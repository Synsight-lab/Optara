/**
 * Keepers. `tsx src/main.ts <oracle|settle|liquidate>...` runs the named loops. Environment:
 *   RPC_URL, CHAIN_ID, MANIFEST, KEEPER_PRIVATE_KEY            required
 *   SPOT_SOURCE = hermes | restamp; HERMES_URL, HERMES_API_KEY, HERMES_API_KEY_HEADER
 *   PUBLISHER_URL          a surface publisher (/surface, /oracle-update); used by oracle and liquidate
 *   PRODUCTS               product ids to keep fresh (comma separated; default: every listed product)
 *   ORACLE_ALWAYS=1        push spot without open interest (testnets)
 *   INDEXER_URL            participant and candidate lists from the indexer API (default: the ledger's events)
 *   LIQUIDATOR_ACCOUNT_ID  the bot's funded subaccount; MIN_PROFIT (native units), SLICE_BPS
 *   SETTLE_BATCH (50), INTERVAL_SECONDS (oracle: maxSpotAge / 2 = 30; settle 60; liquidate 15), GAS_BUFFER_BPS (1000)
 */
import { privateKeyToAccount } from "viem/accounts";
import type { Hex } from "viem";
import { connect, HermesSource, LedgerLogDirectory, RestampMockPythSource, SeriesCatalog, type AccountDirectory, type SpotSource } from "@optara/sdk";
import { loadManifest } from "@optara/sdk/node";
import { IndexerDirectory } from "./indexerDirectory.ts";
import { LiquidationBot } from "./liquidationBot.ts";
import { OraclePusher } from "./oraclePusher.ts";
import { PublisherFeed, SpotOnlyFeed } from "./oracleFeed.ts";
import { SettlementKeeper } from "./settlementKeeper.ts";
import type { Ctx } from "./tx.ts";

const env = (k: string, d?: string) => {
  const v = process.env[k] ?? d;
  if (v === undefined) throw new Error(`${k} is required`);
  return v;
};

async function main() {
  const modes = process.argv.slice(2);
  if (modes.length === 0 || modes.some((x) => !["oracle", "settle", "liquidate"].includes(x))) {
    throw new Error("usage: main.ts <oracle|settle|liquidate>...");
  }
  const manifest = loadManifest(env("MANIFEST"));
  const account = privateKeyToAccount(env("KEEPER_PRIVATE_KEY") as Hex);
  const { public: client, wallet } = await connect(env("RPC_URL"), Number(env("CHAIN_ID")), account);
  if (manifest.chainId !== Number(env("CHAIN_ID"))) throw new Error("manifest chain id differs from CHAIN_ID");
  const log = (msg: string) => console.log(`${new Date().toISOString()} ${msg}`);
  const ctx: Ctx = { client, wallet: wallet!, log, gasBufferBps: BigInt(process.env.GAS_BUFFER_BPS ?? "1000") };

  const chunk = BigInt(process.env.LOG_CHUNK ?? "100");
  const from = BigInt(manifest.deployedAtBlock);
  const catalog = new SeriesCatalog(client, manifest.proxies.OptionSeriesRegistry.proxy, from, chunk);
  const directory: AccountDirectory = process.env.INDEXER_URL
    ? new IndexerDirectory(process.env.INDEXER_URL)
    : new LedgerLogDirectory(client, manifest.proxies.SubAccounts.proxy, from, chunk);
  const spot: SpotSource =
    (process.env.SPOT_SOURCE ?? (manifest.chainId === 31337 ? "restamp" : "hermes")) === "restamp"
      ? new RestampMockPythSource(client, (manifest.extra as any).pyth)
      : new HermesSource({ endpoint: env("HERMES_URL", "https://pyth.dourolabs.app/hermes"), apiKey: process.env.HERMES_API_KEY, apiKeyHeader: process.env.HERMES_API_KEY_HEADER });

  const loops: Promise<never>[] = [];
  const every = (name: string, seconds: number, fn: () => Promise<unknown>) =>
    loops.push(
      (async () => {
        for (;;) {
          try {
            await fn();
          } catch (e) {
            log(`${name}: ${(e as Error).message.split("\n")[0]}`);
          }
          await new Promise((r) => setTimeout(r, seconds * 1000));
        }
      })(),
    );

  if (modes.includes("oracle")) {
    await catalog.sync();
    const products = process.env.PRODUCTS
      ? (process.env.PRODUCTS.split(",") as Hex[])
      : [...new Set(catalog.all().map((s) => s.productId))];
    const pusher = new OraclePusher(ctx, { manifest, products, spot, catalog, publisherUrl: process.env.PUBLISHER_URL, always: process.env.ORACLE_ALWAYS === "1" });
    every("oracle", Number(process.env.INTERVAL_SECONDS ?? 30), () => pusher.tick());
  }
  if (modes.includes("settle")) {
    const keeper = new SettlementKeeper(ctx, { manifest, catalog, directory, batchSize: Number(process.env.SETTLE_BATCH ?? 50) });
    every("settle", Number(process.env.INTERVAL_SECONDS ?? 60), async () => {
      const r = await keeper.tick();
      for (const e of r.errors) log(`settle: ${e}`);
    });
  }
  if (modes.includes("liquidate")) {
    const feed = process.env.PUBLISHER_URL ? new PublisherFeed(process.env.PUBLISHER_URL) : new SpotOnlyFeed(client, manifest, spot);
    const bot = new LiquidationBot(ctx, {
      manifest,
      directory,
      liquidatorAccountId: BigInt(env("LIQUIDATOR_ACCOUNT_ID")),
      feed,
      minProfitNative: BigInt(process.env.MIN_PROFIT ?? "0"),
      sliceBps: process.env.SLICE_BPS ? Number(process.env.SLICE_BPS) : undefined,
    });
    every("liquidate", Number(process.env.INTERVAL_SECONDS ?? 15), async () => {
      const r = await bot.tick();
      for (const x of r.skipped) log(`liquidate: ${x}`);
    });
  }
  log(`keeper ${account.address}: ${modes.join(", ")}`);
  await Promise.all(loops);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
