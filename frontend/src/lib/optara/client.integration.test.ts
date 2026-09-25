// @vitest-environment node
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { readFileSync, rmSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, createTestClient, createWalletClient, defineChain, getAddress, http, type Address, type Hex, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { Manifest } from "../../config/networks.ts";
import { getSeries, listSeries, getAccountRiskState, getPositions, previewWrite, previewRedeem, tokenBalance, getSettlementSchedule } from "./reads.ts";
import {
  buildApprove, buildDeposit, buildWrite, buildLockLong, buildCloseShort, buildCancelUnfinalizedShort, buildRedeem,
  buildSyncRiskGroup, buildWithdraw, buildFinalizeRiskGroup, CloseSource,
} from "./actions.ts";
import { closeActionFor, lifecycleOf } from "./lifecycle.ts";

/**
 * Thin client layer against real contracts (SDK-001..014 analogues for this repo): reads match the chain and every
 * builder produces calldata the core accepts. Starts its own anvil and deployment.
 */
const ROOT = resolve(import.meta.dirname, "../../../..");
const PORT = 8547;
const RPC = `http://127.0.0.1:${PORT}`;
const DEPLOYER = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
const USER = "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6" as const;
const chain = defineChain({ id: 31337, name: "anvil", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pub = createPublicClient({ chain, transport: http(RPC), cacheTime: 0 }) as PublicClient;
const testClient = createTestClient({ chain, mode: "anvil", transport: http(RPC) });
const user = createWalletClient({ chain, transport: http(RPC), account: privateKeyToAccount(USER) });
const deployer = createWalletClient({ chain, transport: http(RPC), account: privateKeyToAccount(DEPLOYER) });

let anvil: ChildProcess;
let m: Manifest;
let mocks: { usdt: Address; feedMonUsdt: Address; seededSeries: Hex[] };

type Req = { address: Address; abi: readonly unknown[]; functionName: string; args: readonly unknown[] };
async function send(w: typeof user, r: Req) {
  const hash = await w.writeContract({ ...(r as object), chain: null, account: w.account } as never);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  expect(receipt.status).toBe("success");
}

beforeAll(async () => {
  anvil = spawn("anvil", ["--port", String(PORT), "--code-size-limit", "131072", "--silent"], { stdio: "ignore" });
  for (let i = 0; i < 50; i++) {
    try { await pub.getBlockNumber(); break; } catch { await new Promise((r) => setTimeout(r, 200)); }
  }
  execFileSync("forge", ["script", "script/local/DeployLocal.s.sol", "--rpc-url", RPC, "--broadcast", "--private-key", DEPLOYER, "--code-size-limit", "131072"],
    { cwd: resolve(ROOT, "contract"), env: { ...process.env, OPTARA_LOCAL_NETWORK: "fe2e" }, stdio: "ignore" });
  const raw = JSON.parse(readFileSync(resolve(ROOT, "deployments/fe2e.json"), "utf8")) as Manifest;
  m = { ...raw, contracts: Object.fromEntries(Object.entries(raw.contracts).map(([k, v]) => [k, getAddress(v)])) as Manifest["contracts"] };
  mocks = JSON.parse(readFileSync(resolve(ROOT, "deployments/fe2e.mocks.json"), "utf8"));
}, 300_000);

afterAll(() => {
  anvil?.kill();
  for (const f of ["fe2e.json", "fe2e.mocks.json", "fe2e.config.json"]) {
    const p = resolve(ROOT, "deployments", f);
    if (existsSync(p)) rmSync(p);
  }
});

describe("thin client layer against deployed contracts", () => {
  it("lists series with metadata from chain (settlement asset read per series, never a global USDC)", async () => {
    const all = await listSeries(pub, m);
    expect(all).toHaveLength(7);
    const s = all.find((x) => x.seriesId === mocks.seededSeries[0])!;
    expect(s.assetSymbol).toBe("USDT");
    expect(s.assetDecimals).toBe(6);
    expect(s.underlyingSymbol).toBe("MON");
    expect(s.tokenSymbol).toMatch(/^oMON-USDT-10C-C5-/);
    expect(all.some((x) => x.assetSymbol === "USDC")).toBe(true);
    expect(all.some((x) => x.assetSymbol === "USDe" && x.assetDecimals === 18)).toBe(true);
  });

  it("reads the precommitted settlement schedule from the immutable oracle config", async () => {
    const s = await getSeries(pub, m, mocks.seededSeries[0]!);
    // local deployment: observation [expiry - 1h, expiry], min delay 5 min, max delay 7 days
    expect(await getSettlementSchedule(pub, m, s)).toEqual({
      observationStart: s.expiry - 3600n,
      observationEnd: s.expiry,
      earliestFinalization: s.expiry + 300n,
      escalationDeadline: s.expiry + 604_800n,
    });
  });

  it("deposit, preview, write, lock, close: previews match execution and builders are accepted", async () => {
    const [s0, s1] = mocks.seededSeries as [Hex, Hex];
    const series0 = await getSeries(pub, m, s0);
    const account = user.account.address;
    await send(user, buildApprove(mocks.usdt, m.contracts.OptaraCore, 10_000_000n));
    await send(user, buildDeposit(m, mocks.usdt, 10_000_000n));
    const p = await previewWrite(pub, m, account, series0, 10n ** 18n);
    expect(p.requiredAfter).toBe(5_000_000n);
    expect(p.additionalCollateral).toBe(0n);
    expect(p.maxPayoutNative).toBe(5_000_000n);
    await send(user, buildWrite(m, s0, 10n ** 18n, account));
    const risk = await getAccountRiskState(pub, m, account, mocks.usdt);
    expect(risk.requiredMargin).toBe(p.requiredAfter); // SDK-005: preview == execution state
    expect(risk.freeCollateral).toBe(5_000_000n);
    // lock + LOCKED close of the identical series leaves requirement unchanged
    await send(user, buildWrite(m, s0, 10n ** 18n, account));
    await send(user, buildApprove(series0.optionToken, m.contracts.OptaraCore, 10n ** 18n));
    await send(user, buildLockLong(m, s0, 10n ** 18n));
    await send(user, buildCloseShort(m, s0, 10n ** 18n, CloseSource.LOCKED));
    const pos = await getPositions(pub, m, account);
    expect(pos).toEqual([{ seriesId: s0, groupId: series0.groupId, shortQty: 10n ** 18n, lockedQty: 0n }]);
    await send(user, buildWithdraw(m, mocks.usdt, 5_000_000n, account));
    expect((await getAccountRiskState(pub, m, account, mocks.usdt)).cash).toBe(5_000_000n);
    void s1;
  });

  it("after expiry the close action becomes cancellation; after finalization redeem + sync", async () => {
    const [s0] = mocks.seededSeries as [Hex];
    let series0 = await getSeries(pub, m, s0);
    const account = user.account.address;
    const pushAbi = [{ type: "function", name: "pushRound", stateMutability: "nonpayable", inputs: [{ type: "int256" }, { type: "uint256" }], outputs: [{ type: "uint80" }] }] as const;
    await send(deployer, { address: mocks.feedMonUsdt, abi: pushAbi, functionName: "pushRound", args: [12n * 10n ** 8n, series0.expiry - 30n] });
    await testClient.setNextBlockTimestamp({ timestamp: series0.expiry + 1n });
    await testClient.mine({ blocks: 1 });
    series0 = await getSeries(pub, m, s0);
    const life = lifecycleOf(series0.status, series0.oracleStalled);
    expect(life.kind).toBe("AWAITING_PRICE");
    expect(closeActionFor(life)).toBe("cancelUnfinalizedShort");
    // write happened before expiry: user holds 1 long + 1 short -> cancel half
    await send(user, buildCancelUnfinalizedShort(m, s0, 5n * 10n ** 17n, CloseSource.EXTERNAL));

    await testClient.setNextBlockTimestamp({ timestamp: series0.expiry + 600n });
    await testClient.mine({ blocks: 1 });
    const n = await pub.readContract({ address: mocks.feedMonUsdt, abi: [{ type: "function", name: "latestRoundData", stateMutability: "view", inputs: [], outputs: [{ type: "uint80" }, { type: "int256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint80" }] }] as const, functionName: "latestRoundData" });
    const { encodeAbiParameters } = await import("viem");
    const data = encodeAbiParameters(
      [{ type: "tuple", components: [{ type: "uint8" }, { type: "tuple[]", components: [{ type: "uint80" }, { type: "uint80" }] }, { type: "tuple[]", components: [{ type: "uint80" }, { type: "uint80" }] }] }],
      [[0, [[n[0], 0n]], []]],
    );
    await send(user, buildFinalizeRiskGroup(m, series0.groupId, data));
    series0 = await getSeries(pub, m, s0);
    const settled = lifecycleOf(series0.status, series0.oracleStalled, series0.payoffPerUnderlyingWad);
    expect(settled.kind).toBe("SETTLED");
    expect(closeActionFor(settled)).toBe("redeemAndSync");
    expect(series0.settlementPriceWad).toBe(12n * 10n ** 18n);
    const half = 5n * 10n ** 17n;
    expect(await previewRedeem(pub, m, s0, half)).toEqual({ payout: 1_000_000n, paid: 1_000_000n });
    await send(user, buildRedeem(m, s0, half, account));
    await send(user, buildSyncRiskGroup(m, account, series0.groupId));
    expect(await tokenBalance(pub, series0.optionToken, account)).toBe(0n);
    // cash 5 - debit(0.5 short * 2) = 4
    expect((await getAccountRiskState(pub, m, account, mocks.usdt)).cash).toBe(4_000_000n);
  });
});
