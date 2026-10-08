/**
 * `pnpm dev` (repo root): a complete local Optara for the app, in one command.
 *   1. anvil on :8545 (Monad's 128 KB code size limit)
 *   2. the production local stack (contract/script/local/LocalStack.s.sol → deployments/local.json)
 *   3. a market maker quoting every Kuru book 5% around the protocol's mark, 5 options each side
 *   4. two surface publishers (A on :8790 cosigned by B on :8791) and the keepers (oracle pusher, settlement)
 *   5. periodic Pyth spot restamps for every listed product (DEVNET_LIVE_PRICE_RESTAMP=0 to keep them still)
 *   6. the app on http://localhost:5173
 * Test wallets (Alice…Erin) hold 100,000 USDC each; pick one from "Connect wallet".
 *
 * Mainnet fork mode:
 *   pnpm dev:fork
 *   DEVNET_FORK_URL=https://rpc.monad.xyz pnpm dev
 *   DEVNET_FORK_BLOCK=123456 pnpm dev:fork
 * This deploys the same local Optara stack on top of an Anvil fork, then forces the app/services to use localhost.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { connect } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createTestClient, http, publicActions, walletActions, type Address, type Hex } from "viem";
import { loadManifest } from "@optara/sdk/node";
import { anvil as anvilChain, chainFor, optionSeriesRegistryAbi } from "@optara/sdk";
import { freshOracleUpdateForProduct, pushOracles, quoteBooks, stackAccount, stackPrivateKey, stackProducts, type LocalStack } from "@optara/sdk/testing";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const RPC = "http://127.0.0.1:8545";
const DEFAULT_FORK_URL = "https://rpc.monad.xyz";
const FORK_URL = process.env.DEVNET_FORK_URL || process.env.FORK_RPC_URL;
const FORK_BLOCK = process.env.DEVNET_FORK_BLOCK || process.env.FORK_BLOCK_NUMBER;
const FORK_MODE = process.env.DEVNET_FORK === "1" || !!FORK_URL;
const procs: ChildProcess[] = [];
const log = (m: string) => console.log(`\x1b[35m[devnet]\x1b[0m ${m}`);

function run(name: string, cmd: string, args: string[], env: Record<string, string> = {}, cwd = ROOT) {
  // Its own process group, so stopping it also stops what it started (pnpm → tsx → node).
  const p = spawn(cmd, args, { cwd, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"], detached: true });
  const tag = `\x1b[36m[${name}]\x1b[0m `;
  p.stdout?.on("data", (d) => process.stdout.write(String(d).split("\n").filter(Boolean).map((l) => tag + l).join("\n") + "\n"));
  p.stderr?.on("data", (d) => process.stderr.write(String(d).split("\n").filter(Boolean).map((l) => tag + l).join("\n") + "\n"));
  procs.push(p);
  return p;
}

const shutdown = () => {
  for (const p of procs) {
    try {
      if (p.pid) process.kill(-p.pid, "SIGTERM");
    } catch {
      // already gone
    }
  }
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

const PORTS = { 8545: "anvil", 8790: "publisher A", 8791: "publisher B", 5173: "the app" } as const;

/** True when nothing answers on the port (another `pnpm dev` or anvil would make this run deploy onto its chain). */
const portFree = (port: number) =>
  new Promise<boolean>((resolve) => {
    const sock = connect({ port, host: "127.0.0.1" });
    sock.once("connect", () => (sock.destroy(), resolve(false)));
    sock.once("error", () => resolve(true));
  });

async function waitForRpc(anvil: ChildProcess): Promise<number> {
  const c = createTestClient({ chain: anvilChain, mode: "anvil", transport: http(RPC) });
  for (let i = 0; i < 100; i++) {
    if (anvil.exitCode !== null) throw new Error(`anvil exited (code ${anvil.exitCode})`);
    try {
      const id = await c.request({ method: "eth_chainId" } as any);
      return typeof id === "string" ? Number(BigInt(id)) : Number(id);
    } catch {
      await new Promise((r) => setTimeout(r, 150));
    }
  }
  throw new Error("anvil did not start");
}

function localStackBroadcastComplete(chainId: number, startedAt: number): boolean {
  const manifestPath = join(ROOT, "deployments", "local.json");
  const broadcastPath = join(ROOT, "contract", "broadcast", "LocalStack.s.sol", String(chainId), "run-latest.json");
  if (!existsSync(manifestPath) || !existsSync(broadcastPath)) return false;
  if (statSync(manifestPath).mtimeMs < startedAt || statSync(broadcastPath).mtimeMs < startedAt) return false;
  try {
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as { chainId?: number };
    const broadcast = JSON.parse(readFileSync(broadcastPath, "utf8")) as { chain?: number; pending?: unknown[]; transactions?: unknown[] };
    return manifest.chainId === chainId && broadcast.chain === chainId && (broadcast.transactions?.length ?? 0) > 0 && broadcast.pending?.length === 0;
  } catch {
    return false;
  }
}

async function rpcBlockTimestamp(): Promise<number> {
  const r = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getBlockByNumber", params: ["latest", false] }),
  });
  if (!r.ok) throw new Error(`latest block fetch failed: ${r.status} ${r.statusText}`);
  const j = (await r.json()) as { result?: { timestamp?: Hex } };
  if (!j.result?.timestamp) throw new Error(`latest block response missing timestamp: ${JSON.stringify(j).slice(0, 200)}`);
  return Number(BigInt(j.result.timestamp));
}

async function forgeLocalStack(chainId: number) {
  const startedAt = Date.now();
  const chainNow = await rpcBlockTimestamp();
  const p = run(
    "forge",
    "forge",
    [
      "script",
      "script/local/LocalStack.s.sol",
      "--rpc-url",
      RPC,
      "--broadcast",
      "--skip-simulation",
      "--disable-labels",
      "--offline",
      "--disable-code-size-limit",
      "-q",
    ],
    { NETWORK: "local", FOUNDRY_DISABLE_NIGHTLY_WARNING: "1", RUST_LOG: "error", ...(await livePriceEnv(chainNow)) },
    join(ROOT, "contract"),
  );

  let completeSince = 0;
  for (;;) {
    if (p.exitCode !== null) {
      if (p.exitCode === 0) return;
      throw new Error(`forge exited (code ${p.exitCode})`);
    }
    if (localStackBroadcastComplete(chainId, startedAt)) {
      completeSince ||= Date.now();
      if (Date.now() - completeSince > 10_000) {
        log("forge broadcast is complete; continuing after graceful-exit timeout");
        p.kill("SIGTERM");
        return;
      }
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
}

async function validateManifestSeries(s: LocalStack) {
  const now = (await s.test.getBlock()).timestamp;
  for (const product of stackProducts(s.manifest)) {
    for (let i = 0; i < product.seriesIds.length; i++) {
      if (product.expiries[Math.floor(i / 8)]! <= now) continue;
      const seriesId = product.seriesIds[i]!;
      const exists = await s.test.readContract({
        address: s.manifest.proxies.OptionSeriesRegistry.proxy,
        abi: optionSeriesRegistryAbi,
        functionName: "seriesExists",
        args: [seriesId],
      });
      if (exists) return;
      throw new Error(
        `manifest mismatch: first live ${product.underlyingSymbol}/${product.assetSymbol} series ${seriesId} is not registered on-chain`,
      );
    }
  }
  throw new Error("manifest has no live series left to quote");
}

type LivePrices = { ETH: number; BTC: number; MON: number; USDC: number; USDT: number };
const DEFAULT_PRICES: LivePrices = { ETH: 4000, BTC: 100_000, MON: 0.03, USDC: 1, USDT: 1 };
const ALLOW_STALE_PRICES = process.env.DEVNET_ALLOW_STALE_PRICES === "1";
const LIVE_PRICE_SOURCE = process.env.DEVNET_PRICE_SOURCE ?? "monad-pyth";
const MONAD_PYTH = (process.env.DEVNET_MONAD_PYTH || "0x2880aB155794e7179c9eE2e38200202908C17B43") as Address;
const LIVE_PYTH_RPC = process.env.DEVNET_PYTH_RPC_URL || FORK_URL || DEFAULT_FORK_URL;
const HERMES_URL = process.env.HERMES_URL || process.env.PYTH_HERMES_URL || "https://pyth.dourolabs.app/hermes";
const HERMES_API_KEY = process.env.HERMES_API_KEY || process.env.PYTH_API_KEY;
const HERMES_API_KEY_HEADER = process.env.HERMES_API_KEY_HEADER || process.env.PYTH_API_KEY_HEADER || "Authorization";
const PYTH_MAX_PRICE_AGE_SECONDS = Number(process.env.DEVNET_PYTH_MAX_PRICE_AGE_SECONDS ?? 300);
const PYTH_PRICE_IDS = {
  ETH: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
  BTC: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
  MON: "0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1",
  USDC: "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a",
  USDT: "0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b",
} as const satisfies Record<keyof LivePrices, Hex>;

type HermesPrice = {
  id: string;
  price: { price: string; expo: number; publish_time: number };
};

type PythPrice = {
  price: bigint;
  conf: bigint;
  expo: number;
  publishTime: bigint;
};

const pythAbi = [
  {
    type: "function",
    name: "getPriceUnsafe",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      {
        name: "price",
        type: "tuple",
        components: [
          { name: "price", type: "int64" },
          { name: "conf", type: "uint64" },
          { name: "expo", type: "int32" },
          { name: "publishTime", type: "uint256" },
        ],
      },
    ],
  },
] as const;

function authHeaders(): Record<string, string> {
  if (!HERMES_API_KEY) return {};
  return {
    [HERMES_API_KEY_HEADER]:
      HERMES_API_KEY_HEADER.toLowerCase() === "authorization" ? `Bearer ${HERMES_API_KEY}` : HERMES_API_KEY,
  };
}

function pythNumber(price: string | bigint, expo: number): number {
  return Number(price) * 10 ** expo;
}

function ensureFresh(symbol: string, publishTime: number) {
  const age = Math.floor(Date.now() / 1000) - publishTime;
  if (age > PYTH_MAX_PRICE_AGE_SECONDS) {
    throw new Error(`${symbol} Pyth price is stale (${age}s > ${PYTH_MAX_PRICE_AGE_SECONDS}s)`);
  }
}

function priceFromHermes(p: HermesPrice["price"]): number {
  return Number(p.price) * 10 ** p.expo;
}

async function monadPythPrices(): Promise<LivePrices> {
  const client = createPublicClient({ chain: chainFor(143, LIVE_PYTH_RPC), transport: http(LIVE_PYTH_RPC) });
  const entries = await Promise.all(
    Object.entries(PYTH_PRICE_IDS).map(async ([symbol, id]) => {
      const p = (await client.readContract({ address: MONAD_PYTH, abi: pythAbi, functionName: "getPriceUnsafe", args: [id] })) as PythPrice;
      ensureFresh(symbol, Number(p.publishTime));
      if (p.price <= 0n) throw new Error(`${symbol} Pyth price is non-positive`);
      return [symbol, pythNumber(p.price, p.expo)] as const;
    }),
  );
  return Object.fromEntries(entries) as LivePrices;
}

async function hermesPythPrices(): Promise<LivePrices> {
  const query = new URLSearchParams({ encoding: "hex", parsed: "true" });
  for (const id of Object.values(PYTH_PRICE_IDS)) query.append("ids[]", id);
  const r = await fetch(`${HERMES_URL.replace(/\/$/, "")}/v2/updates/price/latest?${query}`, {
    headers: { accept: "application/json", ...authHeaders() },
  });
  if (!r.ok) {
    const body = (await r.text()).slice(0, 200);
    const keyHint = r.status === 401 ? " (set HERMES_API_KEY or PYTH_API_KEY for Pyth Hermes, or leave DEVNET_PRICE_SOURCE unset to read Monad Pyth over RPC)" : "";
    throw new Error(`Hermes ${r.status} ${r.statusText}${keyHint}: ${body}`);
  }
  const j = (await r.json()) as { parsed?: HermesPrice[] };
  if (!j.parsed?.length) throw new Error(`missing parsed Pyth prices in response: ${JSON.stringify(j).slice(0, 300)}`);
  const byId = new Map(j.parsed.map((p) => [`0x${p.id.replace(/^0x/, "")}`.toLowerCase(), p]));
  const prices = Object.fromEntries(
    Object.entries(PYTH_PRICE_IDS).map(([symbol, id]) => {
      const parsed = byId.get(id.toLowerCase());
      if (!parsed) throw new Error(`Hermes response missing ${symbol}/${id}`);
      ensureFresh(symbol, parsed.price.publish_time);
      return [symbol, priceFromHermes(parsed.price)];
    }),
  ) as LivePrices;
  if (!prices.ETH || !prices.BTC || !prices.MON || !prices.USDC || !prices.USDT) throw new Error(`missing live price in response: ${JSON.stringify(j)}`);
  return prices;
}

async function pythPrices(): Promise<LivePrices> {
  if (process.env.DEVNET_LIVE_PRICES === "0") {
    if (!ALLOW_STALE_PRICES) throw new Error("DEVNET_LIVE_PRICES=0 requires DEVNET_ALLOW_STALE_PRICES=1");
    return DEFAULT_PRICES;
  }
  try {
    return LIVE_PRICE_SOURCE === "hermes" ? await hermesPythPrices() : await monadPythPrices();
  } catch (e) {
    if (LIVE_PRICE_SOURCE !== "hermes" && HERMES_API_KEY) {
      log(`Monad Pyth RPC price fetch failed, trying Hermes: ${(e as Error).message}`);
      return hermesPythPrices();
    }
    if (!ALLOW_STALE_PRICES) throw new Error(`Pyth live price fetch failed: ${(e as Error).message}`);
    log(`Pyth live price fetch failed, using explicit stale defaults: ${(e as Error).message}`);
    return DEFAULT_PRICES;
  }
}

async function livePriceEnv(chainNow = Math.floor(Date.now() / 1000)): Promise<Record<string, string>> {
  const p = await pythPrices();
  log(`Pyth seed prices: ETH $${p.ETH.toLocaleString()}, BTC $${p.BTC.toLocaleString()}, MON $${p.MON}, USDC $${p.USDC}, USDT $${p.USDT}`);
  const wad = (n: number) => BigInt(Math.round(n * 1e8)) * 10n ** 10n;
  const expiries = localExpiries(chainNow);
  return {
    LOCAL_ETH_PRICE_WAD: wad(p.ETH).toString(),
    LOCAL_BTC_PRICE_WAD: wad(p.BTC).toString(),
    LOCAL_MON_PRICE_WAD: wad(p.MON).toString(),
    LOCAL_USDC_PRICE_WAD: wad(p.USDC).toString(),
    LOCAL_USDT_PRICE_WAD: wad(p.USDT).toString(),
    LOCAL_EXPIRY_0: String(expiries[0]),
    LOCAL_EXPIRY_1: String(expiries[1]),
    LOCAL_EXPIRY_2: String(expiries[2]),
  };
}

function weeklyExpiries(now: number): [number, number] {
  const day = Math.floor((now + 2 * 24 * 60 * 60) / (24 * 60 * 60));
  const dow = (day + 4) % 7;
  const friday = (day + ((12 - dow) % 7)) * 24 * 60 * 60 + 8 * 60 * 60;
  return [friday, friday + 7 * 24 * 60 * 60];
}

function localExpiries(now: number): [number, number, number] {
  const near = Number(process.env.LOCAL_NEAR_EXPIRY_SECONDS ?? 75 * 60);
  const [w0, w1] = weeklyExpiries(now);
  return [now + Math.max(near, 65 * 60), w0, w1];
}

function priceForProduct(product: ReturnType<typeof stackProducts>[number], prices: LivePrices): number {
  const symbol = product.underlyingSymbol.toUpperCase();
  const quote = quotePriceForProduct(product, prices);
  if (symbol === "ETH") return prices.ETH / quote;
  if (symbol === "BTC") return prices.BTC / quote;
  if (symbol === "MON" || symbol === "WMON") return prices.MON / quote;
  return Number(product.spotWad) / 1e18;
}

function basePriceForProduct(product: ReturnType<typeof stackProducts>[number], prices: LivePrices): number {
  const symbol = product.underlyingSymbol.toUpperCase();
  if (symbol === "ETH") return prices.ETH;
  if (symbol === "BTC") return prices.BTC;
  if (symbol === "MON" || symbol === "WMON") return prices.MON;
  return Number(product.spotWad) / 1e18;
}

function quotePriceForProduct(product: ReturnType<typeof stackProducts>[number], prices: LivePrices): number {
  const symbol = product.assetSymbol.toUpperCase();
  if (symbol === "USDT") return prices.USDT;
  return prices.USDC;
}

async function pushLiveSpots(s: LocalStack, from: number, products = stackProducts(s.manifest)) {
  const prices = await pythPrices();
  await s.test.setBalance({ address: stackAccount(from).address, value: 10n ** 21n });
  for (const product of products) {
    const price = priceForProduct(product, prices);
    await s.test.increaseTime({ seconds: 1 });
    await pushOracles(
      s,
      from,
      await freshOracleUpdateForProduct(s, product, {
        price,
        basePrice: basePriceForProduct(product, prices),
        quotePrice: quotePriceForProduct(product, prices),
        surface: false,
      }),
    );
  }
  log(`Pyth spot restamp: ETH $${prices.ETH.toLocaleString()}, BTC $${prices.BTC.toLocaleString()}, MON $${prices.MON}, USDC $${prices.USDC}, USDT $${prices.USDT}`);
}

async function main() {
  const busy = [];
  for (const [port, what] of Object.entries(PORTS)) if (!(await portFree(Number(port)))) busy.push(`:${port} (${what})`);
  if (busy.length) {
    log(`already in use: ${busy.join(", ")}. Another \`pnpm dev\` (or anvil) is running — stop it first, e.g. \`pkill anvil\`.`);
    process.exit(1);
  }

  const anvilArgs = ["--port", "8545", "--code-size-limit", "131072", "--silent"];
  if (FORK_MODE) anvilArgs.push("--fork-url", FORK_URL || DEFAULT_FORK_URL);
  if (FORK_MODE && FORK_BLOCK) anvilArgs.push("--fork-block-number", FORK_BLOCK);
  log(FORK_MODE ? `starting anvil fork on :8545 (${FORK_URL || DEFAULT_FORK_URL}${FORK_BLOCK ? ` @ ${FORK_BLOCK}` : ""})` : "starting anvil on :8545");
  const anvil = run("anvil", "anvil", anvilArgs, { RUST_LOG: "error" });
  const chainId = await waitForRpc(anvil);
  const chain = chainFor(chainId, RPC);
  log(`anvil ready on chain ${chainId}${FORK_MODE ? " (forked)" : ""}`);

  log("deploying the local stack (forge)…");
  await forgeLocalStack(chainId);
  const manifest = loadManifest("local");
  const test = createTestClient({ chain, mode: "anvil", transport: http(RPC), pollingInterval: 50, cacheTime: 0 }).extend(publicActions).extend(walletActions);
  const s: LocalStack = { anvil: { rpcUrl: RPC, port: 8545, process: procs[0]!, stop: async () => {} }, manifest, test: test as LocalStack["test"] };

  await validateManifestSeries(s);
  log("market maker: quoting every book");
  await quoteBooks(s);

  log("starting publishers (:8790 cosigned by :8791) and keepers");
  const common = { RPC_URL: RPC, CHAIN_ID: String(chainId), MANIFEST: "local", SPOT_SOURCE: "restamp" };
  const key = stackPrivateKey;
  run("publisher-b", "pnpm", ["--filter", "@optara/publisher", "start"], { ...common, PORT: "8791", PUBLISHER_PRIVATE_KEY: key(3), INTERVAL_SECONDS: "3600" });
  await new Promise((r) => setTimeout(r, 2500));
  run("publisher-a", "pnpm", ["--filter", "@optara/publisher", "start"], { ...common, PORT: "8790", PUBLISHER_PRIVATE_KEY: key(2), COSIGNER_URLS: "http://127.0.0.1:8791", INTERVAL_SECONDS: "60" });
  run("keepers", "pnpm", ["--filter", "@optara/keepers", "start", "oracle", "settle"], { ...common, KEEPER_PRIVATE_KEY: key(4), PUBLISHER_URL: "http://127.0.0.1:8790", ORACLE_ALWAYS: "1", INTERVAL_SECONDS: "20" });

  if (process.env.DEVNET_LIVE_PRICE_RESTAMP !== "0") {
    // Its own account (10, funded here): sharing the deployer's or the keeper's would race their nonces.
    const PRICE_RESTAMPER = 10;
    const products = stackProducts(manifest);
    setInterval(async () => {
      try {
        await pushLiveSpots(s, PRICE_RESTAMPER, products);
      } catch (e) {
        log(`live spot restamp skipped: ${(e as Error).message.split("\n")[0]}`);
      }
    }, Number(process.env.DEVNET_LIVE_PRICE_SECONDS ?? 60) * 1000);
  }

  log("starting the app");
  run("app", "pnpm", ["--filter", "@optara/frontend", "dev", "--host", "127.0.0.1", "--strictPort"], {
    VITE_NETWORK: "local",
    VITE_RPC_URL: RPC,
    VITE_PUBLISHER_URL: "http://127.0.0.1:8790",
  });
  log("ready: open http://localhost:5173 and connect a test wallet (Alice…Erin). Ctrl+C stops everything.");
}

main().catch((e) => {
  console.error(e);
  shutdown();
});
