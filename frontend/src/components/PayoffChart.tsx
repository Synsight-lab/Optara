/**
 * Profit or loss at expiry, as one explorer: pick a settlement price (drag on the chart, use the arrow keys, or tap a
 * preset) and the readout says in plain words what happens. Green is profit, red is loss; today's price, the strike
 * and breakeven are marked. All math comes from lib/optara/payoff.ts.
 */
import { useEffect, useId, useMemo, useRef, useState } from "react";
import { fmtLevelNum } from "../lib/optara/format.ts";
import { breakeven as breakevenOf, chartRange, extremes, niceTicks, payoutPerOption, profitAt, usd, type Leg } from "../lib/optara/payoff.ts";
import { cx } from "./ui.tsx";

export interface PayoffProps {
  optionType: number; // 0 call, 1 put
  strike: number;
  /** Underlying units per option; defaults to 1. */
  size?: number;
  spot?: number;
  premium: number; // per option, in the settlement asset: all-in cost (long) or amount received (short)
  qty: number;
  side: "long" | "short";
  assetSymbol: string;
  underlyingSymbol: string;
}

const SAMPLES = 200;

/** Short axis money: "+$1.2k", "+$150M", "−$50", "$0". */
function axisMoney(v: number): string {
  if (v === 0) return "$0";
  const abs = Math.abs(v);
  const units: [number, string][] = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "k"]];
  const [div, suffix] = units.find(([d]) => abs >= d) ?? [1, ""];
  const n = abs / div;
  const body = div === 1 ? fmtLevelNum(abs) : `${n >= 100 ? n.toFixed(0) : n >= 10 ? n.toFixed(1).replace(/\.0$/, "") : n.toFixed(2).replace(/\.?0+$/, "")}${suffix}`;
  return `${v > 0 ? "+" : "−"}$${body}`;
}

export function PayoffChart({ optionType, strike, size = 1, spot, premium, qty, side, assetSymbol, underlyingSymbol }: PayoffProps) {
  const premiumPerOption = Number.isFinite(premium) && premium > 0 ? premium : 0;
  const qtySafe = Number.isFinite(qty) && qty > 0 ? qty : 0;
  const svg = useRef<SVGSVGElement>(null);
  const box = useRef<HTMLDivElement>(null);
  const [W, setW] = useState(640);
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => e && setW(Math.max(280, Math.round(e.contentRect.width))));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const narrow = W < 480;
  const H = narrow ? 210 : 250;
  const PAD = { l: narrow ? 50 : 60, r: 10, t: 32, b: 28 };
  const uid = useId().replace(/:/g, "");
  const leg: Leg = useMemo(() => ({ optionType, strike, size }), [optionType, strike, size]);
  const be = breakevenOf(leg, premiumPerOption);
  const [lo, hi] = useMemo(() => chartRange([spot ?? strike, strike, be ?? strike]), [spot, strike, be]);

  // The price being explored. It follows today's price until the user picks one.
  const [picked, setPicked] = useState<number | undefined>();
  const price = Math.min(hi, Math.max(lo, picked ?? spot ?? strike));
  useEffect(() => setPicked(undefined), [strike, optionType, side]);

  const [dragging, setDragging] = useState(false);

  const pnl = (s: number) => profitAt(leg, side, qtySafe, premiumPerOption, s);
  const { points, yLo, yHi, yTicks } = useMemo(() => {
    const pts: [number, number][] = [];
    for (let i = 0; i <= SAMPLES; i++) {
      const s = lo + ((hi - lo) * i) / SAMPLES;
      pts.push([s, profitAt(leg, side, qtySafe, premiumPerOption, s)]);
    }
    const ys = pts.map((p) => p[1]);
    const a = Math.min(0, ...ys);
    const b = Math.max(0, ...ys);
    const pad = (b - a) * 0.1 || 1;
    const ticks = niceTicks(a, b, 4);
    // Keep the loss side labelled even when it is small next to the upside.
    if (a < 0 && !ticks.some((t) => t < 0)) ticks.push(a);
    if (b > 0 && !ticks.some((t) => t > 0)) ticks.push(b);
    if (!ticks.includes(0)) ticks.push(0);
    return { points: pts, yLo: a - pad, yHi: b + pad, yTicks: ticks };
  }, [lo, hi, leg, side, qtySafe, premiumPerOption]);

  const x = (s: number) => PAD.l + ((s - lo) / (hi - lo)) * (W - PAD.l - PAD.r);
  const y = (v: number) => PAD.t + ((yHi - v) / (yHi - yLo)) * (H - PAD.t - PAD.b);
  const line = points.map(([s, v], i) => `${i ? "L" : "M"}${x(s).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  const area = `${line} L${x(hi).toFixed(1)},${y(0).toFixed(1)} L${x(lo).toFixed(1)},${y(0).toFixed(1)} Z`;
  // Axis labels closer than 13px to the $0 label move away from it, so both stay readable.
  const labelY = (v: number) => {
    const base = y(v) + 4;
    if (v === 0) return base;
    const gap = y(v) - y(0);
    return Math.abs(gap) < 13 ? y(0) + 4 + (gap >= 0 ? 13 : -13) : base;
  };
  const xTicks = niceTicks(lo, hi, narrow ? 3 : 5).filter((t) => x(t) > PAD.l + 14 && x(t) < W - PAD.r - 14);

  const fromClientX = (clientX: number) => {
    const r = svg.current?.getBoundingClientRect();
    if (!r) return;
    const vx = ((clientX - r.left) / r.width) * W;
    setPicked(lo + ((Math.max(PAD.l, Math.min(W - PAD.r, vx)) - PAD.l) / (W - PAD.l - PAD.r)) * (hi - lo));
  };

  // Readout for the picked price.
  const net = pnl(price);
  const payout = payoutPerOption(leg, price) * qtySafe;
  const total = premiumPerOption * qtySafe;
  const fromToday = spot ? ((price - spot) / spot) * 100 : undefined;
  const { maxGain, maxLoss } = extremes(leg, side, qtySafe, premiumPerOption);
  const isLong = side === "long";
  const costLabel = isLong ? "Premium paid" : "Premium collected";
  const resultLabel = net >= 0 ? (isLong ? "Net profit" : "Writer profit") : (isLong ? "Net loss" : "Writer loss");
  const sentence =
    side === "long"
      ? payout === 0
        ? `The option pays nothing. You lose the ${usd(total)} you paid.`
        : net < 0
        ? `The option pays ${usd(payout)}, less than the ${usd(total)} you paid.`
        : `The option pays ${usd(payout)}, more than the ${usd(total)} you paid.`
      : payout === 0
      ? `You owe nothing and keep the whole ${usd(total)} premium.`
      : net >= 0
      ? `You owe ${usd(payout)} but keep the rest of the ${usd(total)} premium.`
      : `You owe ${usd(payout)}, more than the ${usd(total)} premium you collected.`;

  // Direction-aware presets: moves the option profits from, plus one against.
  const dir = (optionType === 0 ? 1 : -1) * (side === "long" ? 1 : -1);
  const presets = spot
    ? [
        { label: "Today", value: spot },
        ...[0.05, 0.1, 0.2, -0.1].map((m) => ({ label: `${m * dir > 0 ? "+" : "−"}${Math.abs(m * 100)}%`, value: spot * (1 + m * dir) })),
        ...(be !== undefined ? [{ label: "Breakeven", value: be }] : []),
      ].filter((p) => p.value >= lo && p.value <= hi)
    : [];

  // Top-row labels: strike drops to a second line when it would collide with "Today".
  const strikeRow = spot !== undefined && Math.abs(x(spot) - x(strike)) < 64 ? 2 : 1;
  const tone = net >= 0 ? "text-good" : "text-bad";

  return (
    <div className="space-y-3">
      {/* Plain-language readout */}
      <div className="rounded-2xl border border-line bg-surface-2/70 px-4 py-3">
        <div className="grid grid-cols-[1fr_auto] items-end gap-x-3 gap-y-1">
          <div>
          <div className="text-[13px] text-muted">If {underlyingSymbol} settles at</div>
          <div className="num font-display text-xl font-bold tracking-tight sm:text-2xl">
            ${fmtLevelNum(price)}
            {fromToday !== undefined && (
              <span className="block text-xs font-semibold text-muted sm:ml-1.5 sm:inline sm:text-[13px]">
                {Math.abs(fromToday) < 0.05 ? "today's price" : `${fromToday > 0 ? "+" : "−"}${Math.abs(fromToday).toFixed(1)}% from today`}
              </span>
            )}
          </div>
          </div>
          <div className="text-right">
          <div className="text-[13px] text-muted">{resultLabel}</div>
          <div className={cx("num font-display text-xl font-bold tracking-tight sm:text-2xl", tone)}>{usd(Math.abs(net))}</div>
          </div>
          <p className="col-span-2 text-[13px] text-muted">{sentence}</p>
        </div>
        <div className="mt-3 grid gap-2 text-center sm:grid-cols-3">
          <MiniFact label="Option payout" value={usd(payout)} />
          <MiniFact label={costLabel} value={usd(total)} />
          <MiniFact label="After premium" value={`${net >= 0 ? "+" : "-"}${usd(Math.abs(net))}`} tone={tone} />
        </div>
      </div>

      {/* Chart */}
      <div ref={box}>
      <svg
        ref={svg}
        viewBox={`0 0 ${W} ${H}`}
        className={cx("w-full select-none rounded-2xl outline-none focus-visible:ring-2 focus-visible:ring-primary/60", dragging ? "cursor-grabbing" : "cursor-pointer")}
        style={{ touchAction: "pan-y" }}
        role="slider"
        tabIndex={0}
        aria-label={`Settlement price of ${underlyingSymbol}`}
        aria-valuemin={lo}
        aria-valuemax={hi}
        aria-valuenow={price}
        aria-valuetext={`$${fmtLevelNum(price)}: ${net >= 0 ? "profit" : "loss"} ${usd(Math.abs(net))}`}
        onPointerDown={(e) => {
          setDragging(true);
          e.currentTarget.setPointerCapture(e.pointerId);
          fromClientX(e.clientX);
        }}
        onPointerMove={(e) => dragging && fromClientX(e.clientX)}
        onPointerUp={() => setDragging(false)}
        onPointerCancel={() => setDragging(false)}
        onKeyDown={(e) => {
          const step = (hi - lo) / 100;
          if (e.key === "ArrowRight" || e.key === "ArrowUp") setPicked(Math.min(hi, price + step));
          else if (e.key === "ArrowLeft" || e.key === "ArrowDown") setPicked(Math.max(lo, price - step));
          else if (e.key === "Home" && spot) setPicked(spot);
          else return;
          e.preventDefault();
        }}
      >
        <defs>
          <clipPath id={`above${uid}`}>
            <rect x="0" y="0" width={W} height={y(0)} />
          </clipPath>
          <clipPath id={`below${uid}`}>
            <rect x="0" y={y(0)} width={W} height={H} />
          </clipPath>
        </defs>

        {/* Grid and axes */}
        {yTicks.map((v) => (
          <g key={`y${v}`}>
            <line x1={PAD.l} x2={W - PAD.r} y1={y(v)} y2={y(v)} stroke="var(--muted)" strokeOpacity={v === 0 ? 0.6 : 0.12} />
            <text x={PAD.l - 8} y={labelY(v)} textAnchor="end" className="fill-[var(--muted)] text-[11px]">
              {axisMoney(v)}
            </text>
          </g>
        ))}
        {xTicks.map((t) => (
          <text key={`x${t}`} x={x(t)} y={H - 10} textAnchor="middle" className="fill-[var(--muted)] text-[11px]">
            ${fmtLevelNum(t)}
          </text>
        ))}

        {/* Profit (green) and loss (red) */}
        <path d={area} fill="var(--good)" fillOpacity="0.16" clipPath={`url(#above${uid})`} />
        <path d={area} fill="var(--bad)" fillOpacity="0.16" clipPath={`url(#below${uid})`} />
        <path d={line} fill="none" stroke="var(--good)" strokeWidth="2.5" strokeLinejoin="round" clipPath={`url(#above${uid})`} />
        <path d={line} fill="none" stroke="var(--bad)" strokeWidth="2.5" strokeLinejoin="round" clipPath={`url(#below${uid})`} />
        <text x={W - PAD.r - 4} y={PAD.t + 4} textAnchor="end" className="fill-[var(--good)] text-[11px] font-semibold">
          profit
        </text>
        <text x={W - PAD.r - 4} y={H - PAD.b - 6} textAnchor="end" className="fill-[var(--bad)] text-[11px] font-semibold">
          loss
        </text>

        {/* Markers: strike, today, breakeven */}
        <line x1={x(strike)} x2={x(strike)} y1={PAD.t} y2={H - PAD.b} stroke="var(--muted)" strokeDasharray="2 4" strokeOpacity="0.7" />
        <text x={x(strike)} y={strikeRow === 1 ? 13 : 27} textAnchor="middle" className="fill-[var(--muted)] text-[11px]">
          strike
        </text>
        {spot !== undefined && spot >= lo && spot <= hi && (
          <g>
            <line x1={x(spot)} x2={x(spot)} y1={PAD.t} y2={H - PAD.b} stroke="var(--accent)" strokeDasharray="5 4" strokeOpacity="0.8" />
            <text x={x(spot)} y={13} textAnchor="middle" className="fill-[var(--accent)] text-[11px] font-semibold">
              today
            </text>
          </g>
        )}
        {be !== undefined && be > lo && be < hi && (
          <g>
            <circle cx={x(be)} cy={y(0)} r="4.5" fill="var(--warn)" stroke="var(--bg)" strokeWidth="1.5" />
            {Math.abs(x(be) - x(price)) > 40 && x(be) < W - PAD.r - 70 && (
              <text x={x(be)} y={y(0) + 16} textAnchor="middle" className="fill-[var(--warn)] text-[11px] font-semibold">
                breakeven
              </text>
            )}
          </g>
        )}

        {/* The explored price */}
        <line x1={x(price)} x2={x(price)} y1={PAD.t} y2={H - PAD.b} stroke="var(--ink)" strokeOpacity="0.5" />
        <circle cx={x(price)} cy={y(net)} r="7" fill={net >= 0 ? "var(--good)" : "var(--bad)"} stroke="var(--bg)" strokeWidth="2.5" />
      </svg>
      </div>

      {/* Presets */}
      {presets.length > 0 && (
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="mr-1 text-xs text-muted">Try:</span>
          {presets.map((p) => (
            <button
              key={p.label}
              type="button"
              onClick={() => setPicked(p.value)}
              className={cx("chip cursor-pointer !py-1 !text-xs", Math.abs(p.value - price) < (hi - lo) / 400 && "!border-primary/60 !text-primary")}
            >
              {p.label}
            </button>
          ))}
        </div>
      )}

      {/* The three numbers that matter */}
      <div className="grid grid-cols-3 gap-2 text-center">
        <Fact label="Breakeven price" value={be !== undefined ? `$${fmtLevelNum(be)}` : "No breakeven"} dot="bg-warn" />
        <Fact label={isLong ? "Best case" : "Most you can make"} value={maxGain === "unlimited" ? "No limit" : usd(maxGain)} tone="text-good" />
        <Fact label={isLong ? "Max loss" : "Worst case"} value={maxLoss === "unlimited" ? "No limit" : usd(maxLoss)} tone="text-bad" />
      </div>
      <p className="text-xs text-muted">
        Breakeven includes the premium shown by the order form. Drag across the chart, use the arrow keys, or tap a button to try a settlement price. Amounts are in {assetSymbol}.
      </p>
    </div>
  );
}

function MiniFact({ label, value, tone }: { label: string; value: string; tone?: string }) {
  return (
    <div className="rounded-lg border border-line/70 bg-surface/60 px-2 py-2">
      <div className="text-[11px] font-semibold text-muted">{label}</div>
      <div className={cx("num mt-0.5 text-sm font-bold", tone)}>{value}</div>
    </div>
  );
}

function Fact({ label, value, tone, dot }: { label: string; value: string; tone?: string; dot?: string }) {
  return (
    <div className="rounded-xl border border-line bg-surface-2/60 px-2 py-2">
      <div className="flex items-center justify-center gap-1 text-[11px] text-muted">
        {dot && <span className={cx("h-2 w-2 rounded-full", dot)} />}
        {label}
      </div>
      <div className={cx("num font-display mt-0.5 text-sm font-bold", tone)}>{value}</div>
    </div>
  );
}
