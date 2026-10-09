/**
 * The network the app talks to (FRONTEND.md §1: addresses and ABIs come from `deployments/<network>.json`).
 *   VITE_NETWORK         local (default) | monad-testnet | monad-mainnet
 *   VITE_RPC_URL         defaults to the network's public RPC (local: http://127.0.0.1:8545)
 *   VITE_PUBLISHER_URL   surface publisher (/oracle-update); local default http://127.0.0.1:8790
 *   VITE_INDEXER_URL     indexer API; optional (lists fall back to on-chain events)
 */
import { chainFor, parseManifest, type Manifest } from "@optara/sdk";
import type { Chain } from "viem";

const files = import.meta.glob("../../../deployments/*.json", { eager: true, import: "default" }) as Record<string, unknown>;

/** Deployed networks found in deployments/ (test, dry-run and rehearsal manifests excluded). */
export const MANIFESTS: Record<string, Manifest> = Object.fromEntries(
  Object.entries(files)
    .map(([path, raw]) => [path.split("/").pop()!.replace(/\.json$/, ""), raw] as const)
    .filter(([name]) => !/^(e2e|fe2e|demo|rehearsal)|\./.test(name))
    .map(([name, raw]) => [name, parseManifest(raw)]),
);

const env = import.meta.env;
export const NETWORK = (env.VITE_NETWORK as string | undefined) ?? "local";
// Any manifest file can be selected explicitly (the test suites use their own); the list above is what's offered.
const rawSelected = Object.entries(files).find(([path]) => path.endsWith(`/${NETWORK}.json`))?.[1];
const manifest = MANIFESTS[NETWORK] ?? (rawSelected ? parseManifest(rawSelected) : undefined);
if (!manifest) throw new Error(`No deployment manifest for network "${NETWORK}" in deployments/`);
export const MANIFEST: Manifest = manifest;

const DEFAULT_RPC: Record<number, string> = {
  31337: "http://127.0.0.1:8545",
  10143: "https://testnet-rpc.monad.xyz",
  143: "https://rpc.monad.xyz",
};

export const RPC_URL: string = (env.VITE_RPC_URL as string | undefined) ?? DEFAULT_RPC[MANIFEST.chainId] ?? "";
export const CHAIN: Chain = chainFor(MANIFEST.chainId, RPC_URL);
const LOCAL_RPC = /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?(\/|$)/.test(RPC_URL);
export const IS_LOCAL = MANIFEST.chainId === 31337 || (NETWORK === "local" && LOCAL_RPC);
/** A local fork of a real chain: same chain id as the real network, so browser wallets would sign for the real one. */
export const IS_LOCAL_FORK = IS_LOCAL && MANIFEST.chainId !== 31337;
export const PUBLISHER_URL: string = (env.VITE_PUBLISHER_URL as string | undefined) ?? (IS_LOCAL ? "http://127.0.0.1:8790" : "");
export const INDEXER_URL: string | undefined = (env.VITE_INDEXER_URL as string | undefined) || undefined;
export const EXPLORER_URL: string | undefined =
  MANIFEST.chainId === 143 ? "https://monadvision.com" : MANIFEST.chainId === 10143 ? "https://testnet.monadvision.com" : undefined;

export const NETWORK_LABEL: Record<number, string> = { 31337: "Local devnet", 10143: "Monad Testnet", 143: "Monad" };
