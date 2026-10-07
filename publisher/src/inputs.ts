/**
 * Volatility inputs (INDEXER_AND_KEEPERS.md §5.1 "Inputs"). Quotes are implied vols at log-moneyness ln(K / S)
 * relative to spot (the contract's moneyness, MATH.md §5), per expiry.
 */

export interface VolQuote {
  expiry: bigint; // unix seconds
  k: number; // ln(K / S)
  iv: number; // annualized, e.g. 0.6
  weight: number; // relative fitting weight
  widthBps?: number; // bid-ask width in implied vol, as bps of the IV
}

export interface InputSnapshot {
  quotes: VolQuote[];
  /** Independent input sources behind the quotes (reported as `sourceCount`). */
  sources: number;
  /** The spot the inputs were taken at (audit only). */
  spot?: number;
}

export interface VolInputs {
  readonly name: string;
  snapshot(now: bigint, expiries: readonly bigint[]): Promise<InputSnapshot>;
}

/**
 * A synthetic smile: `iv(k, τ)` sampled on a strike ladder at every requested expiry. Used for the local stack and
 * as the documented fallback shape for products without an options market (MON: realized volatility plus proxies,
 * wide confidence, PARAMETERS.md floors).
 */
export class SyntheticInputs implements VolInputs {
  readonly name = "synthetic";
  constructor(
    private readonly iv: (k: number, tauYears: number) => number,
    private readonly ks: readonly number[] = [-0.9, -0.6, -0.4, -0.25, -0.1, 0, 0.1, 0.25, 0.4, 0.6, 0.9],
  ) {}

  async snapshot(now: bigint, expiries: readonly bigint[]): Promise<InputSnapshot> {
    const quotes: VolQuote[] = [];
    for (const e of expiries) {
      const tau = Number(e - now) / 31_536_000;
      if (tau <= 0) continue;
      for (const k of this.ks) quotes.push({ expiry: e, k, iv: this.iv(k, tau), weight: 1 });
    }
    return { quotes, sources: 1 };
  }
}

/** A skewed smile: ATM vol, linear skew per unit k and curvature (sanity-checked shape for tests and local runs). */
export const skewSmile = (atm: number, skew = -0.1, curvature = 0.15) => (k: number) => Math.max(0.05, atm + skew * k + curvature * k * k);

interface DeribitSummary {
  instrument_name: string;
  bid_price: number | null;
  ask_price: number | null;
  mark_price: number;
  mark_iv: number;
  underlying_price: number;
  open_interest: number;
  estimated_delivery_price?: number;
}

const MONTHS: Record<string, number> = { JAN: 0, FEB: 1, MAR: 2, APR: 3, MAY: 4, JUN: 5, JUL: 6, AUG: 7, SEP: 8, OCT: 9, NOV: 10, DEC: 11 };

/** "ETH-27NOV26-3100-P" → expiry (08:00 UTC), strike, type. */
export function parseDeribitInstrument(name: string): { expiry: bigint; strike: number; type: "C" | "P" } | undefined {
  const m = /^[A-Z]+-(\d{1,2})([A-Z]{3})(\d{2})-([\d.]+(?:d\d+)?)-([CP])$/.exec(name);
  if (!m) return undefined;
  const month = MONTHS[m[2]!];
  if (month === undefined) return undefined;
  const expiry = BigInt(Date.UTC(2000 + Number(m[3]), month, Number(m[1]), 8) / 1000);
  return { expiry, strike: Number(m[4]!.replace("d", ".")), type: m[5] as "C" | "P" };
}

/**
 * Deribit public option summaries (no key needed). Out-of-the-money options only (calls at or above the index,
 * puts below), quotes with both sides, weighted by open interest and damped by the spread's width in vol terms.
 */
export class DeribitInputs implements VolInputs {
  readonly name = "deribit";
  constructor(
    private readonly currency: string,
    private readonly opts: { endpoint?: string; fetchImpl?: typeof fetch; minTauSeconds?: number } = {},
  ) {}

  async snapshot(now: bigint): Promise<InputSnapshot> {
    const url = `${this.opts.endpoint ?? "https://www.deribit.com"}/api/v2/public/get_book_summary_by_currency?currency=${this.currency}&kind=option`;
    const res = await (this.opts.fetchImpl ?? fetch)(url);
    if (!res.ok) throw new Error(`Deribit ${res.status}`);
    return parseDeribitSummaries(((await res.json()) as { result: DeribitSummary[] }).result, now, this.opts.minTauSeconds);
  }
}

export function parseDeribitSummaries(rows: readonly DeribitSummary[], now: bigint, minTauSeconds = 86_400): InputSnapshot {
  const quotes: VolQuote[] = [];
  let spot: number | undefined;
  for (const r of rows) {
    const inst = parseDeribitInstrument(r.instrument_name);
    if (!inst || inst.expiry - now < BigInt(minTauSeconds)) continue;
    const index = r.estimated_delivery_price ?? r.underlying_price;
    spot ??= index;
    if (!(r.mark_iv > 0) || !r.bid_price || !r.ask_price || r.ask_price <= r.bid_price) continue;
    const otm = inst.type === "C" ? inst.strike >= index : inst.strike < index;
    if (!otm) continue;
    // Width in vol terms: Δprice / vega. Prices are in the underlying's units, so per unit of forward:
    // vega = φ(d1) √τ (Black-76, undiscounted) and Δσ = (ask − bid) / (φ(d1) √τ).
    const tau = Number(inst.expiry - now) / 31_536_000;
    const sigma = r.mark_iv / 100;
    const d1 = (Math.log(r.underlying_price / inst.strike) + 0.5 * sigma * sigma * tau) / (sigma * Math.sqrt(tau));
    const vega = (Math.exp(-0.5 * d1 * d1) / Math.sqrt(2 * Math.PI)) * Math.sqrt(tau);
    if (!(vega > 1e-6)) continue; // too far out of the money to carry information about the smile
    const widthBps = ((r.ask_price - r.bid_price) / vega / sigma) * 10_000;
    quotes.push({
      expiry: inst.expiry,
      k: Math.log(inst.strike / index),
      iv: r.mark_iv / 100,
      weight: (1 + r.open_interest) / (1 + widthBps / 1000),
      widthBps,
    });
  }
  return { quotes, sources: 1, spot };
}
