/** Live data hooks (TanStack Query). Intervals keep prices and health current without a refresh button. */
import { useQuery, type UseQueryOptions } from "@tanstack/react-query";
import { useMemo } from "react";
import type { Address, Hex } from "viem";
import { IS_LOCAL } from "../../config/network.ts";
import { protocolControlAbi } from "@optara/sdk";
import { ADDR, publicClient } from "./client.ts";
import { TRUSTED_ROLES, type RoleMap } from "./roles.ts";
import {
  estimateLiquidationSpots,
  getAccount,
  getAccounts,
  getProductMarket,
  getSeriesList,
  getSeriesListing,
  getSeriesMarket,
  getTokenBalance,
  getWalletWrappers,
} from "./reads.ts";
import type { Series } from "./types.ts";

const FAST = IS_LOCAL ? 3_000 : 6_000;
const SLOW = IS_LOCAL ? 8_000 : 20_000;

export const useSeriesList = () => useQuery({ queryKey: ["series"], queryFn: getSeriesList, staleTime: 30_000, refetchInterval: 60_000 });

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

/** Market lists: fair value, volatility and best bid/ask, refreshed every SLOW (rows need nothing more). */
export const useSeriesListing = (s: Series | undefined, enabled = true) =>
  useQuery({ queryKey: ["seriesListing", s?.id], queryFn: () => getSeriesListing(s!), enabled: !!s && enabled, staleTime: 10_000, refetchInterval: SLOW });

export const useSeriesMarket = (s: Series | undefined) =>
  useQuery({ queryKey: ["seriesMarket", s?.id], queryFn: () => getSeriesMarket(s!), enabled: !!s, refetchInterval: FAST });

/** The wallet's trusted Optara roles (ProtocolControl.hasRole), shared by the nav and the role-gated pages. */
export const useTrustedRoles = (address: Address | undefined) =>
  useQuery({
    queryKey: ["trustedRoles", address],
    queryFn: async (): Promise<RoleMap> =>
      new Map(
        await Promise.all(
          TRUSTED_ROLES.map(async (r) => [r.key, await publicClient.readContract({ address: ADDR.control, abi: protocolControlAbi, functionName: "hasRole", args: [r.key, address!] })] as const),
        ),
      ),
    enabled: !!address,
  });

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
