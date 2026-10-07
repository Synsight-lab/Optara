/** FRONTEND.md §5: equity against IM and MM, with the state's color and message. */
import { AlertTriangle, CheckCircle, ShieldAlert, ShieldCheck } from "lucide-react";
import { fmtWad } from "../lib/optara/format.ts";
import { classifyHealth, healthBar, STALE_MESSAGE } from "../lib/optara/health.ts";
import type { Health } from "../lib/optara/types.ts";
import { Pill, Term, cx } from "./ui.tsx";

const barColor = {
  good: "bg-good shadow-[0_0_12px_rgba(60,207,145,0.4)]",
  warn: "bg-warn shadow-[0_0_12px_rgba(245,184,75,0.4)]",
  bad: "bg-bad shadow-[0_0_12px_rgba(240,80,110,0.4)]",
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

  const Icon =
    v.tone === "good"
      ? ShieldCheck
      : v.tone === "warn"
      ? AlertTriangle
      : v.tone === "bad"
      ? ShieldAlert
      : ShieldCheck;

  return (
    <div className="relative">
      <div className={cx("space-y-3.5", v.stale && "opacity-50")}>
        {/* Status header with icon */}
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <span
              className={cx(
                "inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-bold",
                v.tone === "good"
                  ? "bg-good/15 text-good"
                  : v.tone === "warn"
                  ? "bg-warn/15 text-warn"
                  : v.tone === "bad"
                  ? "bg-bad/15 text-bad"
                  : "bg-muted/15 text-muted"
              )}
            >
              <Icon className="h-3.5 w-3.5" />
              <span>{v.label}</span>
            </span>
          </div>

          {!compact && (
            <span className="text-xs text-muted font-medium text-right max-w-xs">{v.message}</span>
          )}
        </div>

        {/* Progress bar with IM and MM pins */}
        <div className="relative mt-6 h-3.5 overflow-visible rounded-full bg-surface-2 p-0.5 border border-line">
          <div
            className={cx("h-2.5 rounded-full transition-all duration-500", barColor[v.tone])}
            style={{ width: `${Math.min(100, Math.max(0, b.equityPct))}%` }}
          />

          {health.initialMargin > 0n && <Marker pct={b.imPct} label="IM (Safe)" tone="primary" />}
          {health.maintenanceMargin > 0n && <Marker pct={b.mmPct} label="MM (Danger)" tone="bad" />}
        </div>

        {/* Numbers breakdown */}
        <div className="grid grid-cols-3 gap-2 pt-2 text-xs">
          <div className="rounded-xl bg-surface-2/60 p-2.5 border border-line/60">
            <div className="text-[11px] font-medium text-muted">
              <Term tip="Total value of this subaccount: cash balance plus net position mark values.">
                Account Equity
              </Term>
            </div>
            <div className="num font-bold text-ink mt-0.5 text-sm sm:text-base">
              ${fmtWad(health.equity, 2)}
            </div>
            <div className="text-[10px] text-muted">{assetSymbol}</div>
          </div>

          <div className="rounded-xl bg-surface-2/60 p-2.5 border border-line/60">
            <div className="text-[11px] font-medium text-muted">
              <Term tip="Initial Margin: minimum equity required to open new positions or withdraw collateral.">
                Initial Margin (IM)
              </Term>
            </div>
            <div className="num font-bold text-ink mt-0.5 text-sm sm:text-base">
              ${fmtWad(health.initialMargin, 2)}
            </div>
            <div className="text-[10px] text-muted">Req. to open</div>
          </div>

          <div className="rounded-xl bg-surface-2/60 p-2.5 border border-line/60">
            <div className="text-[11px] font-medium text-muted">
              <Term tip="Maintenance Margin: liquidation threshold. If equity drops below this, liquidators may take slices.">
                Maint. Margin (MM)
              </Term>
            </div>
            <div className="num font-bold text-ink mt-0.5 text-sm sm:text-base">
              ${fmtWad(health.maintenanceMargin, 2)}
            </div>
            <div className="text-[10px] text-muted">Liq. threshold</div>
          </div>
        </div>

        {compact && <p className="text-[11px] text-muted font-medium">{v.message}</p>}
      </div>

      {v.stale && (
        <div className="absolute inset-0 grid place-items-center rounded-2xl bg-surface/85 text-xs font-semibold text-warn backdrop-blur-sm p-4 text-center">
          ⚠️ {STALE_MESSAGE}
        </div>
      )}
    </div>
  );
}

function Marker({ pct, label, tone }: { pct: number; label: string; tone: "primary" | "bad" }) {
  const clamped = Math.min(95, Math.max(5, pct));
  return (
    <div className="absolute -top-1.5 h-6 pointer-events-none" style={{ left: `${clamped}%` }}>
      <div
        className={cx(
          "h-6 w-0.5 -translate-x-1/2 rounded-full",
          tone === "bad" ? "bg-bad shadow-[0_0_6px_rgba(240,80,110,0.8)]" : "bg-primary shadow-[0_0_6px_rgba(131,110,249,0.8)]"
        )}
      />
      <div
        className={cx(
          "absolute -top-4 -translate-x-1/2 text-[9px] font-bold whitespace-nowrap",
          tone === "bad" ? "text-bad" : "text-primary"
        )}
      >
        {label}
      </div>
    </div>
  );
}
