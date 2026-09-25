import { readFileSync } from "node:fs";
import { getAddress, type Address, type Hex } from "viem";

/** Deployment manifest written by contract/script/Deploy.s.sol (DEPLOYMENT.md section 19). */
export interface Manifest {
  network: string;
  chainId: number;
  coreVersion: string;
  deployBlock: number;
  protocolSeriesDomain: Hex;
  contracts: {
    OptaraCore: Address;
    OptaraConfig: Address;
    OracleRegistry: Address;
    ChainlinkSettlementAdapter: Address;
    SeriesFactory: Address;
  };
  assets: Address[];
  underlyings: Address[];
  oracleConfigIds: Hex[];
  pairIds: Hex[];
}

export interface IndexerConfig {
  rpcUrl: string;
  chainId: number;
  manifest: Manifest;
  startBlock: bigint;
  /** Blocks behind head that are treated as final; only these are indexed. */
  confirmations: bigint;
  /** Max block range per eth_getLogs call. */
  batchSize: bigint;
  pollIntervalMs: number;
  reconcileEveryTicks: number;
  dbPath: string;
  port: number;
  /** Alert when a scope's exposure exceeds this fraction (in basis points) of its cap. */
  capAlertBps: bigint;
  kuruMarketsPath?: string;
}

function required(name: string): string {
  const v = process.env[name];
  if (v === undefined || v === "") throw new Error(`missing required env ${name}`);
  return v;
}

export function loadManifest(path: string): Manifest {
  const raw = JSON.parse(readFileSync(path, "utf8")) as Manifest;
  const c = raw.contracts;
  return {
    ...raw,
    contracts: {
      OptaraCore: getAddress(c.OptaraCore),
      OptaraConfig: getAddress(c.OptaraConfig),
      OracleRegistry: getAddress(c.OracleRegistry),
      ChainlinkSettlementAdapter: getAddress(c.ChainlinkSettlementAdapter),
      SeriesFactory: getAddress(c.SeriesFactory),
    },
    assets: raw.assets.map((a) => getAddress(a)),
    underlyings: raw.underlyings.map((a) => getAddress(a)),
  };
}

/** No silent defaults for the chain or deployment; operational knobs have documented defaults. */
export function loadConfig(env = process.env): IndexerConfig {
  const manifest = loadManifest(env.OPTARA_MANIFEST ?? required("OPTARA_MANIFEST"));
  const chainId = Number(env.CHAIN_ID ?? required("CHAIN_ID"));
  if (chainId !== manifest.chainId) {
    throw new Error(`CHAIN_ID ${chainId} does not match manifest chainId ${manifest.chainId}`);
  }
  return {
    rpcUrl: env.RPC_URL ?? required("RPC_URL"),
    chainId,
    manifest,
    startBlock: BigInt(env.START_BLOCK ?? manifest.deployBlock ?? 0),
    confirmations: BigInt(env.CONFIRMATIONS ?? "2"),
    batchSize: BigInt(env.BATCH_SIZE ?? "1000"),
    pollIntervalMs: Number(env.POLL_INTERVAL_MS ?? "2000"),
    reconcileEveryTicks: Number(env.RECONCILE_EVERY_TICKS ?? "10"),
    dbPath: env.DB_PATH ?? "optara-indexer.sqlite",
    port: Number(env.PORT ?? "8787"),
    capAlertBps: BigInt(env.CAP_ALERT_BPS ?? "9000"),
    kuruMarketsPath: env.KURU_MARKETS,
  };
}
