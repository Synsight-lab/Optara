import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { assembleReport, toWad } from "@optara/sdk";
import { butterflyViolations, fitSvi, sviW, type Svi } from "../src/svi.ts";
import { calibrate, confidenceBps, totalVarianceAt } from "../src/calibrate.ts";
import { parseDeribitInstrument, parseDeribitSummaries, SyntheticInputs, skewSmile } from "../src/inputs.ts";
import { chooseTenors } from "@optara/sdk";
import { validateReport, type ValidationContext } from "../src/validate.ts";
import { DEFAULT_K_NODES } from "../src/publisher.ts";

const DAY = 86_400n;
const NOW = 1_791_374_400n; // 2026-10-07T08:00Z, the Deribit fixture's day

describe("SVI", () => {
  it("recovers a known smile from its own points", () => {
    const truth: Svi = { a: 0.01, b: 0.08, rho: -0.4, m: 0.05, sigma: 0.2 };
    const ks = [-0.8, -0.5, -0.3, -0.15, 0, 0.15, 0.3, 0.5, 0.8];
    const { params, rmse } = fitSvi(ks.map((k) => ({ k, w: sviW(truth, k), weight: 1 })));
    expect(rmse).toBeLessThan(1e-6);
    for (const k of [-1, -0.4, 0, 0.4, 1]) expect(sviW(params, k)).toBeCloseTo(sviW(truth, k), 5);
  });

  it("needs five quotes", () => {
    expect(() => fitSvi([{ k: 0, w: 0.1, weight: 1 }])).toThrow(/at least 5/);
  });
});

describe("butterfly (contract interpolation)", () => {
  const k = [-0.5, -0.25, 0, 0.25, 0.5];
  it("a convex smile is clean", () => {
    expect(butterflyViolations(k, k.map((x) => 0.05 + 0.02 * x * x + 0.005 * Math.abs(x)))).toEqual([]);
  });
  it("a concave kink is a violation", () => {
    expect(butterflyViolations(k, [0.05, 0.06, 0.07, 0.06, 0.05]).join()).toMatch(/concave kink/);
  });
  it("a steep wing fails Durrleman's condition", () => {
    expect(butterflyViolations([0, 0.1], [0.01, 0.6]).join()).toMatch(/negative density/);
  });
});

describe("Deribit inputs", () => {
  it("parses instrument names (08:00 UTC expiry)", () => {
    expect(parseDeribitInstrument("ETH-27NOV26-3100-P")).toEqual({ expiry: BigInt(Date.UTC(2026, 10, 27, 8) / 1000), strike: 3100, type: "P" });
    expect(parseDeribitInstrument("ETH-PERPETUAL")).toBeUndefined();
  });

  it("the real snapshot calibrates to clean, arbitrage-free grids at every quoted expiry", () => {
    const rows = JSON.parse(readFileSync(new URL("./fixtures/deribit-eth-2026-10-07.json", import.meta.url), "utf8")).result;
    const snap = parseDeribitSummaries(rows, NOW);
    expect(snap.quotes.length).toBeGreaterThan(100);
    expect(snap.quotes.every((q) => q.iv > 0.05 && q.iv < 5)).toBe(true);
    const cal = calibrate(snap, NOW);
    expect(cal.slices.length).toBeGreaterThanOrEqual(4);
    for (const s of cal.slices) expect(s.rmseIv).toBeLessThan(0.03); // within 3 vol points
    const tenors = chooseTenors(cal.slices.map((s) => s.expiry).filter((e) => e - NOW < 120n * DAY));
    const kNodes = DEFAULT_K_NODES;
    const w = tenors.map((t) => kNodes.map((k) => toWad(totalVarianceAt(cal, k, t, NOW))));
    const { report } = assembleReport({
      chainId: 31337n,
      verifyingContract: "0x0000000000000000000000000000000000000001",
      productId: `0x${"11".repeat(32)}`,
      underlying: "0x0000000000000000000000000000000000000002",
      settlementAsset: "0x0000000000000000000000000000000000000003",
      seq: 1n,
      validAfter: NOW,
      lifetime: 900n,
      tenors,
      kNodes: kNodes.map(toWad),
      w,
      atm: tenors.map((t) => toWad(totalVarianceAt(cal, 0, t, NOW))),
      surfaceMinIvBps: 1000,
      surfaceMaxIvBps: 50_000,
      confidenceBps: confidenceBps(cal, tenors),
      sourceCount: 1,
    });
    const v = validateReport(report, w, ctx({ now: NOW }));
    expect(v).toEqual([]);
    expect(report.confidenceBps).toBeLessThanOrEqual(1000); // confident enough to be risk-bearing
  });
});

const ctx = (o: Partial<ValidationContext> = {}): ValidationContext => ({
  chainId: 31337n,
  surface: "0x0000000000000000000000000000000000000001",
  now: NOW,
  config: { maxReportLifetime: 900, maxIvMoveBps: 2000, maxConfidenceBps: 1000, minIvBps: 1000, maxIvBps: 50_000 },
  header: { surfaceSeq: 0n, validAfter: 0n, tenorTimestamps: [0n, 0n, 0n, 0n], atmTotalVarianceByTenor: [0n, 0n, 0n, 0n] },
  emergency: false,
  ...o,
});

/** A synthetic report at `atm` vol with optional tampering of the grid. */
async function synthetic(atm: number, tamper?: (w: bigint[][]) => void) {
  const tenors = [NOW + 7n * DAY, NOW + 14n * DAY];
  const cal = calibrate(await new SyntheticInputs(skewSmile(atm)).snapshot(NOW, tenors), NOW);
  const w = tenors.map((t) => DEFAULT_K_NODES.map((k) => toWad(totalVarianceAt(cal, k, t, NOW))));
  tamper?.(w);
  const { report } = assembleReport({
    chainId: 31337n,
    verifyingContract: "0x0000000000000000000000000000000000000001",
    productId: `0x${"11".repeat(32)}`,
    underlying: "0x0000000000000000000000000000000000000002",
    settlementAsset: "0x0000000000000000000000000000000000000003",
    seq: 2n,
    validAfter: NOW,
    lifetime: 900n,
    tenors,
    kNodes: DEFAULT_K_NODES.map(toWad),
    w,
    atm: tenors.map((t) => toWad(totalVarianceAt(cal, 0, t, NOW))),
    surfaceMinIvBps: 1000,
    surfaceMaxIvBps: 50_000,
    confidenceBps: confidenceBps(cal, tenors),
    sourceCount: 1,
  });
  return { report, w, tenors };
}

describe("validateReport (PUB-001 refusals)", () => {
  it("a synthetic skewed smile is clean", async () => {
    const { report, w } = await synthetic(0.6);
    expect(validateReport(report, w, ctx())).toEqual([]);
  });

  it("calendar arbitrage on a wing node is refused", async () => {
    const { report, w } = await synthetic(0.6, (w) => (w[1]![0] = w[0]![0]! - 1n));
    expect(validateReport(report, w, ctx()).map((v) => v.code)).toContain("CALENDAR");
  });

  it("butterfly arbitrage is refused", async () => {
    const { report, w } = await synthetic(0.6, (w) => (w[0]![6] = w[0]![6]! * 3n));
    expect(validateReport(report, w, ctx()).map((v) => v.code)).toContain("BUTTERFLY");
  });

  it("an ATM move above maxIvMoveBps is refused unless emergency mode is on", async () => {
    const old = await synthetic(0.6);
    const header = { surfaceSeq: 1n, validAfter: NOW, tenorTimestamps: old.report.tenorTimestamps, atmTotalVarianceByTenor: old.report.atmTotalVarianceByTenor };
    const up = await synthetic(0.78); // +30%
    expect(validateReport(up.report, up.w, ctx({ header })).map((v) => v.code)).toContain("IV_MOVE");
    expect(validateReport(up.report, up.w, ctx({ header, emergency: true }))).toEqual([]);
    const small = await synthetic(0.69); // +15%
    expect(validateReport(small.report, small.w, ctx({ header }))).toEqual([]);
  });

  it("stale sequence, lifetime and leaves outside the bounds are refused", async () => {
    const { report, w } = await synthetic(0.6);
    const header = { surfaceSeq: 5n, validAfter: NOW, tenorTimestamps: report.tenorTimestamps, atmTotalVarianceByTenor: report.atmTotalVarianceByTenor };
    expect(validateReport(report, w, ctx({ header })).map((v) => v.code)).toContain("SEQUENCE");
    expect(validateReport({ ...report, expiresAt: report.validAfter + 901n }, w, ctx()).map((v) => v.code)).toContain("TIME");
    expect(validateReport({ ...report, surfaceMaxIvBps: 6000 }, w, ctx()).map((v) => v.code)).toContain("LEAF_IV");
    expect(validateReport({ ...report, surfaceMinIvBps: 500 }, w, ctx()).map((v) => v.code)).toContain("IV_BOUNDS");
  });
});

describe("tenor choice (ORACLES.md §3.7)", () => {
  it("covers every listed expiry with at most 4 tenors", () => {
    expect(chooseTenors([1n, 2n])).toEqual([1n, 2n]);
    const many = Array.from({ length: 10 }, (_, i) => BigInt(i + 1));
    const t = chooseTenors(many);
    expect(t).toHaveLength(4);
    expect(t[0]).toBe(1n);
    expect(t[3]).toBe(10n);
  });
});
