/**
 * Profit and loss per option and overall, from on-chain history (no local trade log).
 *
 *   P&L = value of what you still hold + cash you received − cash you paid
 *
 * Split by average cost (the usual way brokers report it):
 *   realized   = locked in: each sale or redemption against the average cost of the options it closed, plus settlement
 *   unrealized = what you still hold: its value now against what it cost
 *   realized + unrealized = the total above
 *
 * Cash you paid: buys (premium + Optara buyer fee), writing fees, writers' debts collected at settlement.
 * Cash you received: sells (net of the order-book fee), redemptions, account credits at settlement.
 * Value now: options in your wallet and margin accounts at Optara's fair value (the mark); once an expiry's price is
 * fixed, at their settlement payout instead. Written options count as negative value (what you owe).
 */
import type { Series } from "./types.ts";

export interface SeriesPnl {
  series: Series;
  /** Cash paid out for this option, in the settlement asset. */
  paid: number;
  /** Cash received for this option. */
  received: number;
  /** Value of what is still held (negative for written options), at fair value or the settlement payout. */
  value: number;
  /** P&L already locked in by sales, redemptions and settlement. */
  realized: number;
  /** What the options still held cost (average cost of the wallet tokens left). */
  costHeld: number;
  /** Options still held: in the wallet, and the net position in your margin accounts (negative = written). */
  walletQty: number;
  accountQty: number;
  /** "open" while held and before expiry; "expired" once the price is fixed; "closed" when nothing is held. */
  status: "open" | "expired" | "closed";
  /** Some history can't be valued exactly (a liquidation, or tokens received by transfer). */
  approximate: boolean;
  /** You wrote this option at some point. A % of fees paid means nothing for a writer, so none is shown. */
  wrote: boolean;
  /** Everything that happened to this option for you, oldest first. */
  history: HistoryEntry[];
  /** The expiry's official settlement price, once fixed. */
  settlementPrice?: number;
}

export interface HistoryEntry {
  /** Unix seconds. */
  at: number;
  kind: "buy" | "sell" | "write" | "redeem" | "settle";
  qty: number;
  /** Cash received (+) or paid (−) by this event, in the settlement asset. */
  cash: number;
  /** For settlement: the price it settled at. */
  price?: number;
}

export const pnlOf = (r: Pick<SeriesPnl, "paid" | "received" | "value">) => r.value + r.received - r.paid;
/** The open part of the P&L: total minus what is already realized. */
export const unrealizedOf = (r: Pick<SeriesPnl, "paid" | "received" | "value" | "realized">) => pnlOf(r) - r.realized;

/** One wallet-token movement of an option, in the order it happened. */
export type Fill =
  | { kind: "buy"; qty: number; cash: number } // cash paid: premium + buyer fee
  | { kind: "mint"; qty: number; cash: number } // written into the wallet; cash = writing fee
  | { kind: "sell"; qty: number; cash: number } // cash received, net of the order-book fee
  | { kind: "redeem"; qty: number; cash: number }; // payout received

/**
 * Average cost of the wallet tokens: buys and writes add quantity and cost; each sale or redemption realizes its
 * proceeds against the average cost of the tokens it removes. Returns the realized P&L and the cost still held.
 */
export function averageCost(fills: Fill[]): { realized: number; costHeld: number; qtyHeld: number; unknownQty: number } {
  let qty = 0;
  let cost = 0;
  let realized = 0;
  let unknownQty = 0;
  for (const f of fills) {
    if (f.kind === "buy" || f.kind === "mint") {
      qty += f.qty;
      cost += f.cash;
      continue;
    }
    const closed = Math.min(f.qty, qty);
    const knownCash = f.qty > 0 ? (f.cash * closed) / f.qty : 0;
    const costOut = qty > 0 ? (cost * closed) / qty : 0;
    realized += knownCash - costOut;
    unknownQty += Math.max(0, f.qty - closed);
    cost -= costOut;
    qty -= closed;
    if (qty <= 1e-12) (qty = 0), (cost = 0);
  }
  return { realized, costHeld: cost, qtyHeld: qty, unknownQty };
}

/** P&L as a share of what was paid; undefined when nothing was paid or the option was written (the risk is collateral, not the fee). */
export function pnlPct(r: Pick<SeriesPnl, "paid" | "received" | "value" | "wrote">): number | undefined {
  return r.paid > 0 && !r.wrote ? pnlOf(r) / r.paid : undefined;
}

export interface PnlTotals {
  paid: number;
  received: number;
  value: number;
  pnl: number;
  realized: number;
  unrealized: number;
  costHeld: number;
  pct?: number;
  winners: number;
  losers: number;
}

/** Totals per settlement asset symbol (USDC and USDT are never added together). */
export function totals(rows: SeriesPnl[]): Map<string, PnlTotals> {
  const out = new Map<string, PnlTotals>();
  for (const r of rows) {
    const k = r.series.assetSymbol;
    const t = out.get(k) ?? { paid: 0, received: 0, value: 0, pnl: 0, realized: 0, unrealized: 0, costHeld: 0, winners: 0, losers: 0 };
    t.paid += r.paid;
    t.received += r.received;
    t.value += r.value;
    t.realized += r.realized;
    t.unrealized += unrealizedOf(r);
    t.costHeld += r.costHeld;
    const p = pnlOf(r);
    t.pnl += p;
    if (p > 0.005) t.winners++;
    else if (p < -0.005) t.losers++;
    out.set(k, t);
  }
  const wrote = new Set(rows.filter((r) => r.wrote).map((r) => r.series.assetSymbol));
  for (const [k, t] of out) t.pct = t.paid > 0 && !wrote.has(k) ? t.pnl / t.paid : undefined;
  return out;
}
