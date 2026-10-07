import { fitSvi, sviW, type Svi } from "./svi.ts";
import type { InputSnapshot } from "./inputs.ts";

const YEAR = 31_536_000;

export interface Slice {
  expiry: bigint;
  tau: number; // years from the calibration time
  params: Svi;
  /** Weighted RMSE of the fit in implied-vol units (e.g. 0.004 = 0.4 vol points). */
  rmseIv: number;
  quotes: number;
  medianWidthBps: number;
}

export interface Calibration {
  time: bigint;
  slices: Slice[];
  sources: number;
}

/** Fits one SVI smile per quoted expiry with at least 5 quotes (INDEXER_AND_KEEPERS.md §5.1 "Calibrate"). */
export function calibrate(snap: InputSnapshot, now: bigint): Calibration {
  const byExpiry = new Map<bigint, typeof snap.quotes>();
  for (const q of snap.quotes) if (q.expiry > now) byExpiry.set(q.expiry, [...(byExpiry.get(q.expiry) ?? []), q]);
  const slices: Slice[] = [];
  for (const [expiry, qs] of [...byExpiry].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
    if (qs.length < 5) continue;
    const tau = Number(expiry - now) / YEAR;
    const { params } = fitSvi(qs.map((q) => ({ k: q.k, w: q.iv * q.iv * tau, weight: q.weight })));
    const wsum = qs.reduce((s, q) => s + q.weight, 0);
    const rmseIv = Math.sqrt(qs.reduce((s, q) => s + q.weight * (Math.sqrt(Math.max(sviW(params, q.k), 0) / tau) - q.iv) ** 2, 0) / wsum);
    const widths = qs.map((q) => q.widthBps ?? 0).sort((a, b) => a - b);
    slices.push({ expiry, tau, params, rmseIv, quotes: qs.length, medianWidthBps: widths[Math.floor(widths.length / 2)]! });
  }
  return { time: now, slices, sources: snap.sources };
}

/**
 * Total variance at log-moneyness k for an expiry, measured from `from` (the report's validAfter): linear in total
 * variance between the bracketing fitted expiries at fixed k (calendar-consistent when the slices are), constant
 * implied vol outside the fitted range.
 */
export function totalVarianceAt(c: Calibration, k: number, expiry: bigint, from: bigint): number {
  const s = c.slices;
  if (s.length === 0) throw new Error("no calibrated expiries");
  const tau = Number(expiry - from) / YEAR;
  if (tau <= 0) throw new Error("expiry not after the report time");
  const ivOf = (sl: Slice) => Math.sqrt(Math.max(sviW(sl.params, k), 0) / sl.tau);
  if (expiry <= s[0]!.expiry) return ivOf(s[0]!) ** 2 * tau;
  if (expiry >= s[s.length - 1]!.expiry) return ivOf(s[s.length - 1]!) ** 2 * tau;
  const i = s.findIndex((sl) => sl.expiry >= expiry) - 1;
  const [a, b] = [s[i]!, s[i + 1]!];
  // Interpolate in calendar time between the slices' expiries, then express from `from`.
  const ta = Number(a.expiry - from) / YEAR;
  const tb = Number(b.expiry - from) / YEAR;
  const wa = ivOf(a) ** 2 * ta;
  const wb = ivOf(b) ** 2 * tb;
  return wa + ((wb - wa) * (tau - ta)) / (tb - ta);
}

/**
 * The report's `confidenceBps` (lower is better; above the product's maxConfidenceBps the protocol goes close-only):
 * the worst slice fit error relative to its ATM vol, half the median quote width, a 50 bps floor; 2,000 bps
 * (thin inputs) when no expiry could be fitted or a target tenor lies more than 30 days outside the fitted ones.
 */
export function confidenceBps(c: Calibration, tenors: readonly bigint[]): number {
  if (c.slices.length === 0) return 2000;
  const first = c.slices[0]!.expiry;
  const last = c.slices[c.slices.length - 1]!.expiry;
  const MONTH = 30n * 86_400n;
  if (tenors.some((t) => t < first - MONTH || t > last + MONTH)) return 2000;
  let worst = 50;
  for (const s of c.slices) {
    const atm = Math.sqrt(Math.max(sviW(s.params, 0), 1e-12) / s.tau);
    worst = Math.max(worst, Math.ceil((s.rmseIv / atm) * 10_000), Math.ceil(s.medianWidthBps / 2));
  }
  return Math.min(worst, 10_000);
}
