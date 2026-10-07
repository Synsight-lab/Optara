/**
 * The surface publisher (INDEXER_AND_KEEPERS.md §5): inputs → calibrate → validate → grid → Merkle → sign → serve.
 * Never signs a report with a violation; holds and reports instead (the protocol goes close-only at maxSurfaceStale).
 */
import type { Address, Hex, LocalAccount, PublicClient } from "viem";
import {
  assembleReport,
  emptyOracleUpdate,
  findNodes,
  findTenors,
  liveSpotOracleAbi,
  logMoneyness,
  signReport,
  sortSignatures,
  subAccountsAbi,
  SurfaceGrid,
  toWad,
  volSurfaceOracleAbi,
  type Manifest,
  type NodeProof,
  type OracleUpdate,
  type SpotSource,
  type SurfaceReport,
} from "@optara/sdk";
import { recoverTypedDataAddress } from "viem";
import { SURFACE_REPORT_TYPES, surfaceDomain } from "@optara/sdk";
import { calibrate, confidenceBps, totalVarianceAt, type Calibration } from "./calibrate.ts";
import { chooseTenors, type SeriesCatalog } from "@optara/sdk";
import type { VolInputs } from "./inputs.ts";
import { validateReport, type ValidationContext, type Violation } from "./validate.ts";

/** ORACLES.md §3.7: nodes spanning at least ±1.0 log-moneyness; 13 nodes, denser near the money. */
export const DEFAULT_K_NODES = [-1.2, -0.9, -0.6, -0.4, -0.25, -0.1, 0, 0.1, 0.25, 0.4, 0.6, 0.9, 1.2];

export interface ProductSpec {
  productId: Hex;
  underlying: Address;
  settlementAsset: Address;
  symbol: string;
  inputs: VolInputs;
  kNodes?: readonly number[];
  riskParameterSetId?: Hex;
}

export interface Signed {
  report: SurfaceReport;
  grid: SurfaceGrid;
  signatures: Hex[];
  signers: Address[];
}

/** Signs for another publisher after validating independently (POST /cosign on its service). */
export interface Cosigner {
  cosign(report: SurfaceReport, grid: readonly (readonly bigint[])[]): Promise<{ signer: Address; signature: Hex }>;
}

export type PublishResult =
  | { ok: true; signed: Signed; confidenceBps: number }
  | { ok: false; reason: "no-listed-series" | "violations" | "quorum" | "inputs"; violations?: Violation[]; detail?: string };

export interface PublisherOptions {
  client: PublicClient;
  manifest: Manifest;
  products: readonly ProductSpec[];
  /** This operator's keys (normally one). */
  signers: readonly LocalAccount[];
  /** Other operators' services. */
  cosigners?: readonly Cosigner[];
  catalog: SeriesCatalog;
  /** Spot blobs for /oracle-update. */
  spot?: SpotSource;
  /** Extra leaves on each side of the bracketing nodes, for spot moves before the transaction lands. */
  nodeMargin?: number;
  log?: (msg: string) => void;
}

export class Publisher {
  /** Grids of recent reports per product, by sequence (so leaves of a report already on chain can be served). */
  private readonly grids = new Map<Hex, Map<bigint, Signed>>();

  constructor(private readonly o: PublisherOptions) {}

  private get surface(): Address {
    return this.o.manifest.proxies.VolSurfaceOracle.proxy;
  }

  latest(productId: Hex): Signed | undefined {
    const m = this.grids.get(productId);
    if (!m || m.size === 0) return undefined;
    return m.get([...m.keys()].reduce((a, b) => (a > b ? a : b)));
  }

  signedAt(productId: Hex, seq: bigint): Signed | undefined {
    return this.grids.get(productId)?.get(seq);
  }

  async context(productId: Hex): Promise<ValidationContext> {
    const c = this.o.client;
    const [block, config, header, emergency] = await Promise.all([
      c.getBlock(),
      c.readContract({ address: this.surface, abi: volSurfaceOracleAbi, functionName: "surfaceConfig", args: [productId] }),
      c.readContract({ address: this.surface, abi: volSurfaceOracleAbi, functionName: "header", args: [productId] }),
      c.readContract({ address: this.surface, abi: volSurfaceOracleAbi, functionName: "isEmergency", args: [productId] }),
    ]);
    return {
      chainId: BigInt(this.o.manifest.chainId),
      surface: this.surface,
      now: block.timestamp,
      config,
      header: {
        surfaceSeq: header.surfaceSeq,
        validAfter: header.validAfter,
        tenorTimestamps: header.tenorTimestamps,
        atmTotalVarianceByTenor: header.atmTotalVarianceByTenor,
      },
      emergency,
    };
  }

  /** Builds and validates the next report for a product (unsigned). */
  async build(spec: ProductSpec): Promise<
    | { ok: true; report: SurfaceReport; grid: SurfaceGrid; violations: Violation[]; calibration: Calibration; ctx: ValidationContext; confidenceBps: number }
    | { ok: false; reason: "no-listed-series" | "inputs"; detail?: string }
  > {
    await this.o.catalog.sync();
    const ctx = await this.context(spec.productId);
    const validAfter = ctx.now;
    const tenors = chooseTenors(this.o.catalog.expiries(spec.productId, validAfter));
    if (tenors.length === 0) return { ok: false, reason: "no-listed-series" };
    let calibration: Calibration;
    try {
      calibration = calibrate(await spec.inputs.snapshot(validAfter, tenors), validAfter);
    } catch (e) {
      return { ok: false, reason: "inputs", detail: (e as Error).message };
    }
    if (calibration.slices.length === 0) return { ok: false, reason: "inputs", detail: "no expiry could be calibrated" };
    const kNodes = spec.kNodes ?? DEFAULT_K_NODES;
    const w = tenors.map((t) => kNodes.map((k) => toWad(totalVarianceAt(calibration, k, t, validAfter))));
    const atm = tenors.map((t) => toWad(totalVarianceAt(calibration, 0, t, validAfter)));
    const conf = confidenceBps(calibration, tenors);
    const seq = (this.latest(spec.productId)?.report.surfaceSeq ?? 0n) > ctx.header.surfaceSeq ? this.latest(spec.productId)!.report.surfaceSeq + 1n : ctx.header.surfaceSeq + 1n;
    const { report, grid } = assembleReport({
      chainId: ctx.chainId,
      verifyingContract: this.surface,
      productId: spec.productId,
      underlying: spec.underlying,
      settlementAsset: spec.settlementAsset,
      seq,
      validAfter,
      lifetime: BigInt(ctx.config.maxReportLifetime),
      tenors,
      kNodes: kNodes.map(toWad),
      w,
      atm,
      surfaceMinIvBps: ctx.config.minIvBps,
      surfaceMaxIvBps: ctx.config.maxIvBps,
      confidenceBps: conf,
      sourceCount: calibration.sources,
      maxBidAskWidthBps: Math.round(Math.max(0, ...calibration.slices.map((s) => s.medianWidthBps))),
      liquidityScore: calibration.slices.reduce((s, sl) => s + sl.quotes, 0),
      lastCalibrationTime: validAfter,
      riskParameterSetId: spec.riskParameterSetId,
    });
    return { ok: true, report, grid, violations: validateReport(report, w, ctx), calibration, ctx, confidenceBps: conf };
  }

  /** Builds, validates and signs (with cosigners) the next report. Refuses on any violation or a short quorum. */
  async publish(spec: ProductSpec): Promise<PublishResult> {
    const b = await this.build(spec);
    if (!b.ok) return b;
    if (b.violations.length > 0) {
      this.o.log?.(`${spec.symbol}: refusing to sign: ${b.violations.map((v) => `${v.code} ${v.detail}`).join("; ")}`);
      return { ok: false, reason: "violations", violations: b.violations };
    }
    const sigs: { signer: Address; signature: Hex }[] = [];
    for (const s of this.o.signers) sigs.push({ signer: s.address, signature: await signReport(b.report, s) });
    for (const c of this.o.cosigners ?? []) {
      try {
        sigs.push(await c.cosign(b.report, b.grid.w));
      } catch (e) {
        this.o.log?.(`${spec.symbol}: cosigner refused: ${(e as Error).message}`);
      }
    }
    const quorum = await this.checkQuorum(b.report, sigs);
    if (quorum) return { ok: false, reason: "quorum", detail: quorum };
    const signed: Signed = { report: b.report, grid: b.grid, signatures: sortSignatures(sigs), signers: sigs.map((s) => s.signer) };
    this.remember(signed);
    return { ok: true, signed, confidenceBps: b.confidenceBps };
  }

  /** Cosigning for another publisher: the grid must match the signed root and pass the same validation here. */
  async cosign(report: SurfaceReport, grid: readonly (readonly bigint[])[]): Promise<{ signer: Address; signature: Hex }> {
    const signer = this.o.signers[0];
    if (!signer) throw new Error("no local signer");
    const g = new SurfaceGrid(report.productId, report.surfaceSeq, grid);
    if (g.tree.root !== report.surfaceRoot) throw new Error("grid does not match surfaceRoot");
    if (!this.o.products.some((p) => p.productId === report.productId)) throw new Error("product not published here");
    const v = validateReport(report, grid, await this.context(report.productId));
    if (v.length > 0) throw new Error(v.map((x) => `${x.code} ${x.detail}`).join("; "));
    return { signer: signer.address, signature: await signReport(report, signer) };
  }

  /** Returns a reason if the signatures can't make an accepted quorum (ORACLES.md §3.3), undefined if they can. */
  private async checkQuorum(report: SurfaceReport, sigs: { signer: Address; signature: Hex }[]): Promise<string | undefined> {
    const c = this.o.client;
    const quorum = await c.readContract({ address: this.surface, abi: volSurfaceOracleAbi, functionName: "quorum" });
    let active = 0;
    let independent = false;
    for (const s of sigs) {
      const recovered = await recoverTypedDataAddress({
        domain: surfaceDomain(report.chainId, report.verifyingContract),
        types: SURFACE_REPORT_TYPES,
        primaryType: "SurfaceReport",
        message: { ...report, tenorTimestamps: [...report.tenorTimestamps], atmTotalVarianceByTenor: [...report.atmTotalVarianceByTenor], kNodes: [...report.kNodes] },
        signature: s.signature,
      });
      if (recovered.toLowerCase() !== s.signer.toLowerCase()) return `signature from ${s.signer} does not recover`;
      const [isActive, isIndependent] = await c.readContract({ address: this.surface, abi: volSurfaceOracleAbi, functionName: "isPublisher", args: [s.signer] });
      if (isActive) active++;
      if (isActive && isIndependent) independent = true;
    }
    if (BigInt(active) < quorum) return `${active} active publisher signatures, quorum ${quorum}`;
    if (!independent) return "no independent publisher signed";
    return undefined;
  }

  private remember(s: Signed) {
    const m = this.grids.get(s.report.productId) ?? new Map<bigint, Signed>();
    m.set(s.report.surfaceSeq, s);
    for (const seq of [...m.keys()].sort((a, b) => (a < b ? -1 : 1)).slice(0, Math.max(0, m.size - 16))) m.delete(seq);
    this.grids.set(s.report.productId, m);
  }

  /**
   * Leaves the risk check needs for these series (MATH.md §5: the tenors around each expiry and the nodes around
   * its log-moneyness at `spotWad`, widened by `nodeMargin`), from report `signed`. With `skipProven`, leaves the
   * chain already caches for that sequence are left out.
   */
  async nodesFor(signed: Signed, series: readonly { strikeWad: bigint; expiry: bigint }[], spotWad: bigint, skipProven: boolean): Promise<NodeProof[]> {
    const r = signed.report;
    const margin = this.o.nodeMargin ?? 1;
    const want = new Set<string>();
    for (const s of series) {
      const tb = findTenors(r.tenorTimestamps, s.expiry);
      if (!tb) continue; // not priceable from this report; the contract will say SeriesNotPriceable
      const [lo, hi] = findNodes(r.kNodes, logMoneyness(s.strikeWad, spotWad));
      for (const t of new Set(tb)) {
        for (let j = Math.max(0, lo - margin); j <= Math.min(r.kNodes.length - 1, hi + margin); j++) want.add(`${t}:${j}`);
      }
    }
    const out: NodeProof[] = [];
    for (const key of want) {
      const [t, j] = key.split(":").map(Number) as [number, number];
      if (skipProven) {
        const [proven] = await this.o.client.readContract({ address: this.surface, abi: volSurfaceOracleAbi, functionName: "nodeValue", args: [r.productId, t, j] });
        if (proven) continue;
      }
      out.push(signed.grid.nodeProof(t, j));
    }
    return out;
  }

  /**
   * INDEXER_AND_KEEPERS.md §5.2 `/oracle-update`: spot blobs for every product the account holds (plus `extraSeries`),
   * the latest signed report per product when it is newer than the chain's, and the proofs of every leaf the risk
   * check will read that the chain doesn't cache yet.
   */
  async oracleUpdate(accountId: bigint | undefined, extraSeries: readonly Hex[] = []): Promise<OracleUpdate> {
    const c = this.o.client;
    const m = this.o.manifest;
    const now = (await c.getBlock()).timestamp;
    const series: { productId: Hex; strikeWad: bigint; expiry: bigint }[] = [];
    if (accountId !== undefined) {
      const positions = await c.readContract({ address: m.proxies.SubAccounts.proxy, abi: subAccountsAbi, functionName: "positionsOf", args: [accountId] });
      for (const p of positions) {
        if (p.balance !== 0n && BigInt(p.series.expiry) > now) series.push({ productId: p.series.productId, strikeWad: p.series.strikeWad, expiry: BigInt(p.series.expiry) });
      }
    }
    await this.o.catalog.sync();
    for (const id of extraSeries) {
      const s = this.o.catalog.get(id);
      if (s) series.push(s);
    }
    const products = [...new Set(series.map((s) => s.productId))];
    const u = emptyOracleUpdate() as { -readonly [K in keyof OracleUpdate]: any[] };
    if (this.o.spot && products.length > 0) {
      const feeds = new Set<Hex>();
      for (const p of products) {
        const src = await c.readContract({ address: m.proxies.LiveSpotOracle.proxy, abi: liveSpotOracleAbi, functionName: "sourceOf", args: [p] });
        feeds.add(src.baseFeedId);
        if (BigInt(src.quoteFeedId) !== 0n) feeds.add(src.quoteFeedId);
      }
      u.spotUpdates = await this.o.spot.updates([...feeds]);
      u.spotProductIds = products;
    }
    for (const p of products) {
      const [spotWad] = await c.readContract({ address: m.proxies.LiveSpotOracle.proxy, abi: liveSpotOracleAbi, functionName: "spotPrice", args: [p] });
      const header = await c.readContract({ address: this.surface, abi: volSurfaceOracleAbi, functionName: "header", args: [p] });
      const latest = this.latest(p);
      const mine = series.filter((s) => s.productId === p);
      if (latest && latest.report.surfaceSeq > header.surfaceSeq && latest.report.expiresAt > now) {
        u.reports.push(latest.report);
        u.reportSignatures.push(latest.signatures);
        u.nodes.push(...(await this.nodesFor(latest, mine, spotWad, false)));
      } else {
        const current = this.signedAt(p, header.surfaceSeq);
        if (current) u.nodes.push(...(await this.nodesFor(current, mine, spotWad, true)));
      }
    }
    return u;
  }
}
