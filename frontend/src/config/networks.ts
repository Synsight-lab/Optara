import { defineChain, getAddress, type Address, type Chain, type Hex } from "viem";

/** Deployment manifest produced by contract/script/Deploy.s.sol. The SDK repo consumes the same file. */
export interface Manifest {
  network: string;
  chainId: number;
  coreVersion: string;
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
}

const manifests = import.meta.glob<Manifest>("../../../deployments/*.json", { eager: true, import: "default" });

export function loadManifest(network: string): Manifest {
  const entry = Object.entries(manifests).find(([path]) => path.endsWith(`/${network}.json`));
  if (!entry) throw new Error(`no deployment manifest for network "${network}" in deployments/`);
  const m = entry[1];
  return {
    ...m,
    contracts: Object.fromEntries(Object.entries(m.contracts).map(([k, v]) => [k, getAddress(v)])) as Manifest["contracts"],
  };
}

/** Known chains. RPC URLs for public networks must be configured explicitly (DEPLOYMENT.md section 84). */
export function chainFor(manifest: Manifest, rpcUrl: string | undefined): Chain {
  const defaults: Record<number, { name: string; rpc?: string }> = {
    31337: { name: "Local (anvil)", rpc: "http://127.0.0.1:8545" },
    10143: { name: "Monad Testnet" },
    143: { name: "Monad" },
  };
  const known = defaults[manifest.chainId];
  const rpc = rpcUrl ?? known?.rpc;
  if (!rpc) throw new Error(`set VITE_RPC_URL for chain ${manifest.chainId}`);
  return defineChain({
    id: manifest.chainId,
    name: known?.name ?? manifest.network,
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });
}

export const NETWORK = import.meta.env.VITE_NETWORK ?? "local";
export const INDEXER_URL: string | undefined = import.meta.env.VITE_INDEXER_URL;
