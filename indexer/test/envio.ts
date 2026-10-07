/**
 * Runs the real indexer (`envio start`) against a test anvil, in its own Postgres schema, for the e2e suites.
 * Needs Postgres at localhost:5433 (postgres / testing, database envio-dev): `pnpm exec envio local docker up`
 * locally, a service container in CI. Hasura is not used (the API reads Postgres directly).
 */
import { spawn, type ChildProcess } from "node:child_process";
import { createWriteStream, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadManifest } from "@optara/sdk";
import { configYaml } from "../scripts/config.ts";
import { Db } from "../api/db.ts";

const INDEXER_DIR = fileURLToPath(new URL("..", import.meta.url));

export interface RunningIndexer {
  db: Db;
  schema: string;
  log: string;
  waitFor(block: bigint, timeoutMs?: number): Promise<void>;
  stop(): Promise<void>;
}

export async function startEnvio(manifestPath: string, rpcUrl: string, name: string): Promise<RunningIndexer> {
  const schema = `e2e_${name}_${Date.now() % 1_000_000}`;
  const configFile = `config.e2e-${name}.yaml`;
  writeFileSync(join(INDEXER_DIR, configFile), configYaml(loadManifest(manifestPath), manifestPath));
  const log = join(tmpdir(), `optara-envio-${schema}.log`);
  const out = createWriteStream(log);
  const port = 9900 + Math.floor(Math.random() * 90);
  const proc: ChildProcess = spawn("pnpm", ["exec", "envio", "start"], {
    cwd: INDEXER_DIR,
    env: { ...process.env, ENVIO_CONFIG: configFile, ENVIO_RPC_URL: rpcUrl, ENVIO_PG_SCHEMA: schema, ENVIO_INDEXER_PORT: String(port), ENVIO_TUI: "false", ENVIO_HASURA: "false" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  proc.stdout!.pipe(out);
  proc.stderr!.pipe(out);
  const db = new Db({ schema, chainId: 31337 });
  const exited = new Promise<void>((r) => proc.once("exit", () => r()));

  return {
    db,
    schema,
    log,
    async waitFor(block: bigint, timeoutMs = 180_000) {
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        if (proc.exitCode !== null) throw new Error(`envio exited (${proc.exitCode}); log: ${log}`);
        try {
          if (BigInt(await db.progressBlock()) >= block) return;
        } catch {
          // tables not created yet
        }
        if (Date.now() > deadline) throw new Error(`indexer did not reach block ${block}; log: ${log}`);
        await new Promise((r) => setTimeout(r, 250));
      }
    },
    async stop() {
      if (proc.exitCode === null) {
        proc.kill("SIGTERM");
        await Promise.race([exited, new Promise((r) => setTimeout(r, 10_000))]);
        if (proc.exitCode === null) proc.kill("SIGKILL");
      }
      try {
        await db.sql.unsafe(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
      } finally {
        await db.close();
        rmSync(join(INDEXER_DIR, configFile), { force: true });
      }
    },
  };
}
