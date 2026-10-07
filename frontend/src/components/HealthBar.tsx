/** FRONTEND.md §5: equity against IM and MM, with the state's color and message. */
import { fmtWad } from "../lib/optara/format.ts";
import { classifyHealth, healthBar, STALE_MESSAGE } from "../lib/optara/health.ts";
import type { Health } from "../lib/optara/types.ts";
import { Pill, Term, cx } from "./ui.tsx";

const barColor = { good: "bg-good", warn: "bg-warn", bad: "bg-bad", neutral: "bg-muted" } as const;

export function HealthBar({ health, hasPositions, assetSymbol, compact }: { health: Health; hasPositions: boolean; assetSymbol: string; compact?: boolean }) {
  const v = classifyHealth(health, hasPositions);
  const b = healthBar(health);
  return (
    <div className="relative">
      <div className={cx("space-y-3", v.stale && "opacity-50")}>
        <div className="flex items-center justify-between gap-3">
          <Pill tone={v.tone} dot>
            {v.label}
          </Pill>
          {!compact && <span className="text-sm text-muted">{v.message}</span>}
        </div>
        <div className="relative mt-5 h-3 overflow-visible rounded-full bg-surface-2">
          <div className={cx("h-3 rounded-full transition-all duration-500", barColor[v.tone])} style={{ width: `${b.equityPct}%` }} />
          {health.initialMargin > 0n && <Marker pct={b.imPct} label="IM" />}
          {health.maintenanceMargin > 0n && <Marker pct={b.mmPct} label="MM" />}
        </div>
        <div className="grid grid-cols-3 gap-2 pt-1 text-sm">
          <div>
            <div className="label">
              <Term tip="What your account is worth now: cash plus the value of your positions.">Equity</Term>
            </div>
            <div className="num font-semibold">
              {fmtWad(health.equity)} <span className="text-muted">{assetSymbol}</span>
            </div>
          </div>
          <div>
            <div className="label">
              <Term tip="Initial margin: the equity you need to open new positions. Below it, the account is close-only.">IM</Term>
            </div>
            <div className="num font-semibold">{fmtWad(health.initialMargin)}</div>
          </div>
          <div>
            <div className="label">
              <Term tip="Maintenance margin: below this, your positions can be liquidated at a discount.">MM</Term>
            </div>
            <div className="num font-semibold">{fmtWad(health.maintenanceMargin)}</div>
          </div>
        </div>
        {compact && <p className="text-xs text-muted">{v.message}</p>}
      </div>
      {v.stale && (
        <div className="absolute inset-0 grid place-items-center rounded-xl bg-surface/70 text-sm font-medium text-muted backdrop-blur-[1px]">{STALE_MESSAGE}</div>
      )}
    </div>
  );
}

function Marker({ pct, label }: { pct: number; label: string }) {
  return (
    <div className="absolute -top-1 h-5" style={{ left: `${pct}%` }}>
      <div className="h-5 w-0.5 -translate-x-1/2 rounded bg-ink/70" />
      <div className="absolute -top-4 -translate-x-1/2 text-[10px] font-semibold text-muted">{label}</div>
    </div>
  );
}
