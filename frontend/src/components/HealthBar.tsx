/** Equity vs margin — one glance: safe buffer, then numbers. */
import { fmtWad } from "../lib/optara/format.ts";
import { classifyHealth, healthBar, STALE_MESSAGE } from "../lib/optara/health.ts";
import type { Health } from "../lib/optara/types.ts";
import { Term, cx } from "./ui.tsx";

const barColor = {
  good: "bg-good",
  warn: "bg-warn",
  bad: "bg-bad",
  neutral: "bg-muted",
} as const;

export function HealthBar({
  health,
  hasPositions,
  assetSymbol,
  compact,
}: {
  health: Health;
  hasPositions: boolean;
  assetSymbol: string;
  compact?: boolean;
}) {
  const v = classifyHealth(health, hasPositions);
  const b = healthBar(health);
  const buffer = health.equity - health.initialMargin;

  return (
    <div className="relative">
      <div className={cx("space-y-3", v.stale && "opacity-50")}>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <span
            className={cx(
              "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[13px] font-bold",
              v.tone === "good" && "border-good/30 bg-good/10 text-good",
              v.tone === "warn" && "border-warn/30 bg-warn/10 text-warn",
              v.tone === "bad" && "border-bad/30 bg-bad/10 text-bad",
              v.tone === "neutral" && "border-line bg-surface-2 text-muted"
            )}
          >
            <span className={cx("h-1.5 w-1.5 rounded-full", v.tone === "good" ? "bg-good" : v.tone === "warn" ? "bg-warn" : v.tone === "bad" ? "bg-bad" : "bg-muted")} />
            {v.label}
          </span>
          {!compact && <span className="max-w-xs text-right text-[13px] text-muted">{v.message}</span>}
        </div>

        <div className="relative h-2.5 rounded-full border border-line bg-surface-2">
          <div
            className={cx("h-full rounded-full transition-all duration-500", barColor[v.tone])}
            style={{ width: `${Math.min(100, Math.max(0, b.equityPct))}%` }}
          />
          {health.initialMargin > 0n && <Marker pct={b.imPct} tone="primary" />}
          {health.maintenanceMargin > 0n && <Marker pct={b.mmPct} tone="bad" />}
        </div>
        <div className="flex justify-between text-[11px] font-medium text-faint">
          <span>Liquidation {health.maintenanceMargin > 0n ? `$${fmtWad(health.maintenanceMargin, 0)}` : "—"}</span>
          <span className={cx("num font-semibold", buffer >= 0n ? "text-good" : "text-bad")}>
            {buffer >= 0n ? `+$${fmtWad(buffer, 0)} buffer` : `−$${fmtWad(-buffer, 0)} short`}
          </span>
          <span>New positions ${fmtWad(health.initialMargin, 0)}</span>
        </div>

        {!compact && (
          <div className="grid grid-cols-3 gap-2 text-[13px]">
            <div className="rounded-xl border border-line bg-surface-2/60 p-2.5">
              <div className="text-xs text-muted"><Term tip="Cash plus net position value.">Equity</Term></div>
              <div className="num font-display mt-0.5 text-[15px] font-semibold">${fmtWad(health.equity, 0)}</div>
            </div>
            <div className="rounded-xl border border-line bg-surface-2/60 p-2.5">
              <div className="text-xs text-muted"><Term tip="Needed to open or withdraw.">Required</Term></div>
              <div className="num font-display mt-0.5 text-[15px] font-semibold">${fmtWad(health.initialMargin, 0)}</div>
            </div>
            <div className="rounded-xl border border-line bg-surface-2/60 p-2.5">
              <div className="text-xs text-muted"><Term tip="Below this you can be liquidated.">Liquidation at</Term></div>
              <div className="num font-display mt-0.5 text-[15px] font-semibold">${fmtWad(health.maintenanceMargin, 0)}</div>
            </div>
          </div>
        )}
        {compact && <p className="text-xs text-muted">{v.message} · {assetSymbol}</p>}
      </div>

      {v.stale && (
        <div className="absolute inset-0 grid place-items-center rounded-2xl bg-surface/85 p-4 text-center text-[13px] font-semibold text-warn backdrop-blur-sm">
          {STALE_MESSAGE}
        </div>
      )}
    </div>
  );
}

function Marker({ pct, tone }: { pct: number; tone: "primary" | "bad" }) {
  const clamped = Math.min(96, Math.max(4, pct));
  return (
    <div className="absolute top-1/2 h-4 pointer-events-none" style={{ left: `${clamped}%` }}>
      <div className={cx("h-4 w-0.5 -translate-x-1/2 -translate-y-1/2 rounded-full", tone === "bad" ? "bg-bad" : "bg-primary")} />
    </div>
  );
}
