/**
 * KPR-001: the settlement keeper finalizes, settles every participant in batches and computes the ratio for a
 * group with 200 accounts.
 */
import { afterAll, beforeAll, describe, expect, inject, it } from "vitest";
import { erc20Abi, maxUint256 } from "viem";
import {
  LedgerLogDirectory,
  SeriesCatalog,
  optionClearingAbi,
  settlementWindowAbi,
  subAccountsAbi,
  type OracleUpdate,
} from "@optara/sdk";
import {
  createAccount,
  freshOracleUpdate,
  increaseTime,
  latestTimestamp,
  pushOracles,
  send,
  spotFee,
  stackAccount,
  stackProduct,
  startLocalStack,
  walletFor,
  type LocalStack,
} from "@optara/sdk/testing";
import { SettlementKeeper, GroupState } from "../src/settlementKeeper.ts";
import type { Ctx } from "../src/tx.ts";

const mockAggregatorAbi = [
  { type: "function", name: "pushRound", stateMutability: "nonpayable", inputs: [{ name: "answer", type: "int256" }, { name: "updatedAt", type: "uint256" }], outputs: [{ name: "roundId", type: "uint80" }] },
] as const;

let s: LocalStack;
beforeAll(async () => {
  const { statePath, manifestPath } = inject("stack");
  s = await startLocalStack(statePath, manifestPath);
});
afterAll(() => s?.anvil.stop());

const ACCOUNTS = 200;
const QTY = 10n ** 16n; // minPositionQty: 0.01 contracts each

describe("KPR-001 settlement keeper", () => {
  it("finalizes, settles 200 participants in batches and fixes the ratio", { timeout: 900_000 }, async () => {
    const p = stackProduct(s.manifest);
    const series = p.seriesIds[4]!; // 4500 call, first expiry
    const clearing = s.manifest.proxies.OptionClearing.proxy;
    const ledger = s.manifest.proxies.SubAccounts.proxy;
    await pushOracles(s, 4, await freshOracleUpdate(s, { price: 4000 }));

    const users = [5, 6, 7, 8, 9];
    for (const u of users) await send(s, stackAccount(u), { address: p.usdc, abi: erc20Abi, functionName: "approve", args: [clearing, maxUint256] });
    // 200 writers: five owners in parallel (one nonce sequence each), 40 accounts apiece; the surface is
    // refreshed between rounds so it stays within surfaceStaleAfter.
    const accounts: bigint[] = [];
    const perOwner = ACCOUNTS / users.length;
    for (let round = 0; round < perOwner; round += 8) {
      await pushOracles(s, 4, await freshOracleUpdate(s, { price: 4000 }));
      const made = await Promise.all(
        users.map(async (u) => {
          const owner = stackAccount(u);
          const ids: bigint[] = [];
          for (let i = round; i < Math.min(round + 8, perOwner); i++) {
            const id = await createAccount(s, u);
            await send(s, owner, { address: clearing, abi: optionClearingAbi, functionName: "depositCollateral", args: [id, 200n * 10n ** 6n] });
            const upd: OracleUpdate = await freshOracleUpdate(s, { price: 4000, surface: false });
            await send(s, owner, { address: clearing, abi: optionClearingAbi, functionName: "mintExternalLong", args: [id, series, QTY, owner.address, maxUint256, upd], value: await spotFee(s, upd) });
            ids.push(id);
          }
          return ids;
        }),
      );
      accounts.push(...made.flat());
    }
    expect(accounts).toHaveLength(ACCOUNTS);
    const group = s.manifest.proxies.SettlementWindow.proxy;
    const catalog = new SeriesCatalog(s.test, s.manifest.proxies.OptionSeriesRegistry.proxy, 0n, 1000n);
    await catalog.sync();
    const g = catalog.groups().find((x) => x.series.some((ss) => ss.seriesId === series))!;
    expect(await s.test.readContract({ address: ledger, abi: subAccountsAbi, functionName: "participants", args: [g.groupId] })).toBe(BigInt(ACCOUNTS));

    // The settlement feed: a round inside the observation window (10 min before expiry) at 4,600, one after.
    const deployer = stackAccount(0);
    const push = async (answer: bigint) =>
      send(s, deployer, { address: p.settlementFeed, abi: mockAggregatorAbi, functionName: "pushRound", args: [answer, await latestTimestamp(s.anvil.rpcUrl)] });
    await increaseTime(s.anvil.rpcUrl, g.expiry - 600n - (await latestTimestamp(s.anvil.rpcUrl)));
    await push(4600_00000000n);
    await increaseTime(s.anvil.rpcUrl, 1200);
    await push(4700_00000000n);

    const keeperAccount = stackAccount(4);
    const ctx: Ctx = { client: s.test, wallet: walletFor(s, 4), log: () => {} };
    const usdcBefore = await s.test.readContract({ address: p.usdc, abi: erc20Abi, functionName: "balanceOf", args: [keeperAccount.address] });
    const keeper = new SettlementKeeper(ctx, {
      manifest: s.manifest,
      catalog,
      directory: new LedgerLogDirectory(s.test, ledger, 0n, 1000n),
      batchSize: 50,
    });
    const r = await keeper.tick();
    expect(r.errors.filter((e) => e.includes(g.groupId))).toEqual([]);
    expect(r.finalized).toContain(g.groupId);
    const settled = r.settled.find((x) => x.groupId === g.groupId)!;
    expect(settled.accounts).toBe(ACCOUNTS);
    expect(settled.batches).toBe(Math.ceil(ACCOUNTS / 50));
    expect(r.ratios).toContain(g.groupId);

    expect(await s.test.readContract({ address: group, abi: settlementWindowAbi, functionName: "groupState", args: [g.groupId] })).toBe(GroupState.REDEEMABLE);
    expect(await s.test.readContract({ address: ledger, abi: subAccountsAbi, functionName: "participants", args: [g.groupId] })).toBe(0n);
    const acct = await s.test.readContract({ address: group, abi: settlementWindowAbi, functionName: "groupAccounting", args: [g.groupId] });
    expect(acct.priceWad).toBe(4600n * 10n ** 18n);
    expect(acct.ratioWad).toBe(10n ** 18n); // every debt (100 USDC × 0.01 each) was collectable
    expect(acct.unpaid).toBe(0n);
    for (const a of [accounts[0]!, accounts[99]!, accounts[199]!]) {
      expect(await s.test.readContract({ address: ledger, abi: subAccountsAbi, functionName: "balanceOf", args: [a, series] })).toBe(0n);
    }
    const usdcAfter = await s.test.readContract({ address: p.usdc, abi: erc20Abi, functionName: "balanceOf", args: [keeperAccount.address] });
    expect(usdcAfter - usdcBefore).toBeGreaterThanOrEqual(2n * 10n ** 6n + BigInt(ACCOUNTS) * 5n * 10n ** 5n); // finalize + settle rewards

    // Idempotent: nothing left to do.
    const again = await keeper.tick();
    expect([again.finalized, again.settled, again.ratios]).toEqual([[], [], []]);
  });
});
