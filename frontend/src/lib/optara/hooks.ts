/** Live data hooks (TanStack Query). Intervals keep prices and health current without a refresh button. */
import { useQuery, type UseQueryOptions } from "@tanstack/react-query";
import { useMemo } from "react";
import type { Address, Hex } from "viem";
import { IS_LOCAL } from "../../config/network.ts";
import { publicClient } from "./client.ts";
import {
  estimateLiquidationSpots,
  getAccount,
  getAccounts,
  getProductMarket,
  getSeriesList,
  getSeriesMarket,
  getTokenBalance,
  getWalletWrappers,
} from "./reads.ts";
import type { Series } from "./types.ts";

const FAST = IS_LOCAL ? 3_000 : 6_000;
const SLOW = IS_LOCAL ? 8_000 : 20_000;

export const useSeriesList = () => useQuery({ queryKey: ["series"], queryFn: getSeriesList, staleTime: 15_000, refetchInterval: 30_000 });

export function useSeriesMap(): Map<Hex, Series> {
  const { data } = useSeriesList();
  return useMemo(() => new Map((data ?? []).map((s) => [s.id, s])), [data]);
}

export const useSeries = (id: Hex | undefined) => {
  const map = useSeriesMap();
  return id ? map.get(id.toLowerCase() as Hex) ?? [...map.values()].find((s) => s.id.toLowerCase() === id.toLowerCase()) : undefined;
};

export const useProductMarket = (productId: Hex | undefined) =>
  useQuery({ queryKey: ["product", productId], queryFn: () => getProductMarket(productId!), enabled: !!productId, refetchInterval: FAST });

export const useSeriesMarket = (s: Series | undefined) =>
  useQuery({ queryKey: ["seriesMarket", s?.id], queryFn: () => getSeriesMarket(s!), enabled: !!s, refetchInterval: SLOW });

export const useAccounts = (owner: Address | undefined) =>
  useQuery({ queryKey: ["accounts", owner], queryFn: () => getAccounts(owner!), enabled: !!owner, staleTime: 10_000 });

export function useAccountView(accountId: bigint | undefined) {
  const map = useSeriesMap();
  return useQuery({
    queryKey: ["account", accountId?.toString(), map.size],
    queryFn: () => getAccount(accountId!, map),
    enabled: accountId !== undefined && map.size > 0,
    refetchInterval: FAST,
  });
}

export function useWalletWrappers(owner: Address | undefined) {
  const { data: series } = useSeriesList();
  return useQuery({
    queryKey: ["walletWrappers", owner, series?.length],
    queryFn: () => getWalletWrappers(owner!, series!),
    enabled: !!owner && !!series,
    refetchInterval: SLOW,
  });
}

export const useTokenBalance = (token: Address | undefined, owner: Address | undefined) =>
  useQuery({ queryKey: ["balance", token, owner], queryFn: () => getTokenBalance(token!, owner!), enabled: !!token && !!owner, refetchInterval: SLOW });

/** The chain's time (seconds), refreshed with the block: countdowns and expiry checks use it, not the wall clock. */
export const useChainTime = () =>
  useQuery({ queryKey: ["chainTime"], queryFn: async () => (await publicClient.getBlock()).timestamp, refetchInterval: FAST, select: (t) => t });

export const useLiquidationSpots = (accountId: bigint | undefined, productId: Hex | undefined, spotWad: bigint | undefined, enabled: boolean) =>
  useQuery({
    queryKey: ["liqSpots", accountId?.toString(), productId, spotWad?.toString()],
    queryFn: () => estimateLiquidationSpots(accountId!, productId!, spotWad!),
    enabled: enabled && accountId !== undefined && !!productId && !!spotWad,
    staleTime: 30_000,
  });

export type { UseQueryOptions };
