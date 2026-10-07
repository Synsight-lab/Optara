/**
 * Spot updater (INDEXER_AND_KEEPERS.md §2), extended to the surface: for products with open interest, pushes the
 * provider's spot every maxSpotAge / 2 and, when a publisher has a newer signed report, that report with the leaves
 * of every listed unexpired series, so passive views (health, previews, the indexer's health cache) stay fresh.
 */
import type { Hex } from "viem";
import {
  emptyOracleUpdate,
  liveSpotOracleAbi,
  nodeProofFromJson,
  optionClearingAbi,
  reportFromJson,
  subAccountsAbi,
  volSurfaceOracleAbi,
  type Manifest,
  type OracleUpdate,
  type SeriesCatalog,
  type SpotSource,
} from "@optara/sdk";
import { feeFor } from "./oracleFeed.ts";
import { sendTx, type Ctx } from "./tx.ts";

export interface OraclePusherOptions {
  manifest: Manifest;
  products: readonly Hex[];
  spot: SpotSource;
  catalog: SeriesCatalog;
  /** A publisher service; without one only spot is pushed. */
  publisherUrl?: string;
  /** Push even without open interest (testnets, demos). */
  always?: boolean;
  fetchImpl?: typeof fetch;
}

export class OraclePusher {
  constructor(
    private readonly ctx: Ctx,
    private readonly o: OraclePusherOptions,
  ) {}

  /** One pass. Returns what was pushed. */
  async tick(): Promise<{ spot: Hex[]; reports: { productId: Hex; seq: bigint }[]; error?: string }> {
    const { client } = this.ctx;
    const m = this.o.manifest;
    const now = (await client.getBlock()).timestamp;
    const spotProducts: Hex[] = [];
    const u = emptyOracleUpdate() as { -readonly [K in keyof OracleUpdate]: any[] };
    const reports: { productId: Hex; seq: bigint }[] = [];
    await this.o.catalog.sync();
    for (const p of this.o.products) {
      const oi = await client.readContract({ address: m.proxies.SubAccounts.proxy, abi: subAccountsAbi, functionName: "productShortNotional", args: [p] });
      if (oi === 0n && !this.o.always) continue;
      const src = await client.readContract({ address: m.proxies.LiveSpotOracle.proxy, abi: liveSpotOracleAbi, functionName: "sourceOf", args: [p] });
      const [, publishTime] = await client.readContract({ address: m.proxies.LiveSpotOracle.proxy, abi: liveSpotOracleAbi, functionName: "spotPrice", args: [p] });
      if (now - BigInt(publishTime) >= BigInt(src.maxSpotAge) / 2n) spotProducts.push(p);
      if (this.o.publisherUrl) {
        const r = await this.newerReport(p, now);
        if (r) {
          u.reports.push(r.report);
          u.reportSignatures.push(r.signatures);
          u.nodes.push(...r.nodes);
          reports.push({ productId: p, seq: r.report.surfaceSeq });
          if (!spotProducts.includes(p)) spotProducts.push(p); // a new surface is only useful with a fresh spot
        }
      }
    }
    if (spotProducts.length === 0) return { spot: [], reports };
    const feeds = new Set<Hex>();
    for (const p of spotProducts) {
      const src = await client.readContract({ address: m.proxies.LiveSpotOracle.proxy, abi: liveSpotOracleAbi, functionName: "sourceOf", args: [p] });
      feeds.add(src.baseFeedId);
      if (BigInt(src.quoteFeedId) !== 0n) feeds.add(src.quoteFeedId);
    }
    u.spotUpdates = await this.o.spot.updates([...feeds]);
    u.spotProductIds = spotProducts;
    const res = await sendTx(this.ctx, {
      address: m.proxies.OptionClearing.proxy,
      abi: optionClearingAbi,
      functionName: "updateOracles",
      args: [u],
      value: await feeFor(client, m, u),
    });
    if (!res.ok) {
      this.ctx.log(`oracle push failed: ${res.error}`);
      return { spot: [], reports: [], error: res.error };
    }
    this.ctx.log(`pushed spot for ${spotProducts.length} product(s)${reports.length ? `, reports ${reports.map((r) => r.seq).join(",")}` : ""}`);
    return { spot: spotProducts, reports };
  }

  /** The publisher's latest report if newer than the chain's and still valid, with the listed series' leaves. */
  private async newerReport(productId: Hex, now: bigint) {
    const f = this.o.fetchImpl ?? fetch;
    const res = await f(`${this.o.publisherUrl}/surface/${productId}/latest`);
    if (!res.ok) return undefined;
    const body = (await res.json()) as { report: unknown; signatures: Hex[] };
    const report = reportFromJson(body.report);
    const h = await this.ctx.client.readContract({ address: this.o.manifest.proxies.VolSurfaceOracle.proxy, abi: volSurfaceOracleAbi, functionName: "header", args: [productId] });
    if (report.surfaceSeq <= h.surfaceSeq || report.expiresAt <= now) return undefined;
    const series = this.o.catalog.all().filter((s) => s.productId === productId && s.expiry > now).map((s) => s.seriesId);
    const nodesRes = await f(`${this.o.publisherUrl}/surface/${productId}/${report.surfaceSeq}/nodes?series=${series.join(",")}`);
    const nodes = nodesRes.ok ? ((await nodesRes.json()) as unknown[]).map(nodeProofFromJson) : [];
    return { report, signatures: body.signatures, nodes };
  }
}
