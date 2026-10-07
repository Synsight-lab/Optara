import type { Address, Hex, PublicClient } from "viem";
import { optionSeriesRegistryAbi } from "./abi.ts";

export interface ListedSeries {
  seriesId: Hex;
  groupId: Hex;
  productId: Hex;
  underlying: Address;
  settlementAsset: Address;
  settlementOracleConfigId: Hex;
  wrapper: Address;
  optionType: number;
  strikeWad: bigint;
  contractSizeWad: bigint;
  expiry: bigint;
}

/**
 * Listed series, followed from `OptionSeriesRegistry.SeriesCreated` (the registry has no enumeration). Scans in
 * chunks (Monad's public RPC limits `eth_getLogs` to 100 blocks) and keeps its position between calls.
 */
export class SeriesCatalog {
  private next: bigint;
  private readonly series = new Map<Hex, ListedSeries>();

  constructor(
    private readonly client: PublicClient,
    private readonly registry: Address,
    fromBlock: bigint,
    private readonly chunk = 100n,
  ) {
    this.next = fromBlock;
  }

  async sync(): Promise<void> {
    const head = await this.client.getBlockNumber();
    while (this.next <= head) {
      const to = this.next + this.chunk - 1n > head ? head : this.next + this.chunk - 1n;
      const logs = await this.client.getContractEvents({
        address: this.registry,
        abi: optionSeriesRegistryAbi,
        eventName: "SeriesCreated",
        fromBlock: this.next,
        toBlock: to,
        strict: true,
      });
      for (const l of logs) {
        const t = l.args.terms;
        this.series.set(l.args.seriesId, {
          seriesId: l.args.seriesId,
          groupId: l.args.groupId,
          productId: t.volSurfaceProductId,
          underlying: t.underlying,
          settlementAsset: t.settlementAsset,
          settlementOracleConfigId: t.settlementOracleConfigId,
          wrapper: t.wrapper,
          optionType: t.optionType,
          strikeWad: t.strikeWad,
          contractSizeWad: t.contractSizeWad,
          expiry: BigInt(t.expiry),
        });
      }
      this.next = to + 1n;
    }
  }

  get(seriesId: Hex): ListedSeries | undefined {
    return this.series.get(seriesId);
  }

  all(): ListedSeries[] {
    return [...this.series.values()];
  }

  /** Settlement groups (one expiry, settlement asset and oracle config each) with their series. */
  groups(): { groupId: Hex; expiry: bigint; settlementOracleConfigId: Hex; underlying: Address; settlementAsset: Address; series: ListedSeries[] }[] {
    const m = new Map<Hex, ListedSeries[]>();
    for (const s of this.series.values()) m.set(s.groupId, [...(m.get(s.groupId) ?? []), s]);
    return [...m].map(([groupId, series]) => ({
      groupId,
      expiry: series[0]!.expiry,
      settlementOracleConfigId: series[0]!.settlementOracleConfigId,
      underlying: series[0]!.underlying,
      settlementAsset: series[0]!.settlementAsset,
      series,
    }));
  }

  /** Distinct expiries after `after` of the product's listed series, increasing. */
  expiries(productId: Hex, after: bigint): bigint[] {
    const set = new Set<bigint>();
    for (const s of this.series.values()) if (s.productId === productId && s.expiry > after) set.add(s.expiry);
    return [...set].sort((a, b) => (a < b ? -1 : 1));
  }
}

/**
 * The report's tenors (ORACLES.md §3.7: every listed expiry must lie between two tenors or on one): all listed
 * expiries when there are at most 4, else the first, the last and two evenly spaced between.
 */
export function chooseTenors(expiries: readonly bigint[]): bigint[] {
  if (expiries.length <= 4) return [...expiries];
  const last = expiries.length - 1;
  const picks = new Set([0, Math.round(last / 3), Math.round((2 * last) / 3), last]);
  return [...picks].sort((a, b) => a - b).map((i) => expiries[i]!);
}
