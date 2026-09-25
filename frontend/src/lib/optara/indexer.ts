import type { Hex } from "viem";

/** Optional indexer API client (indexer/). Advisory data only; the chain stays authoritative. */
export interface FinalizationProof {
  groupId: Hex;
  oracleConfigId: Hex;
  sourceIndex: 0 | 1;
  oracleData: Hex;
  quotedPriceWad?: string;
  observationTimestamp?: string;
  earliestFinalization: string;
  error?: string;
}

export async function fetchFinalizationProof(indexerUrl: string, groupId: Hex): Promise<FinalizationProof> {
  const r = await fetch(`${indexerUrl}/groups/${groupId}/finalization-proof`);
  if (!r.ok) throw new Error(`indexer returned ${r.status}`);
  return r.json();
}

export interface MarketEntry {
  seriesId: Hex;
  market: string;
  base: string;
  quote: string;
  chainId: number;
}

export async function fetchVerifiedMarkets(indexerUrl: string): Promise<MarketEntry[]> {
  const r = await fetch(`${indexerUrl}/markets`);
  if (!r.ok) return [];
  return (await r.json()).valid as MarketEntry[];
}
