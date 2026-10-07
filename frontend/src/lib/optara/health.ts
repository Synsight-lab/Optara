/** FRONTEND.md §5: health states, colors and messages. */
import type { Health } from "./types.ts";

export type Tone = "good" | "warn" | "bad" | "neutral";

export interface HealthView {
  label: string;
  tone: Tone;
  message: string;
  stale: boolean;
}

export function classifyHealth(h: Health | undefined, hasPositions: boolean): HealthView {
  if (!h) return { label: "No account", tone: "neutral", message: "Create an account and deposit to start.", stale: false };
  const stale = !h.fresh;
  if (!hasPositions && h.initialMargin === 0n) return { label: "No risk", tone: "neutral", message: "No open positions. You can open new ones.", stale };
  switch (h.state) {
    case "HEALTHY":
      return { label: "Healthy", tone: "good", message: "You can open new positions.", stale };
    case "CLOSE_ONLY":
      return { label: "Close-only", tone: "warn", message: "New risk blocked. Deposit or reduce positions.", stale };
    default:
      return { label: "Liquidatable", tone: "bad", message: "Your positions can be liquidated now.", stale };
  }
}

export const STALE_MESSAGE = "Prices delayed. Shown values may be outdated.";

/**
 * Where equity sits on the bar: 0 at zero equity, with IM and MM marked; the bar spans max(IM × 1.5, equity).
 */
export function healthBar(h: Health): { equityPct: number; imPct: number; mmPct: number } {
  const span = [h.equity > 0n ? h.equity : 0n, (h.initialMargin * 3n) / 2n, 1n].reduce((a, b) => (a > b ? a : b));
  const pct = (x: bigint) => Math.max(0, Math.min(100, Number((x * 10_000n) / span) / 100));
  return { equityPct: pct(h.equity), imPct: pct(h.initialMargin), mmPct: pct(h.maintenanceMargin) };
}
