/**
 * IDX-001: the indexer rebuilds every balance, total, supply and participant count from events, equal to chain
 * state (through a full lifecycle: writes, wrapper transfers, unwraps, router trades, a liquidation, settlement,
 * claims and redemptions; checked by the monitor's reconciliation and spot checks).
 * IDX-002 (reorg half): after a chain reorganization the indexer rolls back and matches the new chain.
 * Needs the local Envio Postgres (`pnpm exec envio local docker up`).
 */
import type { Server } from "node:http";
import { afterAll, beforeAll, describe, expect, inject, it } from "vitest";
import { erc20Abi, keccak256, maxUint256, toHex, type Address } from "viem";
import {
  LedgerLogDirectory,
  MockPythSource,
  SeriesCatalog,
  optionClearingAbi,
  optionSeriesRegistryAbi,
  settlementWindowAbi,
  subAccountsAbi,
  venueRouterAbi,
} from "@optara/sdk";
import {
  createAccount,
  freshOracleUpdate,
  increaseTime,
  latestTimestamp,
  mint,
  openAccount,
  pushOracles,
  send,
  stackAccount,
  stackProduct,
  startLocalStack,
  walletFor,
  type LocalStack,
} from "@optara/sdk/testing";
import { LiquidationBot } from "@optara/keepers/src/liquidationBot.ts";
import { SettlementKeeper } from "@optara/keepers/src/settlementKeeper.ts";
import { SpotOnlyFeed } from "@optara/keepers/src/oracleFeed.ts";
import { Monitor } from "../api/monitor.ts";
import { startApi } from "../api/server.ts";
import { startEnvio, type RunningIndexer } from "./envio.ts";

const bookAbi = [
  { type: "function", name: "setBid", stateMutability: "nonpayable", inputs: [{ name: "price", type: "uint256" }, { name: "size", type: "uint256" }], outputs: [] },
  { type: "function", name: "setAsk", stateMutability: "nonpayable", inputs: [{ name: "price", type: "uint256" }, { name: "size", type: "uint256" }], outputs: [] },
] as const;
const mockAggregatorAbi = [
  { type: "function", name: "pushRound", stateMutability: "nonpayable", inputs: [{ name: "answer", type: "int256" }, { name: "updatedAt", type: "uint256" }], outputs: [{ name: "roundId", type: "uint80" }] },
] as const;

const E18 = 10n ** 18n;
const USDC = 10n ** 6n;

let s: LocalStack;
let idx: RunningIndexer;
let monitor: Monitor;
let api: Server;
let apiUrl = "";
const accounts: Record<string, bigint> = {};

beforeAll(async () => {
  const { statePath, manifestPath } = inject("stack");
  s = await startLocalStack(statePath, manifestPath);
  await lifecycle();
  idx = await startEnvio(manifestPath, s.anvil.rpcUrl, "idx");
  await idx.waitFor(await s.test.getBlockNumber());
  monitor = new Monitor(idx.db, s.test, s.manifest);
  api = await startApi({ db: idx.db, monitor, client: s.test, manifest: s.manifest }, 0);
  apiUrl = `http://127.0.0.1:${(api.address() as { port: number }).port}`;
}, 900_000);

afterAll(async () => {
  await new Promise((r) => api?.close(r));
  await idx?.stop();
  await s?.anvil.stop();
});

async function lifecycle() {
  const p = stackProduct(s.manifest);
  const px = s.manifest.proxies;
  const c4500 = p.seriesIds[4]!;
  const p4000 = p.seriesIds[3]!;
  const book = p.kuruBooks[4]! as Address;
  let price = 4000;
  await pushOracles(s, 4, await freshOracleUpdate(s, { price }));
  const spotOnly = () => freshOracleUpdate(s, { price, surface: false });

  // Alice writes calls and puts; gives Bob a wrapper; Bob unwraps half of it into his account.
  const [alice, bob, carol] = [stackAccount(5), stackAccount(6), stackAccount(7)];
  accounts.alice = await openAccount(s, 5, 20_000n * USDC);
  await mint(s, 5, accounts.alice, c4500, 2n * E18, await spotOnly());
  await mint(s, 5, accounts.alice, p4000, E18, await spotOnly());
  const wrapper4500 = (await s.test.readContract({ address: px.OptionSeriesRegistry.proxy, abi: optionSeriesRegistryAbi, functionName: "getSeries", args: [c4500] })).wrapper;
  await send(s, alice, { address: wrapper4500, abi: erc20Abi, functionName: "transfer", args: [bob.address, E18] });
  accounts.bob = await openAccount(s, 6, 5_000n * USDC);
  await send(s, bob, { address: px.OptionClearing.proxy, abi: optionClearingAbi, functionName: "unwrapLong", args: [accounts.bob, c4500, E18 / 2n] });

  // Router: Alice sells half a contract to the book; Carol buys it back.
  const mm = stackAccount(0);
  await send(s, mm, { address: book, abi: bookAbi, functionName: "setBid", args: [1_000_000n, 10n ** 16n] });
  await send(s, mm, { address: p.usdc, abi: [{ type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }], outputs: [] }] as const, functionName: "mint", args: [book, 100n * USDC] });
  await send(s, alice, { address: wrapper4500, abi: erc20Abi, functionName: "approve", args: [px.VenueRouter.proxy, maxUint256] });
  const kuru = keccak256(toHex("KURU"));
  const deadline = (await latestTimestamp(s.anvil.rpcUrl)) + 3600n;
  await send(s, alice, { address: px.VenueRouter.proxy, abi: venueRouterAbi, functionName: "sellThroughVenue", args: [{ venueId: kuru, seriesId: c4500, qty: E18 / 2n, minProceeds: 0n, maxVenueFeeNative: maxUint256, recipient: alice.address, deadline }, "0x"] });
  await send(s, mm, { address: book, abi: bookAbi, functionName: "setAsk", args: [1_100_000n, 10n ** 16n] });
  await send(s, carol, { address: p.usdc, abi: erc20Abi, functionName: "approve", args: [px.VenueRouter.proxy, maxUint256] });
  await send(s, carol, { address: px.VenueRouter.proxy, abi: venueRouterAbi, functionName: "buyThroughVenue", args: [{ venueId: kuru, seriesId: c4500, premiumIn: 50n * USDC, minQty: 0n, maxBuyerFeeNative: maxUint256, maxVenueFeeNative: maxUint256, recipient: carol.address, deadline }, "0x"] });

  // A writer at IM; a 50% rally; the reference bot liquidates it from user 9's account.
  const victimOwner = stackAccount(8);
  accounts.victim = await createAccount(s, 8);
  const [, eqAfter, imAfter] = await s.test.readContract({ address: px.OptionClearing.proxy, abi: optionClearingAbi, functionName: "previewMint", args: [accounts.victim, c4500, 2n * E18] });
  await send(s, victimOwner, { address: p.usdc, abi: erc20Abi, functionName: "approve", args: [px.OptionClearing.proxy, maxUint256] });
  await send(s, victimOwner, { address: px.OptionClearing.proxy, abi: optionClearingAbi, functionName: "depositCollateral", args: [accounts.victim, (imAfter - eqAfter) / 10n ** 12n + USDC] });
  await mint(s, 8, accounts.victim, c4500, 2n * E18, await spotOnly());
  accounts.liquidator = await openAccount(s, 9, 60_000n * USDC);
  await increaseTime(s.anvil.rpcUrl, 2);
  price = 6000;
  await pushOracles(s, 4, await freshOracleUpdate(s, { price }));
  const dir = () => new LedgerLogDirectory(s.test, px.SubAccounts.proxy, 0n, 1000n);
  const bot = new LiquidationBot({ client: s.test, wallet: walletFor(s, 9), log: () => {} }, {
    manifest: s.manifest,
    directory: dir(),
    liquidatorAccountId: accounts.liquidator,
    feed: new SpotOnlyFeed(s.test, s.manifest, new MockPythSource(() => price, () => latestTimestamp(s.anvil.rpcUrl))),
    minProfitNative: USDC,
  });
  await bot.tick();
  await increaseTime(s.anvil.rpcUrl, 900);
  await pushOracles(s, 4, await freshOracleUpdate(s, { price }));
  const r = await bot.tick();
  expect(r.slices.length).toBeGreaterThan(0);

  // Expiry of the first group: settlement price 4,600; the keeper settles; Bob claims, Carol redeems.
  const catalog = new SeriesCatalog(s.test, px.OptionSeriesRegistry.proxy, 0n, 1000n);
  await catalog.sync();
  const g = catalog.groups().find((x) => x.series.some((ss) => ss.seriesId === c4500))!;
  const push = async (answer: bigint) => send(s, mm, { address: p.settlementFeed, abi: mockAggregatorAbi, functionName: "pushRound", args: [answer, await latestTimestamp(s.anvil.rpcUrl)] });
  await increaseTime(s.anvil.rpcUrl, g.expiry - 600n - (await latestTimestamp(s.anvil.rpcUrl)));
  await push(4600_00000000n);
  await increaseTime(s.anvil.rpcUrl, 1200);
  await push(4700_00000000n);
  const keeper = new SettlementKeeper({ client: s.test, wallet: walletFor(s, 4), log: () => {} }, { manifest: s.manifest, catalog, directory: dir(), batchSize: 50 });
  const k = await keeper.tick();
  expect(k.ratios).toContain(g.groupId);
  await send(s, bob, { address: px.SettlementWindow.proxy, abi: settlementWindowAbi, functionName: "claimSettlement", args: [accounts.bob, g.groupId] });
  const carolWrappers = await s.test.readContract({ address: wrapper4500, abi: erc20Abi, functionName: "balanceOf", args: [carol.address] });
  await send(s, carol, { address: px.SettlementWindow.proxy, abi: settlementWindowAbi, functionName: "redeemWrapper", args: [c4500, carolWrappers, carol.address] });
  accounts.groupKey = BigInt(g.groupId);
}

const get = async (path: string) => {
  const res = await fetch(`${apiUrl}${path}`);
  expect(res.status).toBe(200);
  return res.json() as Promise<any>;
};

describe("IDX-001 rebuild from events", () => {
  it("every cash balance, series total, wrapper supply, participant count and INV-7 custody equals the chain", async () => {
    expect(await monitor.reconcile()).toEqual([]);
  });

  it("records the lifecycle: auction with slices, trades, fees, the settled group, claims and redemptions", async () => {
    const groupId = `0x${accounts.groupKey!.toString(16).padStart(64, "0")}`;
    const [auction] = await idx.db.rows<any>("Auction", `"accountId" = $1`, [accounts.victim!.toString()]);
    expect(auction.slices).toBeGreaterThan(0);
    expect(auction.active).toBe(false);
    expect((await idx.db.rows("Trade")).length).toBe(2);
    const kinds = new Set((await idx.db.rows<any>("Fee")).map((f) => f.kind));
    for (const k of ["SELLER", "BUYER", "SPLIT", "KEEPER_REWARD"]) expect(kinds).toContain(k);
    const g = await idx.db.one<any>("SettlementGroup", groupId);
    expect([g.finalized, g.ratioSet, g.participants, g.priceWad]).toEqual([true, true, 0n, 4600n * E18]);
    const events = new Set((await idx.db.rows<any>("SettlementEvent", `"groupId" = $1`, [groupId])).map((e) => e.kind));
    expect([...events].sort()).toEqual(["CLAIMED", "REDEEMED", "SETTLED"]);
    const product = (await idx.db.rows<any>("Product"))[0];
    expect(product.spotPriceWad).toBe(6000n * E18);
  });

  it("serves the API: positions, groups with participants, accounts by owner, alerts without mismatches", async () => {
    const positions = await get("/positions");
    const onChain = await s.test.readContract({ address: s.manifest.proxies.SubAccounts.proxy, abi: subAccountsAbi, functionName: "positionsOf", args: [accounts.alice!] });
    expect(positions.filter((p: any) => BigInt(p.accountId) === accounts.alice).length).toBe(onChain.length);
    const groups = await get("/groups");
    const open = groups.find((g: any) => !g.finalized);
    const detail = await get(`/groups/${open.id}`);
    expect(detail.series.length).toBe(8);
    const byOwner = await get(`/accounts/${stackAccount(5).address}`);
    expect(byOwner.map((a: any) => BigInt(a.accountId))).toEqual([accounts.alice]);
    await monitor.refreshHealth();
    const liquidatable = await get("/liquidatable");
    expect(liquidatable.find((h: any) => BigInt(h.accountId) === accounts.victim)).toBeUndefined();
    const alerts = await get("/alerts");
    expect(alerts.filter((a: any) => a.kind === "INDEX_MISMATCH" || a.kind === "CUSTODY")).toEqual([]);
    expect((await get(`/accounts/${accounts.victim}/events`)).liquidations.length).toBeGreaterThan(0);
  });
});

describe("IDX-002 reorg", () => {
  it("rolls back a replaced branch and matches the new chain", async () => {
    const bob = stackAccount(6);
    const px = s.manifest.proxies;
    const snapshot = await s.test.snapshot();
    // Branch A: a deposit of 111 USDC and a new account, both seen by the indexer.
    await send(s, bob, { address: stackProduct(s.manifest).usdc, abi: erc20Abi, functionName: "approve", args: [px.OptionClearing.proxy, maxUint256] });
    await send(s, bob, { address: px.OptionClearing.proxy, abi: optionClearingAbi, functionName: "depositCollateral", args: [accounts.bob!, 111n * USDC] });
    const orphan = await createAccount(s, 6);
    const headA = await s.test.getBlockNumber();
    await idx.waitFor(headA);
    const cashA = (await idx.db.one<any>("Account", accounts.bob!.toString())).cash;
    expect(cashA).toBe(await s.test.readContract({ address: px.SubAccounts.proxy, abi: subAccountsAbi, functionName: "cashOf", args: [accounts.bob!] }));
    expect(await idx.db.one("Account", orphan.toString())).toBeDefined();

    // Reorg: back to the snapshot, then branch B (a different deposit) grows past A.
    await s.test.revert({ id: snapshot });
    await send(s, bob, { address: stackProduct(s.manifest).usdc, abi: erc20Abi, functionName: "approve", args: [px.OptionClearing.proxy, maxUint256] });
    await send(s, bob, { address: px.OptionClearing.proxy, abi: optionClearingAbi, functionName: "depositCollateral", args: [accounts.bob!, 222n * USDC] });
    await s.test.mine({ blocks: 3 });
    const headB = await s.test.getBlockNumber();
    expect(headB).toBeGreaterThan(headA);
    await idx.waitFor(headB);
    const cashOnChain = await s.test.readContract({ address: px.SubAccounts.proxy, abi: subAccountsAbi, functionName: "cashOf", args: [accounts.bob!] });
    expect(cashOnChain).toBe(cashA - 111n * USDC + 222n * USDC);
    expect((await idx.db.one<any>("Account", accounts.bob!.toString())).cash).toBe(cashOnChain);
    // Only a rollback removes the account created on the replaced branch (no event of branch B touches it).
    expect(await idx.db.one("Account", orphan.toString())).toBeUndefined();
    expect(await monitor.reconcile()).toEqual([]);
  });
});
