/**
 * Indexer API, health worker and monitor (alongside `envio start`). Environment:
 *   RPC_URL, CHAIN_ID, MANIFEST                                   required
 *   ENVIO_PG_HOST/PORT/USER/PASSWORD/DATABASE, ENVIO_PG_SCHEMA    the indexer's Postgres (Envio's variables)
 *   PORT (8787), HEALTH_INTERVAL_SECONDS (15), RECONCILE_INTERVAL_SECONDS (300)
 */
import { connect } from "@optara/sdk";
import { loadManifest } from "@optara/sdk/node";
import { Db } from "./db.ts";
import { Monitor } from "./monitor.ts";
import { startApi } from "./server.ts";

const env = (k: string, d?: string) => {
  const v = process.env[k] ?? d;
  if (v === undefined) throw new Error(`${k} is required`);
  return v;
};

async function main() {
  const chainId = Number(env("CHAIN_ID"));
  const manifest = loadManifest(env("MANIFEST"));
  if (manifest.chainId !== chainId) throw new Error("manifest chain id differs from CHAIN_ID");
  const { public: client } = await connect(env("RPC_URL"), chainId);
  const db = new Db({
    host: process.env.ENVIO_PG_HOST,
    port: process.env.ENVIO_PG_PORT ? Number(process.env.ENVIO_PG_PORT) : undefined,
    user: process.env.ENVIO_PG_USER,
    password: process.env.ENVIO_PG_PASSWORD,
    database: process.env.ENVIO_PG_DATABASE,
    schema: process.env.ENVIO_PG_SCHEMA,
    chainId,
  });
  const monitor = new Monitor(db, client, manifest);
  const log = (msg: string) => console.log(`${new Date().toISOString()} ${msg}`);
  await startApi({ db, monitor, client, manifest }, Number(process.env.PORT ?? 8787));
  log(`indexer API on :${process.env.PORT ?? 8787}`);

  const loop = (name: string, seconds: number, fn: () => Promise<void>) =>
    (async () => {
      for (;;) {
        try {
          await fn();
        } catch (e) {
          log(`${name}: ${(e as Error).message.split("\n")[0]}`);
        }
        await new Promise((r) => setTimeout(r, seconds * 1000));
      }
    })();
  await Promise.all([
    loop("health", Number(process.env.HEALTH_INTERVAL_SECONDS ?? 15), () => monitor.refreshHealth()),
    loop("reconcile", Number(process.env.RECONCILE_INTERVAL_SECONDS ?? 300), async () => {
      const m = await monitor.reconcile();
      for (const a of m) log(`ALERT ${a.kind} ${a.subject}: ${a.detail}`);
    }),
  ]);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
