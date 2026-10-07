import type { Hex, PublicClient } from "viem";
import { emptyOracleUpdate, liveSpotOracleAbi, oracleUpdateFromJson, type Manifest, type OracleUpdate, type SpotSource } from "@optara/sdk";

/** Where a keeper gets the `OracleUpdate` it attaches to a risk-checked call. */
export interface OracleFeed {
  forAccount(accountId: bigint | undefined, products: readonly Hex[]): Promise<OracleUpdate>;
}

/** A publisher's `/oracle-update` (spot, newest report, missing leaves: INDEXER_AND_KEEPERS.md §5.2). */
export class PublisherFeed implements OracleFeed {
  constructor(
    private readonly url: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async forAccount(accountId: bigint | undefined): Promise<OracleUpdate> {
    const q = accountId === undefined ? "" : `?account=${accountId}`;
    const res = await this.fetchImpl(`${this.url}/oracle-update${q}`);
    if (!res.ok) throw new Error(`publisher ${res.status}`);
    return oracleUpdateFromJson(await res.json());
  }
}

/** Spot only (the surface and its leaves must already be on chain): the products' provider blobs. */
export class SpotOnlyFeed implements OracleFeed {
  constructor(
    private readonly client: PublicClient,
    private readonly manifest: Manifest,
    private readonly spot: SpotSource,
  ) {}

  async forAccount(_accountId: bigint | undefined, products: readonly Hex[]): Promise<OracleUpdate> {
    if (products.length === 0) return emptyOracleUpdate();
    const feeds = new Set<Hex>();
    for (const p of products) {
      const src = await this.client.readContract({ address: this.manifest.proxies.LiveSpotOracle.proxy, abi: liveSpotOracleAbi, functionName: "sourceOf", args: [p] });
      feeds.add(src.baseFeedId);
      if (BigInt(src.quoteFeedId) !== 0n) feeds.add(src.quoteFeedId);
    }
    return { ...emptyOracleUpdate(), spotUpdates: await this.spot.updates([...feeds]), spotProductIds: [...products] };
  }
}

/** The provider fee to attach for an update's spot blobs. */
export const feeFor = (client: PublicClient, manifest: Manifest, u: OracleUpdate) =>
  u.spotUpdates.length === 0
    ? Promise.resolve(0n)
    : client.readContract({ address: manifest.proxies.LiveSpotOracle.proxy, abi: liveSpotOracleAbi, functionName: "updateFee", args: [u.spotUpdates] });
