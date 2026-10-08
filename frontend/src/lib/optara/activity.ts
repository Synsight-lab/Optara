/** Local trade log: when you bought or sold each option on this device.
 * There is no on-chain per-wallet fill history to read, so the app records
 * successful buy/sell transactions locally (address-scoped). */
import type { Address, Hex } from "viem";

export interface TradeEntry {
  seriesId: Hex;
  side: "buy" | "sell";
  at: number;
}

const key = (owner: Address | undefined) => `optara.trades.${owner?.toLowerCase() ?? "anon"}`;
const CAP = 200;

function read(owner: Address | undefined): TradeEntry[] {
  try {
    const raw = localStorage.getItem(key(owner));
    if (!raw) return [];
    const arr = JSON.parse(raw) as TradeEntry[];
    return Array.isArray(arr) ? arr : [];
  } catch {
    return [];
  }
}

/** Last trade per series (lowercased id), newest first. */
export function tradeMap(owner: Address | undefined): Map<string, TradeEntry> {
  const m = new Map<string, TradeEntry>();
  for (const e of read(owner).sort((a, b) => b.at - a.at)) {
    const k = e.seriesId.toLowerCase();
    if (!m.has(k)) m.set(k, e);
  }
  return m;
}

export function recordTrade(owner: Address | undefined, seriesId: Hex, side: "buy" | "sell"): void {
  try {
    const next = [{ seriesId, side, at: Date.now() }, ...read(owner)].slice(0, CAP);
    localStorage.setItem(key(owner), JSON.stringify(next));
  } catch {
    // private mode: activity lasts for the session only
  }
}
