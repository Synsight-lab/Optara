/**
 * Profit or loss at expiry against the settlement price, for buying (long) or writing (short) `qty` options at
 * `premium` each. Hover or drag across the chart to read any point; today's spot and breakeven are marked.
 */
import { useId, useMemo, useRef, useState } from "react";

export interface PayoffProps {
  optionType: number; // 0 call, 1 put
  strike: number;
  spot?: number;
  premium: number; // per option, in the settlement asset
  qty: number;
  side: "long" | "short";
  assetSymbol: string;
  underlyingSymbol: string;
}

const W = 640;
const H = 260;
const PAD = { l: 56, r: 16, t: 16, b: 34 };

const money = (x: number) => `${x < 0 ? "−" : ""}$${Math.abs(x).toLocaleString(undefined, { maximumFractionDigits: Math.abs(x) < 100 ? 2 : 0 })}`;

export function PayoffChart({ optionType, strike, spot, premium, qty, side, assetSymbol, underlyingSymbol }: PayoffProps) {
  const svg = useRef<SVGSVGElement>(null);
  const uid = useId().replace(/:/g, "");
  const [hoverX, setHoverX] = useState<number | undefined>();
  const sign = side === "long" ? 1 : -1;
  const center = spot ?? strike;
  const lo = Math.max(0, Math.min(center, strike) * 0.55);
  const hi = Math.max(center, strike) * 1.55;
  const pnl = (s: number) => sign * qty * ((optionType === 0 ? Math.max(s - strike, 0) : Math.max(strike - s, 0)) - premium);
  const breakeven = optionType === 0 ? strike + premium : strike - premium;

  const { points, yMin, yMax } = useMemo(() => {
    const pts: [number, number][] = [];
    for (let i = 0; i <= 160; i++) {
      const s = lo + ((hi - lo) * i) / 160;
      pts.push([s, pnl(s)]);
    }
    const ys = pts.map((p) => p[1]);
    let a = Math.min(0, ...ys);
    let b = Math.max(0, ...ys);
    const pad = (b - a) * 0.12 || 1;
    a -= pad;
    b += pad;
    return { points: pts, yMin: a, yMax: b };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lo, hi, strike, premium, qty, side, optionType]);

  const x = (s: number) => PAD.l + ((s - lo) / (hi - lo)) * (W - PAD.l - PAD.r);
  const y = (v: number) => PAD.t + ((yMax - v) / (yMax - yMin)) * (H - PAD.t - PAD.b);
  const line = points.map(([s, v], i) => `${i ? "L" : "M"}${x(s).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  const area = `${line} L${x(hi).toFixed(1)},${y(0).toFixed(1)} L${x(lo).toFixed(1)},${y(0).toFixed(1)} Z`;

  const hoverS = hoverX === undefined ? undefined : lo + ((hoverX - PAD.l) / (W - PAD.l - PAD.r)) * (hi - lo);
  const hoverV = hoverS === undefined ? undefined : pnl(hoverS);
  const ticks = Array.from({ length: 5 }, (_, i) => lo + ((hi - lo) * i) / 4);

  const onMove = (clientX: number) => {
    const r = svg.current?.getBoundingClientRect();
    if (!r) return;
    const vx = ((clientX - r.left) / r.width) * W;
    setHoverX(Math.max(PAD.l, Math.min(W - PAD.r, vx)));
  };

  return (
    <div className="relative">
      <svg
        ref={svg}
        viewBox={`0 0 ${W} ${H}`}
        className="w-full touch-none select-none"
        role="img"
        aria-label={`Profit or loss at expiry for ${side === "long" ? "buying" : "writing"} ${qty} options`}
        onMouseMove={(e) => onMove(e.clientX)}
        onMouseLeave={() => setHoverX(undefined)}
        onTouchMove={(e) => e.touches[0] && onMove(e.touches[0].clientX)}
        onTouchEnd={() => setHoverX(undefined)}
      >
        <defs>
          <clipPath id={`above${uid}`}>
            <rect x="0" y="0" width={W} height={y(0)} />
          </clipPath>
          <clipPath id={`below${uid}`}>
            <rect x="0" y={y(0)} width={W} height={H} />
          </clipPath>
          <linearGradient id={`gain${uid}`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="var(--good)" stopOpacity="0.35" />
            <stop offset="100%" stopColor="var(--good)" stopOpacity="0.02" />
          </linearGradient>
          <linearGradient id={`loss${uid}`} x1="0" y1="1" x2="0" y2="0">
            <stop offset="0%" stopColor="var(--bad)" stopOpacity="0.35" />
            <stop offset="100%" stopColor="var(--bad)" stopOpacity="0.02" />
          </linearGradient>
        </defs>
        {/* axes */}
        <line x1={PAD.l} x2={W - PAD.r} y1={y(0)} y2={y(0)} stroke="var(--muted)" strokeOpacity="0.45" />
        {ticks.map((t) => (
          <text key={t} x={x(t)} y={H - 10} textAnchor="middle" className="fill-[var(--muted)] text-[11px]">
            {Math.round(t).toLocaleString()}
          </text>
        ))}
        {[yMax * 0.9, 0, yMin * 0.9].map((v) => (
          <text key={v} x={PAD.l - 8} y={y(v) + 4} textAnchor="end" className="fill-[var(--muted)] text-[11px]">
            {money(v)}
          </text>
        ))}
        <path d={area} fill={`url(#gain${uid})`} clipPath={`url(#above${uid})`} />
        <path d={area} fill={`url(#loss${uid})`} clipPath={`url(#below${uid})`} />
        <path d={line} fill="none" stroke="var(--primary)" strokeWidth="2.5" strokeLinejoin="round" />
        {/* strike and breakeven */}
        <line x1={x(strike)} x2={x(strike)} y1={PAD.t} y2={H - PAD.b} stroke="var(--muted)" strokeDasharray="2 4" strokeOpacity="0.6" />
        {breakeven > lo && breakeven < hi && (
          <g>
            <circle cx={x(breakeven)} cy={y(0)} r="4" fill="var(--warn)" />
            <text
              x={x(breakeven)}
              y={y(0) + (Math.abs(y(0) - PAD.t) < 40 || (spot !== undefined && Math.abs(x(spot) - x(breakeven)) < 110) ? 18 : -9)}
              textAnchor="middle"
              className="fill-[var(--warn)] text-[11px] font-semibold"
            >
              breakeven {Math.round(breakeven).toLocaleString()}
            </text>
          </g>
        )}
        {spot !== undefined && spot > lo && spot < hi && (
          <g>
            <line x1={x(spot)} x2={x(spot)} y1={PAD.t} y2={H - PAD.b} stroke="var(--accent)" strokeDasharray="5 4" />
            <text x={x(spot) + 5} y={PAD.t + 12} className="fill-[var(--accent)] text-[11px] font-semibold">
              now {Math.round(spot).toLocaleString()}
            </text>
          </g>
        )}
        {hoverX !== undefined && hoverS !== undefined && hoverV !== undefined && (
          <g>
            <line x1={hoverX} x2={hoverX} y1={PAD.t} y2={H - PAD.b} stroke="var(--ink)" strokeOpacity="0.35" />
            <circle cx={hoverX} cy={y(hoverV)} r="5" fill="var(--primary)" stroke="var(--bg)" strokeWidth="2" />
          </g>
        )}
      </svg>
      <div className="mt-2 flex min-h-10 flex-wrap items-center justify-between gap-2 rounded-xl bg-surface-2 px-3.5 py-2 text-sm">
        {hoverS !== undefined && hoverV !== undefined ? (
          <>
            <span className="text-muted">
              If {underlyingSymbol} settles at <b className="num text-ink">{Math.round(hoverS).toLocaleString()}</b>
            </span>
            <span className={`num font-semibold ${hoverV >= 0 ? "text-good" : "text-bad"}`}>
              {hoverV >= 0 ? "you make " : "you lose "}
              {money(Math.abs(hoverV))} {assetSymbol}
            </span>
          </>
        ) : (
          <span className="text-muted">Move across the chart to see your result at any settlement price.</span>
        )}
      </div>
    </div>
  );
}
