/** Node-only helpers (filesystem). Browser code imports "@optara/sdk" only. */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { parseManifest, type Manifest } from "./manifest.ts";
import { HermesSource } from "./pyth.ts";
import { CompositeSpotSource, RedstoneSource } from "./redstone.ts";

/** The repository's deployments/ directory. */
export const DEPLOYMENTS_DIR = fileURLToPath(new URL("../../deployments", import.meta.url));

/** Reads `deployments/<network>.json`, or a manifest file when given a path ending in `.json`. */
export function loadManifest(networkOrPath: string): Manifest {
  const path = networkOrPath.endsWith(".json") ? networkOrPath : join(DEPLOYMENTS_DIR, `${networkOrPath}.json`);
  return parseManifest(JSON.parse(readFileSync(path, "utf8")));
}

export { CompositeSpotSource, RedstoneSource, isRedstoneFeedId, redstoneFeedId, type RedstoneOptions } from "./redstone.ts";

/** `deployments/config/<network>.json` (roles, Pyth, Kuru, RedStone signers), or undefined if there is none. */
export function loadNetworkConfig(network: string): Record<string, any> | undefined {
  try {
    return JSON.parse(readFileSync(join(DEPLOYMENTS_DIR, "config", `${network}.json`), "utf8"));
  } catch {
    return undefined;
  }
}

/**
 * The spot source for a network: Pyth (Hermes) for Pyth feed ids and RedStone for RedStone feed names, routed per
 * feed, so each product can use either. RedStone is configured from the network config's `redstone` section.
 */
export function spotSourceFor(o: { network: string; hermesUrl?: string; hermesApiKey?: string; hermesApiKeyHeader?: string }): CompositeSpotSource {
  const rs = loadNetworkConfig(o.network)?.redstone as { dataServiceId: string; signers: string[]; threshold: number } | undefined;
  const hermes = new HermesSource({ endpoint: o.hermesUrl ?? "https://pyth.dourolabs.app/hermes", apiKey: o.hermesApiKey, apiKeyHeader: o.hermesApiKeyHeader });
  const redstone = rs?.signers?.length
    ? new RedstoneSource({ dataServiceId: rs.dataServiceId, authorizedSigners: rs.signers, signersPerFeed: rs.threshold })
    : undefined;
  return new CompositeSpotSource(hermes, redstone);
}

/** The network name of a MANIFEST setting (a name like monad-testnet, or a path to <name>.json). */
export const networkName = (manifest: string) => manifest.replace(/^.*\//, "").replace(/\.json$/, "");
