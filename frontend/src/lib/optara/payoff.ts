/**
 * Display math for one option, in plain numbers (OPTION_SPEC.md §4). Every page that shows a payout, breakeven or
 * "how far must the price move" figure uses these, so the numbers agree everywhere and include the contract size.
 */
import { fmtLevelNum } from "./format.ts";
import type { Series } from "./types.ts";

export interface Leg {
  optionType: number; // 0 call, 1 put
  strike: number;
  /** Underlying units per option (1 for ETH options, e.g. 100 for MON). */
  size: number;
}

export const legOf = (s: Pick<Series, "optionType" | "strikeWad" | "contractSizeWad">): Leg => ({
  optionType: s.optionType,
  strike: Number(s.strikeWad) / 1e18,
  size: Number(s.contractSizeWad) / 1e18 || 1,
});

/** Cash one option pays at expiry if the settlement price is `price`. */
export const payoutPerOption = (leg: Leg, price: number) =>
  leg.size * (leg.optionType === 0 ? Math.max(price - leg.strike, 0) : Math.max(leg.strike - price, 0));

/**
 * Profit or loss at expiry for `qty` options. `costPerOption` is what one option cost a buyer (fees included) or
 * what a writer received for it (fees deducted).
 */
export function profitAt(leg: Leg, side: "long" | "short", qty: number, costPerOption: number, price: number) {
  const perOption = payoutPerOption(leg, price) - costPerOption;
  return (side === "long" ? perOption : -perOption) * qty;
}

/** Settlement price where profit is zero; undefined for a put that can never pay back its cost. */
export function breakeven(leg: Leg, costPerOption: number): number | undefined {
  const move = costPerOption / leg.size;
  if (leg.optionType === 0) return leg.strike + move;
  const be = leg.strike - move;
  return be > 0 ? be : undefined;
}

/** Whether the option would pay anything if it expired at `spot`. */
export const inTheMoney = (leg: Leg, spot: number) => (leg.optionType === 0 ? spot > leg.strike : spot < leg.strike);

/**
 * How far the price must move, in the option's direction, to reach `target`: positive = a move is still needed,
 * zero or negative = already there. 0.05 means 5%.
 */
export function moveNeeded(leg: Leg, spot: number, target: number): number {
  if (!(spot > 0)) return 0;
  return leg.optionType === 0 ? target / spot - 1 : 1 - target / spot;
}

/** "rise 5.2%" / "fall 5.2%" ("rises" / "falls" with `third`); "already there" once no move is needed. */
export function moveText(leg: Leg, move: number, dp = 1, third = false): string {
  if (move <= 0) return "already there";
  const word = (leg.optionType === 0 ? "rise" : "fall") + (third ? "s" : "");
  const min = 10 ** -dp;
  return move * 100 < min ? `${word} under ${min.toFixed(dp)}%` : `${word} ${(move * 100).toFixed(dp)}%`;
}

/** A dollar amount: whole dollars from 100, cents below, 3 significant digits under $1; "−$12.50" for losses. */
export function usd(x: number, opts: { sign?: boolean } = {}): string {
  if (Math.abs(x) < 0.005 && Math.abs(x) * 1e6 < 1) x = 0; // float leftovers like −2e-14 read as $0.00
  const abs = Math.abs(x);
  const body = abs >= 100 ? Math.round(abs).toLocaleString("en-US") : abs >= 1 || abs === 0 ? abs.toFixed(2) : fmtLevelNum(abs);
  if (x < 0 && body !== "0.00") return `−$${body}`;
  return `${opts.sign ? "+" : ""}$${body}`;
}

/** A price level such as a strike or breakeven. */
export const priceLevel = (x: number) => `$${fmtLevelNum(x)}`;

/** A round price step about 5% of `price` (1, 2 or 5 × a power of ten): "every $200 above". */
export function niceStep(price: number): number {
  if (!(price > 0)) return 1;
  const raw = price * 0.05;
  const p = 10 ** Math.floor(Math.log10(raw));
  const m = raw / p;
  return (m < 1.5 ? 1 : m < 3.5 ? 2 : m < 7.5 ? 5 : 10) * p;
}

/** Best and worst case at expiry for `qty` options; "unlimited" where the payoff has no bound. */
export function extremes(leg: Leg, side: "long" | "short", qty: number, costPerOption: number) {
  const premium = costPerOption * qty;
  // A put's payout is largest when the price goes to zero.
  const putMax = Math.max(0, leg.strike * leg.size - costPerOption) * qty;
  if (side === "long") return { maxGain: leg.optionType === 0 ? ("unlimited" as const) : putMax, maxLoss: premium };
  return { maxGain: premium, maxLoss: leg.optionType === 0 ? ("unlimited" as const) : putMax };
}

/** The price window a payoff chart shows: today, the strike and breakeven, with room either side. */
export function chartRange(points: number[]): [number, number] {
  const xs = points.filter((x) => x > 0 && Number.isFinite(x));
  if (xs.length === 0) return [0, 1];
  const lo = Math.min(...xs);
  const hi = Math.max(...xs);
  const pad = Math.max((hi - lo) * 0.6, hi * 0.15);
  return [Math.max(0, lo - pad), hi + pad];
}

/** About `count` round axis values covering [lo, hi] (steps of 1, 2 or 5 × a power of ten). */
export function niceTicks(lo: number, hi: number, count = 5): number[] {
  if (!(hi > lo)) return [lo];
  const raw = (hi - lo) / count;
  const p = 10 ** Math.floor(Math.log10(raw));
  const m = raw / p;
  const step = (m < 1.5 ? 1 : m < 3 ? 2 : m < 7 ? 5 : 10) * p;
  const out: number[] = [];
  for (let v = Math.ceil(lo / step) * step; v <= hi + step * 1e-9; v += step) out.push(Math.abs(v) < step * 1e-9 ? 0 : v);
  return out;
}

/** Above this, the buyer is warned that the price is high; above the second, they must confirm before buying. */
export const OVERPAY_WARN = 0.1;
export const OVERPAY_CONFIRM = 0.25;

/**
 * How much more than fair value a buyer pays, all fees included: 0.15 = 15% above. Undefined when there is no usable
 * fair value (no mark, or an option worth nothing).
 */
export function overFairValue(allInPerOption: number, fairPerOption: number | undefined): number | undefined {
  if (fairPerOption === undefined || !(fairPerOption > 0) || !(allInPerOption > 0)) return undefined;
  return allInPerOption / fairPerOption - 1;
}
