import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { chainFor, loadManifest, NETWORK } from "./networks.ts";

export const manifest = loadManifest(NETWORK);
export const chain = chainFor(manifest, import.meta.env.VITE_RPC_URL);

export const wagmiConfig = createConfig({
  chains: [chain],
  connectors: [injected()],
  transports: { [chain.id]: http(chain.rpcUrls.default.http[0], { batch: false }) },
  // Always read fresh chain state: previews must reflect the latest block (SECURITY.md section 77).
  cacheTime: 0,
});
