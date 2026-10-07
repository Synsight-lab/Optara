/**
 * `pnpm dev` (repo root): a complete local Optara for the app, in one command.
 *   1. anvil on :8545 (Monad's 128 KB code size limit)
 *   2. the production local stack (contract/script/local/LocalStack.s.sol → deployments/local.json)
 *   3. a market maker quoting every Kuru book 5% around the protocol's mark, 5 options each side
 *   4. two surface publishers (A on :8790 cosigned by B on :8791) and the keepers (oracle pusher, settlement)
 *   5. a gentle random walk of the ETH price (DEVNET_WIGGLE=0 to keep it still)
 *   6. the app on http://localhost:5173
 * Test wallets (Alice…Erin) hold 100,000 USDC each; pick one from "Connect wallet".
 */
import { spawn, type ChildProcess } from "node:child_process";
import { connect } from "node:net";
import { fileURLToPath } from "node:url";
import { createTestClient, http, publicActions, walletActions } from "viem";
import { loadManifest } from "@optara/sdk/node";
import { anvil as anvilChain } from "@optara/sdk";
import { forgeScript, freshOracleUpdate, pushOracles, quoteBooks, stackAccount, stackPrivateKey, type LocalStack } from "@optara/sdk/testing";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const RPC = "http://127.0.0.1:8545";
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

async function waitForRpc(anvil: ChildProcess) {
  const c = createTestClient({ chain: anvilChain, mode: "anvil", transport: http(RPC) });
  for (let i = 0; i < 100; i++) {
    if (anvil.exitCode !== null) throw new Error(`anvil exited (code ${anvil.exitCode})`);
    try {
      return await c.request({ method: "eth_chainId" } as any);
    } catch {
      await new Promise((r) => setTimeout(r, 150));
    }
  }
  throw new Error("anvil did not start");
}

async function main() {
  const busy = [];
  for (const [port, what] of Object.entries(PORTS)) if (!(await portFree(Number(port)))) busy.push(`:${port} (${what})`);
  if (busy.length) {
    log(`already in use: ${busy.join(", ")}. Another \`pnpm dev\` (or anvil) is running — stop it first, e.g. \`pkill anvil\`.`);
    process.exit(1);
  }

  log("starting anvil on :8545");
  const anvil = run("anvil", "anvil", ["--port", "8545", "--code-size-limit", "131072", "--silent"]);
  await waitForRpc(anvil);

  log("deploying the local stack (forge)…");
  forgeScript("script/local/LocalStack.s.sol", RPC, { NETWORK: "local" });
  const manifest = loadManifest("local");
  const test = createTestClient({ chain: anvilChain, mode: "anvil", transport: http(RPC), pollingInterval: 50, cacheTime: 0 }).extend(publicActions).extend(walletActions);
  const s: LocalStack = { anvil: { rpcUrl: RPC, port: 8545, process: procs[0]!, stop: async () => {} }, manifest, test };

  log("market maker: quoting every book");
  await pushOracles(s, 4, await freshOracleUpdate(s, { price: 4000 }));
  await quoteBooks(s);

  log("starting publishers (:8790 cosigned by :8791) and keepers");
  const common = { RPC_URL: RPC, CHAIN_ID: "31337", MANIFEST: "local", SPOT_SOURCE: "restamp" };
  const key = stackPrivateKey;
  run("publisher-b", "pnpm", ["--filter", "@optara/publisher", "start"], { ...common, PORT: "8791", PUBLISHER_PRIVATE_KEY: key(3), INTERVAL_SECONDS: "3600" });
  await new Promise((r) => setTimeout(r, 2500));
  run("publisher-a", "pnpm", ["--filter", "@optara/publisher", "start"], { ...common, PORT: "8790", PUBLISHER_PRIVATE_KEY: key(2), COSIGNER_URLS: "http://127.0.0.1:8791", INTERVAL_SECONDS: "60" });
  run("keepers", "pnpm", ["--filter", "@optara/keepers", "start", "oracle", "settle"], { ...common, KEEPER_PRIVATE_KEY: key(4), PUBLISHER_URL: "http://127.0.0.1:8790", ORACLE_ALWAYS: "1", INTERVAL_SECONDS: "20" });

  if (process.env.DEVNET_WIGGLE !== "0") {
    // Its own account (10, funded here): sharing the deployer's or the keeper's would race their nonces.
    const WIGGLER = 10;
    await test.setBalance({ address: stackAccount(WIGGLER).address, value: 10n ** 21n });
    let price = 4000;
    setInterval(async () => {
      try {
        price = Math.max(2000, Math.min(8000, price * (1 + (Math.random() - 0.5) * 0.006)));
        await test.increaseTime({ seconds: 1 });
        await pushOracles(s, WIGGLER, await freshOracleUpdate(s, { price, surface: false }));
      } catch (e) {
        log(`price wiggle skipped: ${(e as Error).message.split("\n")[0]}`);
      }
    }, 15_000);
  }

  log("starting the app");
  run("app", "pnpm", ["--filter", "@optara/frontend", "dev", "--host", "127.0.0.1", "--strictPort"]);
  log("ready: open http://localhost:5173 and connect a test wallet (Alice…Erin). Ctrl+C stops everything.");
}

main().catch((e) => {
  console.error(e);
  shutdown();
});
