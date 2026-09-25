import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  defineChain,
  http,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { optaraCoreAbi, erc20Abi, aggregatorV3Abi } from "../../src/abi.ts";
import { loadManifest, type IndexerConfig } from "../../src/config.ts";
import { Store } from "../../src/db.ts";
import { Indexer } from "../../src/indexer.ts";
import { reconcile } from "../../src/reconcile.ts";
import { keeperTick } from "../../src/keeper.ts";
import { buildFinalizationProof } from "../../src/proof.ts";
import { startApi } from "../../src/api.ts";

const ROOT = resolve(import.meta.dirname, "../../..");
const PORT = 8546;
const RPC = `http://127.0.0.1:${PORT}`;
const API_PORT = 18787;
const KEYS = {
  deployer: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  user: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", // anvil #3 (DeployLocal.USER)
  bob: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a", // anvil #4
} as const;

const chain = defineChain({ id: 31337, name: "anvil", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pub = createPublicClient({ chain, transport: http(RPC), cacheTime: 0 }) as PublicClient;
const test = createTestClient({ chain, mode: "anvil", transport: http(RPC) });
const wallet = (k: Hex) => createWalletClient({ chain, transport: http(RPC), account: privateKeyToAccount(k) });
const deployer = wallet(KEYS.deployer);
const user = wallet(KEYS.user);
const bob = wallet(KEYS.bob);

let anvil: ChildProcess;
let cfg: IndexerConfig;
let mocks: Record<string, string> & { seededSeries: Hex[] };
let store: Store;
let indexer: Indexer;

async function send(w: ReturnType<typeof wallet>, address: Address, abi: readonly unknown[], functionName: string, args: unknown[]) {
  const hash = await w.writeContract({ address, abi: abi as never, functionName: functionName as never, args: args as never, chain: null, account: w.account });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  expect(receipt.status).toBe("success");
  return receipt;
}

const mockAggregatorAbi = [
  ...aggregatorV3Abi,
  { type: "function", name: "pushRound", stateMutability: "nonpayable", inputs: [{ type: "int256" }, { type: "uint256" }], outputs: [{ type: "uint80" }] },
  { type: "function", name: "startNewPhase", stateMutability: "nonpayable", inputs: [], outputs: [] },
] as const;

beforeAll(async () => {
  anvil = spawn("anvil", ["--port", String(PORT), "--code-size-limit", "131072", "--silent"], { stdio: "ignore" });
  for (let i = 0; i < 50; i++) {
    try {
      await pub.getBlockNumber();
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 200));
    }
  }
  execFileSync(
    "forge",
    ["script", "script/local/DeployLocal.s.sol", "--rpc-url", RPC, "--broadcast", "--private-key", KEYS.deployer, "--code-size-limit", "131072"],
    { cwd: resolve(ROOT, "contract"), env: { ...process.env, OPTARA_LOCAL_NETWORK: "e2e" }, stdio: "ignore" },
  );
  const manifest = loadManifest(resolve(ROOT, "deployments/e2e.json"));
  mocks = JSON.parse(readFileSync(resolve(ROOT, "deployments/e2e.mocks.json"), "utf8"));
  const marketsPath = resolve(ROOT, "deployments/e2e.markets.json");
  cfg = {
    rpcUrl: RPC, chainId: 31337, manifest, startBlock: 0n, confirmations: 0n, batchSize: 50n, pollIntervalMs: 100,
    reconcileEveryTicks: 1, dbPath: ":memory:", port: API_PORT, capAlertBps: 9000n, kuruMarketsPath: marketsPath,
  };
  store = new Store(":memory:");
  indexer = new Indexer(pub, store, cfg);
}, 300_000);

afterAll(() => {
  anvil?.kill();
  for (const f of ["e2e.json", "e2e.mocks.json", "e2e.config.json", "e2e.markets.json"]) {
    const p = resolve(ROOT, "deployments", f);
    if (existsSync(p)) rmSync(p);
  }
});

describe("indexer end-to-end on anvil", () => {
  const core = () => cfg.manifest.contracts.OptaraCore;
  const usdt = () => mocks.usdt as Address;

  it("indexes the deployment, writes, transfers and locks exactly as the chain reports", async () => {
    const [s0, s1] = mocks.seededSeries as [Hex, Hex];
    await send(user, usdt(), erc20Abi, "approve", [core(), 2n ** 255n]);
    await send(user, core(), optaraCoreAbi, "deposit", [usdt(), 100_000_000n]);
    await send(user, core(), optaraCoreAbi, "write", [s0, 2n * 10n ** 18n, user.account.address]);
    const token0 = (await pub.readContract({ address: core(), abi: optaraCoreAbi, functionName: "getSeries", args: [s0] })).optionToken;
    await send(user, token0, erc20Abi, "transfer", [bob.account.address, 10n ** 18n]);
    // deployer writes the K12 hedge and hands it to the user, who locks it
    await send(deployer, usdt(), erc20Abi, "approve", [core(), 2n ** 255n]);
    await send(deployer, core(), optaraCoreAbi, "deposit", [usdt(), 3_000_000n]);
    await send(deployer, core(), optaraCoreAbi, "write", [s1, 10n ** 18n, user.account.address]);
    const token1 = (await pub.readContract({ address: core(), abi: optaraCoreAbi, functionName: "getSeries", args: [s1] })).optionToken;
    await send(user, token1, erc20Abi, "approve", [core(), 10n ** 18n]);
    await send(user, core(), optaraCoreAbi, "lockLong", [s1, 10n ** 18n]);

    const r = await indexer.syncOnce();
    expect(r.events).toBeGreaterThan(20);
    expect(store.all("SELECT * FROM series")).toHaveLength(7);
    expect(store.all("SELECT * FROM groups")).toHaveLength(4);
    const u = user.account.address.toLowerCase();
    expect(store.get("SELECT amount FROM cash WHERE account = ?", u)).toEqual({ amount: "100000000" });
    expect(store.get("SELECT short_qty FROM positions WHERE account = ? AND series_id = ?", u, s0.toLowerCase())).toEqual({ short_qty: "2000000000000000000" });
    expect(store.get("SELECT locked_qty FROM positions WHERE account = ? AND series_id = ?", u, s1.toLowerCase())).toEqual({ locked_qty: "1000000000000000000" });
    expect(store.get("SELECT amount FROM balances WHERE holder = ? AND token = ?", bob.account.address.toLowerCase(), token0.toLowerCase())).toEqual({ amount: "1000000000000000000" });
    expect(store.get("SELECT amount FROM balances WHERE holder = ? AND token = ?", core().toLowerCase(), token1.toLowerCase())).toEqual({ amount: "1000000000000000000" });

    const now = Number((await pub.getBlock()).timestamp);
    const rep = await reconcile(pub, store, cfg, now);
    expect(rep.alerts.filter((a) => ["DEFICIT", "INDEX_MISMATCH", "VAULT_SHORTFALL"].includes(a.kind))).toEqual([]);
  });

  it("rolls back and rebuilds on a reorg (SECURITY.md section 79)", async () => {
    const snap = await test.snapshot();
    await send(user, core(), optaraCoreAbi, "deposit", [usdt(), 5_000_000n]);
    await indexer.syncOnce();
    const u = user.account.address.toLowerCase();
    expect(store.get("SELECT amount FROM cash WHERE account = ?", u)).toEqual({ amount: "105000000" });
    await test.revert({ id: snap });
    await test.mine({ blocks: 3 });
    const r = await indexer.syncOnce();
    expect(r.rolledBackTo).toBeDefined();
    expect(store.get("SELECT amount FROM cash WHERE account = ?", u)).toEqual({ amount: "100000000" });
    const rep = await reconcile(pub, store, cfg, Number((await pub.getBlock()).timestamp));
    expect(rep.alerts.filter((a) => a.kind === "INDEX_MISMATCH")).toEqual([]);
  });

  it("builds the unique finalization proof; the keeper finalizes and syncs; holders redeem", async () => {
    const [s0] = mocks.seededSeries as [Hex];
    const series = await pub.readContract({ address: core(), abi: optaraCoreAbi, functionName: "getSeries", args: [s0] });
    const feed = mocks.feedMonUsdt as Address;
    // in-force round shortly before expiry (13 USDT/MON); after expiry the feed's aggregator is upgraded (new Chainlink
    // phase) and the successor round is the new phase's first round, so the proof must cross the phase boundary
    const lastBefore = await pub.readContract({ address: feed, abi: mockAggregatorAbi, functionName: "latestRoundData" });
    await send(deployer, feed, mockAggregatorAbi, "pushRound", [13n * 10n ** 8n, series.expiry - 60n]);
    await test.setNextBlockTimestamp({ timestamp: series.expiry + 600n });
    await test.mine({ blocks: 1 });
    await send(deployer, feed, mockAggregatorAbi, "startNewPhase", []);
    await send(deployer, feed, mockAggregatorAbi, "pushRound", [14n * 10n ** 8n, series.expiry + 600n]);
    const phaseOf = (id: bigint) => id >> 64n;
    const newLatest = await pub.readContract({ address: feed, abi: mockAggregatorAbi, functionName: "latestRoundData" });
    expect(phaseOf(newLatest[0])).toBe(phaseOf(lastBefore[0]) + 1n);

    const proof = await buildFinalizationProof(pub, cfg.manifest.contracts.OracleRegistry, cfg.manifest.contracts.ChainlinkSettlementAdapter, {
      groupId: series.groupId, oracleConfigId: series.oracleConfigId, expiry: series.expiry,
    });
    expect(proof.error).toBeUndefined();
    expect(proof.sourceIndex).toBe(0);
    expect(proof.quotedPriceWad).toBe(13n * 10n ** 18n); // quoted by the on-chain adapter from the cross-phase proof

    await indexer.syncOnce();
    const now = (await pub.getBlock()).timestamp;
    const k = await keeperTick(pub, deployer, store, cfg, now);
    expect(k.finalized).toContain(series.groupId.toLowerCase());
    await indexer.syncOnce();
    // second keeper pass syncs the now-finalized account groups
    const k2 = await keeperTick(pub, deployer, store, cfg, now);
    expect(k2.synced.length).toBeGreaterThanOrEqual(2);
    await indexer.syncOnce();

    const u = user.account.address.toLowerCase();
    // user: short 2 x 3 = 6 debit, locked K12C3 x 1 = 1 credit -> 100 - 5 = 95
    expect(store.get("SELECT amount FROM cash WHERE account = ?", u)).toEqual({ amount: "95000000" });
    expect(store.all("SELECT * FROM positions WHERE account = ?", u)).toHaveLength(0);
    expect(store.get("SELECT finalized, settlement_price_wad FROM groups WHERE group_id = ?", series.groupId.toLowerCase()))
      .toEqual({ finalized: 1, settlement_price_wad: "13000000000000000000" });

    await send(bob, core(), optaraCoreAbi, "redeem", [s0, 10n ** 18n, bob.account.address]);
    expect(await pub.readContract({ address: usdt(), abi: erc20Abi, functionName: "balanceOf", args: [bob.account.address] })).toBe(3_000_000n);
    await indexer.syncOnce();
    const rep = await reconcile(pub, store, cfg, Number(now));
    expect(rep.alerts.filter((a) => ["DEFICIT", "INDEX_MISMATCH", "VAULT_SHORTFALL"].includes(a.kind))).toEqual([]);
    // the MON/USDe group expired too but its only round is stale: flagged, never settled with an invented price
    expect(rep.alerts.some((a) => a.kind === "AWAITING_FINALIZATION")).toBe(true);
  });

  it("serves the read API", async () => {
    const [s0] = mocks.seededSeries as [Hex];
    const series = store.get<{ option_token: string; settlement_asset: string }>("SELECT * FROM series WHERE series_id = ?", s0.toLowerCase())!;
    writeFileSync(cfg.kuruMarketsPath!, JSON.stringify([
      { seriesId: s0, market: "0x00000000000000000000000000000000000000f1", base: series.option_token, quote: series.settlement_asset, chainId: 31337 },
      { seriesId: s0, market: "0x00000000000000000000000000000000000000f2", base: series.option_token, quote: mocks.usdc, chainId: 31337 },
    ]));
    const server = startApi({ store, client: pub, cfg, cursor: () => indexer.cursor() });
    try {
      const get = (p: string) => fetch(`http://127.0.0.1:${API_PORT}${p}`).then((r) => r.json());
      expect((await get("/health")).ok).toBe(true);
      expect(await get("/series")).toHaveLength(7);
      const acct = await get(`/accounts/${user.account.address}`);
      expect(acct.cash[0].amount).toBe("95000000");
      const risk = await get(`/accounts/${user.account.address}/risk`);
      expect(risk.find((r: { asset: string }) => r.asset.toLowerCase() === mocks.usdt!.toLowerCase()).cash).toBe("95000000");
      const markets = await get("/markets");
      expect(markets.valid).toHaveLength(1);
      expect(markets.rejected[0].reason).toBe("quote is not the series settlement asset");
      const alerts = await get("/alerts");
      expect(alerts.some((a: { kind: string }) => a.kind === "AWAITING_FINALIZATION")).toBe(true);
      const events = await get(`/accounts/${user.account.address}/events`);
      expect(events.length).toBeGreaterThan(3);
      expect((await fetch(`http://127.0.0.1:${API_PORT}/nope`)).status).toBe(404);
    } finally {
      server.close();
    }
  });
});
