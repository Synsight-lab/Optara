/** The limits a transaction is signed with, and the slippage that sets them (FRONTEND.md §7). */
import { useState } from "react";
import { MAX_SLIPPAGE_BPS, MIN_SLIPPAGE_BPS, SLIPPAGE_PRESETS, useSlippage } from "../lib/optara/limits.ts";
import { Details, Row, Term, cx } from "./ui.tsx";

export interface Limit {
  label: string;
  value: string;
  tip: string;
}

export function LimitsPanel({ limits }: { limits: Limit[] }) {
  const [bps, setBps] = useSlippage();
  const [custom, setCustom] = useState("");
  const pct = (b: number) => `${(b / 100).toFixed(b % 100 ? (b % 10 ? 2 : 1) : 0)}%`;

  return (
    <Details summary={<span>Price protection <b className="num">{pct(bps)}</b></span>}>
      <div className="space-y-2.5 py-1">
        <p className="text-xs leading-relaxed text-muted">
          If the price moves against you by more than this before your transaction lands, it is cancelled and only gas is
          spent. Lower is safer but fails more often in a fast market.
        </p>
        <div className="flex flex-wrap items-center gap-1.5">
          {SLIPPAGE_PRESETS.map((p) => (
            <button key={p} type="button" onClick={() => (setBps(p), setCustom(""))} className={cx("chip cursor-pointer", bps === p && "border-primary/50 bg-primary-soft text-primary")}>
              {pct(p)}
            </button>
          ))}
          <label className="flex items-center gap-1 text-xs text-muted">
            <input
              inputMode="decimal"
              placeholder="Custom"
              value={custom}
              onChange={(e) => {
                const v = e.target.value.replace(/[^\d.]/g, "");
                setCustom(v);
                const n = Number(v);
                if (v && n > 0) setBps(n * 100);
              }}
              className="input w-20 !py-1 text-xs"
              aria-label="Custom price protection in percent"
            />
            %
          </label>
        </div>
        {custom && (Number(custom) * 100 < MIN_SLIPPAGE_BPS || Number(custom) * 100 > MAX_SLIPPAGE_BPS) && (
          <p className="text-xs text-warn">
            Allowed range {pct(MIN_SLIPPAGE_BPS)} to {pct(MAX_SLIPPAGE_BPS)}; using {pct(bps)}.
          </p>
        )}
        {bps > 300 && <p className="text-xs text-warn">Above 3%, you may get a noticeably worse price than shown.</p>}
        {limits.length > 0 && (
          <div className="border-t border-line pt-2">
            <div className="mb-1 text-[11px] font-semibold text-muted">You sign these limits</div>
            {limits.map((l) => (
              <Row key={l.label} label={<Term tip={l.tip}>{l.label}</Term>} value={l.value} />
            ))}
          </div>
        )}
      </div>
    </Details>
  );
}
