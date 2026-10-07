// @vitest-environment node
/**
 * FRONTEND.md §11 "Integration": user flows F1–F13 (USER_FLOWS.md) through the app's own transaction builders and
 * reads, against the local stack, with a real surface publisher serving /oracle-update and mock Kuru books.
 */
import type { Server } from "node:http";
import { afterAll, beforeAll, describe, expect, inject, it, vi } from "vitest";
import type { Address, Hex } from "viem";
import { RestampMockPythSource, SeriesCatalog, settlementWindowAbi, subAccountsAbi } from "@optara/sdk";
import {
  freshOracleUpdate,
  increaseTime,
  latestTimestamp,
  pushOracles,
  quoteBooks,
  send,
  stackAccount,
  stackProduct,
  startLocalStack,
  walletFor,
  type LocalStack,
} from "@optara/sdk/testing";
import { Publisher } from "@optara/publisher/src/publisher.ts";
import { SyntheticInputs, skewSmile } from "@optara/publisher/src/inputs.ts";
import { startServer } from "@optara/publisher/src/server.ts";

const E18 = 10n ** 18n;
const USDC = 10n ** 6n;

let s: LocalStack;
let server: Server;
let lib: {
  actions: typeof import("../lib/optara/actions.ts");
  reads: typeof import("../lib/optara/reads.ts");
};
let series: import("../lib/optara/types.ts").Series[];
const byIndex = (i: number) => series.find((x) => x.id.toLowerCase() === stackProduct(s.manifest).seriesIds[i]!.toLowerCase())!;

/** What the app's TxButton does: skip steps already done, run the rest in order. */
async function run(user: number, steps: import("../lib/optara/actions.ts").Step[]) {
  const w = walletFor(s, user) as any;
  const receipts = [];
  for (const st of steps) {
    if (st.done && (await st.done(w))) continue;
    receipts.push(await st.run(w));
  }
  return receipts;
}

beforeAll(async () => {
  const { statePath, manifestPath } = inject("stack");
  s = await startLocalStack(statePath, manifestPath);
  const p = stackProduct(s.manifest);
  await pushOracles(s, 4, await freshOracleUpdate(s, { price: 4000 }));
  await quoteBooks(s, { indices: [3, 4, 6] }); // 4000 put, 4500 call, 5000 call (first expiry)

  const catalog = new SeriesCatalog(s.test, s.manifest.proxies.OptionSeriesRegistry.proxy, 0n, 1000n);
  const publisher = new Publisher({
    client: s.test,
    manifest: s.manifest,
    products: [{ symbol: "ETH/USDC", productId: p.productId, underlying: p.weth, settlementAsset: p.usdc, inputs: new SyntheticInputs(skewSmile(0.6, -0.1, 0.1)) }],
    signers: [stackAccount(2), stackAccount(3)],
    catalog,
    spot: new RestampMockPythSource(s.test, p.pyth),
  });
  const r = await publisher.publish({ symbol: "ETH/USDC", productId: p.productId, underlying: p.weth, settlementAsset: p.usdc, inputs: new SyntheticInputs(skewSmile(0.6, -0.1, 0.1)) });
  expect(r.ok).toBe(true);
  server = await startServer({ publisher, catalog, client: s.test, manifest: s.manifest, status: () => ({ ok: true }) }, 0);

  // The app reads its network from the environment (config/network.ts).
  vi.stubEnv("VITE_NETWORK", "e2e-services");
  vi.stubEnv("VITE_RPC_URL", s.anvil.rpcUrl);
  vi.stubEnv("VITE_PUBLISHER_URL", `http://127.0.0.1:${(server.address() as { port: number }).port}`);
  lib = { actions: await import("../lib/optara/actions.ts"), reads: await import("../lib/optara/reads.ts") };
  series = await lib.reads.getSeriesList();
}, 600_000);

afterAll(async () => {
  await new Promise((r) => server?.close(r));
  await s?.anvil.stop();
  vi.unstubAllEnvs();
});

describe("writer flows", () => {
  let alice: bigint;
  const ALICE = 5;
  const aliceAddr = () => stackAccount(ALICE).address;

  it("F1 open an account and deposit (one go)", async () => {
    let created: bigint | undefined;
    const p = stackProduct(s.manifest);
    await run(ALICE, lib.actions.setupAccountSteps(p.usdc as Address, 20_000n * USDC, "USDC", (id) => (created = id)));
    alice = created!;
    expect((await lib.reads.getAccounts(aliceAddr())).includes(alice)).toBe(true);
    const a = await lib.reads.getAccount(alice, new Map(series.map((x) => [x.id, x])));
    expect(a.cash).toBe(20_000n * USDC);
    expect(a.positions).toEqual([]);
  });

  it("F2 write with fresh oracle data and sell on Kuru; F3 deposit the premium", async () => {
    const c4500 = byIndex(4);
    const [fee, , , ok] = await lib.reads.previewMint(alice, c4500.id, E18);
    expect(ok).toBe(true);
    const quote = (await lib.reads.getQuote(c4500.id))!;
    const gross = (quote.bid! * E18) / E18 / 10n ** 12n;
    const kuruFee = await lib.reads.kuruSellFee(quote.market, gross);
    const before = await lib.reads.getTokenBalance(c4500.settlementAsset, aliceAddr());
    await run(ALICE, [...lib.actions.mintSteps(alice, c4500, E18, fee + fee / 100n + 1n, aliceAddr()), ...lib.actions.sellSteps(c4500, E18, ((gross - kuruFee) * 99n) / 100n, kuruFee + 1n, aliceAddr())]);
    const premium = (await lib.reads.getTokenBalance(c4500.settlementAsset, aliceAddr())) - before;
    // The book rounds the fill and Kuru's fee; the app's estimate (with 1% slippage) is within one unit of it.
    expect(premium - (gross - kuruFee)).toBeGreaterThanOrEqual(-1n);
    expect(premium - (gross - kuruFee)).toBeLessThanOrEqual(1n);
    const a = await lib.reads.getAccount(alice, new Map(series.map((x) => [x.id, x])));
    expect(a.positions.map((p) => [p.seriesId, p.balance])).toEqual([[c4500.id, -E18]]);

    const equityBefore = a.health.equity;
    await run(ALICE, lib.actions.depositSteps(alice, c4500.settlementAsset, premium, "USDC"));
    expect((await lib.reads.getHealth(alice)).equity - equityBefore).toBe(premium * 10n ** 12n);
  });

  it("F4 hedge with a spread: buy the 5000 call on Kuru, move it into the account; margin drops", async () => {
    const c5000 = byIndex(6);
    const imBefore = (await lib.reads.getHealth(alice)).initialMargin;
    const quote = (await lib.reads.getQuote(c5000.id))!;
    const budget = (quote.ask! * 11n) / 10n / 10n ** 12n + 2n * USDC; // a bit more than one option costs
    const buyerFee = await lib.reads.previewBuyerFee(budget);
    const venueFee = await lib.reads.kuruTakerFee(quote.market, budget);
    await run(ALICE, lib.actions.buySteps(c5000, budget, E18 / 2n, buyerFee + 1n, venueFee + 1n, aliceAddr()));
    const held = (await lib.reads.getWalletWrappers(aliceAddr(), [c5000]))[0]!.balance;
    expect(held).toBeGreaterThanOrEqual(E18);
    await run(ALICE, lib.actions.unwrapSteps(alice, c5000, E18));
    expect((await lib.reads.getHealth(alice)).initialMargin).toBeLessThan(imBefore);
  });

  it("F5 buy back and close; F6 withdraw within free margin; F7 move a long to the wallet", async () => {
    const c4500 = byIndex(4);
    const c5000 = byIndex(6);
    const quote = (await lib.reads.getQuote(c4500.id))!;
    const budget = (quote.ask! * 11n) / 10n / 10n ** 12n + 2n * USDC;
    await run(ALICE, lib.actions.buySteps(c4500, budget, E18, (await lib.reads.previewBuyerFee(budget)) + 1n, (await lib.reads.kuruTakerFee(quote.market, budget)) + 1n, aliceAddr()));
    await run(ALICE, lib.actions.closeShortSteps(alice, c4500, E18));
    let a = await lib.reads.getAccount(alice, new Map(series.map((x) => [x.id, x])));
    expect(a.positions.find((p) => p.seriesId === c4500.id)).toBeUndefined();

    const out = a.maxWithdrawable / 2n;
    const before = await lib.reads.getTokenBalance(c4500.settlementAsset, aliceAddr());
    await run(ALICE, lib.actions.withdrawSteps(alice, out, aliceAddr()));
    expect((await lib.reads.getTokenBalance(c4500.settlementAsset, aliceAddr())) - before).toBe(out);

    await run(ALICE, lib.actions.wrapSteps(alice, c5000, E18, aliceAddr()));
    a = await lib.reads.getAccount(alice, new Map(series.map((x) => [x.id, x])));
    expect(a.positions).toEqual([]);
  });
});

describe("buyer, liquidator and settlement flows", () => {
  const BOB = 6;
  const CAROL = 7;
  const DAVE = 8;
  let carol: bigint;
  let dave: bigint;

  it("F9 buy a put through the router; F11 unwrap it into an account", async () => {
    const p4000 = byIndex(3);
    const quote = (await lib.reads.getQuote(p4000.id))!;
    const budget = 200n * USDC;
    const bob = stackAccount(BOB).address;
    await run(BOB, lib.actions.buySteps(p4000, budget, 1n, (await lib.reads.previewBuyerFee(budget)) + 1n, (await lib.reads.kuruTakerFee(quote.market, budget)) + 1n, bob));
    const held = (await lib.reads.getWalletWrappers(bob, [p4000]))[0]!.balance;
    expect(held).toBeGreaterThan(0n);
    let account: bigint | undefined;
    await run(BOB, lib.actions.setupAccountSteps(p4000.settlementAsset, 100n * USDC, "USDC", (id) => (account = id)));
    const unit = 10n ** 16n; // minPositionQty
    await run(BOB, lib.actions.unwrapSteps(account!, p4000, (held / unit) * unit));
    const a = await lib.reads.getAccount(account!, new Map(series.map((x) => [x.id, x])));
    expect(a.positions[0]!.balance).toBe((held / unit) * unit);
  });

  it("F8 margin trouble after a rally; F12 a liquidator starts the auction and takes a slice", async () => {
    const c4500 = byIndex(4);
    let id: bigint | undefined;
    const p = stackProduct(s.manifest);
    await run(CAROL, lib.actions.setupAccountSteps(p.usdc as Address, 1n, "USDC", (x) => (id = x)));
    carol = id!;
    const [, eqAfter, imAfter] = await lib.reads.previewMint(carol, c4500.id, 2n * E18);
    await run(CAROL, lib.actions.depositSteps(carol, p.usdc as Address, (imAfter - eqAfter) / 10n ** 12n + USDC, "USDC"));
    await run(CAROL, lib.actions.mintSteps(carol, c4500, 2n * E18, 10n ** 12n, stackAccount(CAROL).address));
    expect((await lib.reads.getHealth(carol)).state).toBe("HEALTHY");

    await increaseTime(s.anvil.rpcUrl, 2);
    await pushOracles(s, 4, await freshOracleUpdate(s, { price: 6000 }));
    expect((await lib.reads.getHealth(carol)).state).toBe("LIQUIDATABLE");

    await run(DAVE, lib.actions.setupAccountSteps(p.usdc as Address, 60_000n * USDC, "USDC", (x) => (dave = x)));
    await run(DAVE, lib.actions.startAuctionSteps(carol, p.weth as Address));
    expect((await lib.reads.getAuction(carol, p.weth as Address)).start).not.toBe(0n);
    await increaseTime(s.anvil.rpcUrl, 900);
    await pushOracles(s, 4, await freshOracleUpdate(s, { price: 6000 }));
    const [, , discount, , cash] = await lib.reads.previewSlice(carol, p.weth as Address, 2500);
    expect(discount).toBeGreaterThan(0n);
    const healthBefore = await lib.reads.getHealth(carol);
    await run(DAVE, lib.actions.sliceSteps(carol, p.weth as Address, dave, 2500, cash > 0n ? (cash * 99n) / 100n : 0n, cash < 0n ? (-cash * 101n) / 100n : 0n));
    const after = await lib.reads.getHealth(carol);
    expect(after.equity - after.maintenanceMargin).toBeGreaterThan(healthBefore.equity - healthBefore.maintenanceMargin);
  });

  it("F13 expiry to payout: fix the price, settle accounts in a batch, open payouts; F10 redeem; claim credits", async () => {
    const c4500 = byIndex(4);
    const p = stackProduct(s.manifest);
    const groupId = c4500.groupId;
    const feedAbi = [{ type: "function", name: "pushRound", stateMutability: "nonpayable", inputs: [{ type: "int256" }, { type: "uint256" }], outputs: [{ type: "uint80" }] }] as const;
    const push = async (answer: bigint) => send(s, stackAccount(0), { address: p.settlementFeed as Address, abi: feedAbi, functionName: "pushRound", args: [answer, await latestTimestamp(s.anvil.rpcUrl)] });
    await increaseTime(s.anvil.rpcUrl, c4500.expiry - 600n - (await latestTimestamp(s.anvil.rpcUrl)));
    await push(4600_00000000n);
    await increaseTime(s.anvil.rpcUrl, 1200);
    await push(4700_00000000n);

    expect((await lib.reads.getGroup(groupId)).state).toBe("EXPIRED");
    await run(BOB, lib.actions.finalizeSteps(groupId, c4500.settlementOracleConfigId, c4500.expiry));
    expect((await lib.reads.getGroup(groupId)).state).toBe("FINALIZED");

    const holders = await lib.reads.getHolders(series.filter((x) => x.groupId === groupId).map((x) => x.id));
    for (let i = 0; i < holders.length; i += 20) await run(BOB, lib.actions.settleBatchSteps(groupId, holders.slice(i, i + 20)));
    expect((await lib.reads.getGroup(groupId)).state).toBe("ALL_SETTLED");
    await run(BOB, lib.actions.ratioSteps(groupId));
    const g = await lib.reads.getGroup(groupId);
    expect(g.state).toBe("REDEEMABLE");
    expect(g.accounting.priceWad).toBe(4600n * E18);

    // F10: Carol's written-and-held 4500 calls pay (4600 − 4500) × ratio each.
    const carolAddr = stackAccount(CAROL).address;
    const held = (await lib.reads.getWalletWrappers(carolAddr, [c4500]))[0]!.balance;
    const [payout] = await lib.reads.previewRedeem(c4500.id, held);
    const before = await lib.reads.getTokenBalance(c4500.settlementAsset, carolAddr);
    await run(CAROL, lib.actions.redeemSteps(c4500, held, carolAddr));
    expect((await lib.reads.getTokenBalance(c4500.settlementAsset, carolAddr)) - before).toBe(payout);
    expect(payout).toBe((held * 100n) / 10n ** 12n);

    // Claims: the liquidator took over shorts (a debt); any account left with a credit claims it into cash.
    const sw = s.manifest.proxies.SettlementWindow.proxy;
    for (const a of holders) {
      const credit = await s.test.readContract({ address: sw, abi: settlementWindowAbi, functionName: "creditOf", args: [a, groupId] });
      if (credit === 0n) continue;
      const owner = await s.test.readContract({ address: s.manifest.proxies.SubAccounts.proxy, abi: subAccountsAbi, functionName: "ownerOf", args: [a] });
      const who = [5, 6, 7, 8, 9].find((i) => stackAccount(i).address === owner);
      if (who === undefined) continue;
      await run(who, lib.actions.claimSteps(a, groupId as Hex));
      expect(await s.test.readContract({ address: sw, abi: settlementWindowAbi, functionName: "creditOf", args: [a, groupId] })).toBe(credit); // the record stays; a second claim refuses
      await expect(run(who, lib.actions.claimSteps(a, groupId as Hex))).rejects.toThrow(/Nothing left to claim/);
    }
  });
});
