/** Node-only helpers (filesystem). Browser code imports "@optara/sdk" only. */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { parseManifest, type Manifest } from "./manifest.ts";
import { HermesSource } from "./pyth.ts";
import { CompositeSpotSource, REDSTONE_PUBLIC_GATEWAYS, SignedPriceSource } from "./signedPrices.ts";

/** The repository's deployments/ directory. */
export const DEPLOYMENTS_DIR = fileURLToPath(new URL("../../deployments", import.meta.url));

/** Reads `deployments/<network>.json`, or a manifest file when given a path ending in `.json`. */
export function loadManifest(networkOrPath: string): Manifest {
  const path = networkOrPath.endsWith(".json") ? networkOrPath : join(DEPLOYMENTS_DIR, `${networkOrPath}.json`);
  return parseManifest(JSON.parse(readFileSync(path, "utf8")));
}

export { CompositeSpotSource, REDSTONE_PUBLIC_GATEWAYS, SignedPriceSource, isNamedFeedId, namedFeedId, type SignedPriceOptions } from "./signedPrices.ts";

/** `deployments/config/<network>.json` (roles, Pyth, Kuru, RedStone signers), or undefined if there is none. */
export function loadNetworkConfig(network: string): Record<string, any> | undefined {
  try {
    return JSON.parse(readFileSync(join(DEPLOYMENTS_DIR, "config", `${network}.json`), "utf8"));
  } catch {
    return undefined;
  }
}

/**
 * The spot source for a network: Pyth (Hermes) for Pyth feed ids, and signed price packages for named feeds (e.g.
 * "MON"), routed per feed so each product can use either. Signed prices come from the network config's `priceNode`
 * section ({ urls, signers, threshold }: Optara's testnet price node) or, without one, from RedStone's gateways with
 * the on-chain signer set in the `redstone` section. PRICE_NODE_URLS (comma separated) overrides the URLs.
 */
export function spotSourceFor(o: { network: string; hermesUrl?: string; hermesApiKey?: string; hermesApiKeyHeader?: string }): CompositeSpotSource {
  const cfg = loadNetworkConfig(o.network);
  const node = cfg?.priceNode as { urls?: string[]; signers?: string[]; threshold?: number } | undefined;
  const rs = cfg?.redstone as { dataServiceId: string; signers: string[]; threshold: number } | undefined;
  const hermes = new HermesSource({ endpoint: o.hermesUrl ?? "https://pyth.dourolabs.app/hermes", apiKey: o.hermesApiKey, apiKeyHeader: o.hermesApiKeyHeader });
  const envUrls = (process.env.PRICE_NODE_URLS ?? "").split(",").map((u) => u.trim()).filter(Boolean);
  const urls = envUrls.length ? envUrls : node?.urls?.length ? node.urls : REDSTONE_PUBLIC_GATEWAYS;
  const signers = node?.signers?.length ? node.signers : rs?.signers;
  const threshold = node?.threshold ?? rs?.threshold;
  const signed = signers?.length && threshold
    ? new SignedPriceSource({ urls, dataServiceId: rs?.dataServiceId ?? "optara", authorizedSigners: signers, signersPerFeed: threshold })
    : undefined;
  return new CompositeSpotSource(hermes, signed);
}

/** The network name of a MANIFEST setting (a name like monad-testnet, or a path to <name>.json). */
export const networkName = (manifest: string) => manifest.replace(/^.*\//, "").replace(/\.json$/, "");
