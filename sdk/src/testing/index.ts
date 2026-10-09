/**
 * Local-chain helpers for the service test suites (TESTING.md §2 "Services"): anvil with Monad's code size limit,
 * the production local stack (contract/script/local/LocalStack.s.sol) deployed once and reused through anvil state
 * files, the stack's accounts, and time control.
 */
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { createServer } from "node:net";
import { existsSync, mkdirSync, writeFileSync, readFileSync, rmSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { createHash } from "node:crypto";
import type {} from "vitest";
import { createTestClient, createWalletClient, http, publicActions, toHex, walletActions, type Hex, type LocalAccount } from "viem";
import { mnemonicToAccount } from "viem/accounts";
import { anvil as anvilChain } from "../chain.ts";
import type { Manifest } from "../manifest.ts";
import { loadManifest, DEPLOYMENTS_DIR } from "../node.ts";

export const ANVIL_MNEMONIC = "test test test test test test test test test test test junk";
export const CONTRACT_DIR = fileURLToPath(new URL("../../../contract", import.meta.url));
const STATE_DIR = join(CONTRACT_DIR, "cache", "services-e2e");
const zeroFeedId = `0x${"0".repeat(64)}` as Hex;

/** Local stack accounts (LocalStack.s.sol): 0 deployer + treasury, 1 governance + admins, 2/3 publishers, 4 keeper, 5–9 users. */
export const stackAccount = (index: number): LocalAccount => mnemonicToAccount(ANVIL_MNEMONIC, { addressIndex: index });
/** The stack account's private key (for services started against the local stack). */
export const stackPrivateKey = (index: number): Hex => toHex(mnemonicToAccount(ANVIL_MNEMONIC, { addressIndex: index }).getHdKey().privateKey!);
export const ACCOUNTS = {
  deployer: 0,
  governance: 1,
  publisherA: 2,
  publisherB: 3,
  keeper: 4,
  users: [5, 6, 7, 8, 9],
} as const;

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => {
      const port = (s.address() as { port: number }).port;
      s.close(() => resolve(port));
    });
    s.on("error", reject);
  });
}

export interface Anvil {
  rpcUrl: string;
  port: number;
  process: ChildProcess;
  stop(): Promise<void>;
}

/** Starts anvil (chain 31337, 128 KB code size limit), optionally from a saved state file. */
export async function startAnvil(opts: { loadState?: string; dumpState?: string; extraArgs?: string[] } = {}): Promise<Anvil> {
  const port = await freePort();
  const args = ["--port", String(port), "--code-size-limit", "131072", "--silent"];
  if (opts.loadState) args.push("--load-state", opts.loadState);
  if (opts.dumpState) args.push("--dump-state", opts.dumpState);
  args.push(...(opts.extraArgs ?? []));
  const proc = spawn("anvil", args, { stdio: "ignore" });
  const rpcUrl = `http://127.0.0.1:${port}`;
  const client = createTestClient({ chain: anvilChain, mode: "anvil", transport: http(rpcUrl) }).extend(publicActions);
  for (let i = 0; ; i++) {
    try {
      await client.getChainId();
      break;
    } catch {
      if (i > 100 || proc.exitCode !== null) throw new Error(`anvil did not start on port ${port}`);
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  return {
    rpcUrl,
    port,
    process: proc,
    stop: () =>
      new Promise((resolve) => {
        if (proc.exitCode !== null) return resolve();
        proc.once("exit", () => resolve());
        proc.kill("SIGTERM");
      }),
  };
}

/** Runs `forge script` from contract/ against `rpcUrl` (broadcast). */
export function forgeScript(script: string, rpcUrl: string, env: Record<string, string> = {}): string {
  return execFileSync(
    "forge",
    ["script", script, "--rpc-url", rpcUrl, "--broadcast", "--disable-code-size-limit", "-q"],
    { cwd: CONTRACT_DIR, env: { ...process.env, ...env, FOUNDRY_DISABLE_NIGHTLY_WARNING: "1", RUST_LOG: "error" }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
}

/**
 * The deployed local stack as an anvil state file plus its manifest (`deployments/e2e-services.json`), built once
 * per machine and reused while contract/out is unchanged. Call from a Vitest globalSetup.
 */
export async function prepareStackState(): Promise<{ statePath: string; manifestPath: string }> {
  mkdirSync(STATE_DIR, { recursive: true });
  const lock = join(STATE_DIR, "lock");
  for (let i = 0; ; i++) {
    try {
      mkdirSync(lock); // atomic: one preparer at a time across parallel test runs
      break;
    } catch {
      if (i > 3000) throw new Error(`stale lock ${lock}: remove it`);
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  try {
    return await prepareLocked();
  } finally {
    rmSync(lock, { recursive: true, force: true });
  }
}

async function prepareLocked(): Promise<{ statePath: string; manifestPath: string }> {
  const statePath = join(STATE_DIR, "stack.json");
  const stampPath = join(STATE_DIR, "stamp");
  const manifestPath = join(DEPLOYMENTS_DIR, "e2e-services.json");
  const stamp = buildStamp();
  // Reuse while the build is unchanged and the state is under 12 h old (its first expiry is over a day out at deploy).
  const fresh = existsSync(statePath) && Date.now() - statSync(statePath).mtimeMs < 12 * 3600_000;
  if (fresh && existsSync(manifestPath) && existsSync(stampPath) && readFileSync(stampPath, "utf8") === stamp) {
    return { statePath, manifestPath };
  }
  const a = await startAnvil({ dumpState: statePath });
  try {
    forgeScript("script/local/LocalStack.s.sol", a.rpcUrl, { NETWORK: "e2e-services" });
  } finally {
    await a.stop(); // anvil writes the state on exit
  }
  writeFileSync(stampPath, stamp);
  return { statePath, manifestPath };
}

/** Changes whenever the compiled contracts or scripts change (forge's build cache). */
function buildStamp(): string {
  const cache = join(CONTRACT_DIR, "cache", "solidity-files-cache.json");
  return existsSync(cache) ? createHash("sha256").update(readFileSync(cache)).digest("hex") : "none";
}

export interface LocalStack {
  anvil: Anvil;
  manifest: Manifest;
  test: ReturnType<typeof testClient>;
}

/** Anvil mines on submission, so poll for receipts every 50 ms (viem's default waits seconds). */
const POLL_MS = 50;

export const testClient = (rpcUrl: string) =>
  // cacheTime 0: tests move the chain (mine, revert) and must never read a cached block number.
  createTestClient({ chain: anvilChain, mode: "anvil", transport: http(rpcUrl), pollingInterval: POLL_MS, cacheTime: 0 }).extend(publicActions).extend(walletActions);

/** A fresh anvil loaded with the prepared stack. */
export async function startLocalStack(statePath: string, manifestPath: string): Promise<LocalStack> {
  const anvil = await startAnvil({ loadState: statePath });
  const test = testClient(anvil.rpcUrl);
  // The loaded state's latest block is as old as the state file; services stamp reports and prices with the
  // latest block time, so bring the chain to the present first (a live chain's head is always current).
  await test.mine({ blocks: 1 });
  return { anvil, manifest: loadManifest(manifestPath), test };
}

/** Advances chain time by `seconds` and mines a block. */
export async function increaseTime(rpcUrl: string, seconds: number | bigint): Promise<void> {
  const t = testClient(rpcUrl);
  await t.increaseTime({ seconds: Number(seconds) });
  await t.mine({ blocks: 1 });
}

export async function latestTimestamp(rpcUrl: string): Promise<bigint> {
  return (await testClient(rpcUrl).getBlock()).timestamp;
}

export type { Hex };

declare module "vitest" {
  export interface ProvidedContext {
    stack: { statePath: string; manifestPath: string };
  }
}

/** The ETH/USDC listing of the local stack (`extra` of its manifest). */
export function stackProducts(m: Manifest) {
  const e = m.extra as Record<string, any>;
  const allExpiries = (e.expiries as number[]).map(BigInt);
  if (e.productIds) {
    const starts = e.productSeriesStarts as number[];
    return (e.productIds as Hex[]).map((productId, i) => ({
      productId,
      underlyingSymbol: (e.productSymbols as string[])[i]!,
      assetSymbol: (e.productAssetSymbols as string[])[i]!,
      underlying: (e.productUnderlyings as Hex[])[i]!,
      settlementAsset: (e.productSettlementAssets as Hex[])[i]!,
      weth: e.weth as Hex,
      usdc: e.usdc as Hex,
      pyth: e.pyth as Hex,
      pythFeedId: (e.productPythFeedIds as Hex[])[i]!,
      pythQuoteFeedId: ((e.productPythQuoteFeedIds as Hex[] | undefined)?.[i] ?? zeroFeedId) as Hex,
      settlementFeed: (e.productSettlementFeeds as Hex[])[i]!,
      settlementConfigId: (e.productSettlementConfigIds as Hex[])[i]!,
      riskSetId: (e.productRiskSetIds as Hex[])[i]!,
      kuruRouter: e.kuruRouter as Hex,
      expiries: allExpiries,
      seriesIds: (e.seriesIds as Hex[]).slice(starts[i]!, starts[i + 1]!),
      kuruBooks: (e.kuruBooks as Hex[]).slice(starts[i]!, starts[i + 1]!),
      optaraDirectBooks: ((e.optaraDirectBooks as Hex[] | undefined) ?? []).slice(starts[i]!, starts[i + 1]!),
      spotWad: BigInt((e.productSpotWads as string[] | number[] | bigint[])[i]!),
    }));
  }
  return [
    {
      productId: e.ethUsdcProductId as Hex,
      underlyingSymbol: "ETH",
      assetSymbol: "USDC",
      underlying: e.weth as Hex,
      settlementAsset: e.usdc as Hex,
      weth: e.weth as Hex,
      usdc: e.usdc as Hex,
      pyth: e.pyth as Hex,
      pythFeedId: e.ethUsdcPythFeedId as Hex,
      pythQuoteFeedId: (e.ethUsdcPythQuoteFeedId ?? zeroFeedId) as Hex,
      settlementFeed: e.ethUsdcSettlementFeed as Hex,
      settlementConfigId: e.ethUsdcSettlementConfigId as Hex,
      riskSetId: e.ethUsdcRiskSetId as Hex,
      kuruRouter: e.kuruRouter as Hex,
      expiries: allExpiries,
      seriesIds: e.seriesIds as Hex[],
      kuruBooks: e.kuruBooks as Hex[],
      optaraDirectBooks: (e.optaraDirectBooks as Hex[] | undefined) ?? [],
      spotWad: 4000n * 10n ** 18n,
    },
  ];
}

export function stackProduct(m: Manifest) {
  return stackProducts(m)[0]!;
}
export * from "./actions.ts";
export * from "./settlementFeeds.ts";

/** A wallet client for stack account `index` on this stack's anvil. */
export const walletFor = (s: LocalStack, index: number) =>
  createWalletClient({ chain: anvilChain, transport: http(s.anvil.rpcUrl), account: stackAccount(index), pollingInterval: POLL_MS });
