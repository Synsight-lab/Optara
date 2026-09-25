import { createPublicClient, createWalletClient, defineChain, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { loadConfig } from "./config.ts";
import { Store } from "./db.ts";
import { Indexer } from "./indexer.ts";
import { reconcile } from "./reconcile.ts";
import { startApi } from "./api.ts";
import { keeperTick } from "./keeper.ts";

const cfg = loadConfig();
const chain = defineChain({
  id: cfg.chainId,
  name: cfg.manifest.network,
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: [cfg.rpcUrl] } },
});
const client = createPublicClient({ chain, transport: http(cfg.rpcUrl), cacheTime: 0 });

const onChainId = await client.getChainId();
if (onChainId !== cfg.chainId) throw new Error(`RPC chain ${onChainId} != configured ${cfg.chainId}`);

const store = new Store(cfg.dbPath);
const indexer = new Indexer(client, store, cfg);
const server = startApi({ store, client, cfg, cursor: () => indexer.cursor() });

const keeperKey = process.argv.includes("--keeper") ? (process.env.KEEPER_PRIVATE_KEY as Hex | undefined) : undefined;
if (process.argv.includes("--keeper") && !keeperKey) throw new Error("--keeper requires KEEPER_PRIVATE_KEY");
const wallet = keeperKey ? createWalletClient({ chain, transport: http(cfg.rpcUrl), account: privateKeyToAccount(keeperKey) }) : undefined;

console.log(`[optara-indexer] ${cfg.manifest.network} chain=${cfg.chainId} core=${cfg.manifest.contracts.OptaraCore} api=:${cfg.port}`);

let tick = 0;
let stopping = false;
async function loop() {
  while (!stopping) {
    try {
      const r = await indexer.syncOnce();
      if (r.rolledBackTo !== undefined) console.warn(`[optara-indexer] reorg: rolled back to ${r.rolledBackTo}`);
      if (r.events > 0) console.log(`[optara-indexer] indexed ${r.events} events up to ${r.toBlock}`);
      if (tick % cfg.reconcileEveryTicks === 0) {
        const now = Number((await client.getBlock()).timestamp);
        const rep = await reconcile(client, store, cfg, now);
        for (const a of rep.alerts) console.warn(`[optara-indexer] ALERT ${a.kind} ${a.subject}: ${a.detail}`);
        if (wallet) {
          const k = await keeperTick(client, wallet, store, cfg, BigInt(now));
          if (k.finalized.length || k.synced.length) console.log(`[keeper] finalized ${k.finalized.length}, synced ${k.synced.length}`);
          for (const e of k.errors) console.warn(`[keeper] ${e}`);
        }
      }
    } catch (e) {
      console.error(`[optara-indexer] tick failed: ${(e as Error).message}`);
    }
    tick++;
    await new Promise((r) => setTimeout(r, cfg.pollIntervalMs));
  }
}

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    stopping = true;
    server.close();
    store.close();
    process.exit(0);
  });
}
await loop();
