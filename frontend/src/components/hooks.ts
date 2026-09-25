import { usePublicClient } from "wagmi";
import type { PublicClient } from "viem";
import { manifest, chain } from "../config/wagmi.ts";

export function useOptara() {
  const client = usePublicClient({ chainId: chain.id }) as PublicClient;
  return { client, manifest, chain };
}
