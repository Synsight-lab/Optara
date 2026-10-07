/** Small UI primitives shared by every page. */
import { useEffect, useId, useState, type ReactNode } from "react";
import type { Tone } from "../lib/optara/health.ts";

export const cx = (...xs: (string | false | null | undefined)[]) => xs.filter(Boolean).join(" ");

export function Card({ children, className, title, action }: { children: ReactNode; className?: string; title?: ReactNode; action?: ReactNode }) {
  return (
    <section className={cx("card p-5 rise", className)}>
      {(title || action) && (
        <header className="mb-4 flex items-center justify-between gap-3">
          {title && <h2 className="text-base font-semibold">{title}</h2>}
          {action}
        </header>
      )}
      {children}
    </section>
  );
}

const toneClass: Record<Tone | "primary" | "accent", string> = {
  good: "bg-good/15 text-good",
  warn: "bg-warn/15 text-warn",
  bad: "bg-bad/15 text-bad",
  neutral: "bg-muted/15 text-muted",
  primary: "bg-primary-soft text-primary",
  accent: "bg-accent/15 text-accent",
};

export function Pill({ tone = "neutral", children, dot }: { tone?: Tone | "primary" | "accent"; children: ReactNode; dot?: boolean }) {
  return (
    <span className={cx("pill", toneClass[tone])}>
      {dot && <span className="live-dot inline-block h-1.5 w-1.5 rounded-full bg-current" />}
      {children}
    </span>
  );
}

export function Stat({ label, value, sub, tone }: { label: ReactNode; value: ReactNode; sub?: ReactNode; tone?: Tone }) {
  const color = tone === "good" ? "text-good" : tone === "warn" ? "text-warn" : tone === "bad" ? "text-bad" : "";
  return (
    <div className="min-w-0">
      <div className="label">{label}</div>
      <div className={cx("num mt-1 truncate text-xl font-semibold", color)}>{value}</div>
      {sub && <div className="mt-0.5 truncate text-xs text-muted">{sub}</div>}
    </div>
  );
}

export const Skeleton = ({ className }: { className?: string }) => <div className={cx("animate-pulse rounded-lg bg-surface-2", className ?? "h-5 w-24")} />;

/** A term with a plain-language explanation on hover/focus (IM, MM, IV…). */
export function Term({ children, tip }: { children: ReactNode; tip: string }) {
  const id = useId();
  return (
    <span className="group relative inline-flex cursor-help items-center gap-1 underline decoration-dotted decoration-muted/60 underline-offset-4" tabIndex={0} aria-describedby={id}>
      {children}
      <span
        role="tooltip"
        id={id}
        className="pointer-events-none absolute left-1/2 top-full z-30 mt-2 hidden w-64 max-w-[80vw] -translate-x-1/2 rounded-xl border border-line bg-surface-2 p-3 text-xs font-normal normal-case tracking-normal text-ink shadow-xl group-hover:block group-focus:block"
      >
        {tip}
      </span>
    </span>
  );
}

export function Segmented<T extends string>({ value, onChange, options, size = "md" }: { value: T; onChange: (v: T) => void; options: { value: T; label: ReactNode; disabled?: boolean; title?: string }[]; size?: "sm" | "md" }) {
  return (
    <div role="tablist" className="inline-flex gap-1 rounded-xl border border-line bg-surface-2 p-1">
      {options.map((o) => (
        <button
          key={o.value}
          role="tab"
          aria-selected={value === o.value}
          disabled={o.disabled}
          title={o.title}
          onClick={() => onChange(o.value)}
          className={cx(
            "rounded-lg font-medium transition disabled:opacity-35",
            size === "sm" ? "px-2.5 py-1 text-xs" : "px-3.5 py-1.5 text-sm",
            value === o.value ? "bg-primary text-white shadow" : "text-muted hover:text-ink",
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function EmptyState({ icon = "◇", title, body, action }: { icon?: ReactNode; title: string; body?: ReactNode; action?: ReactNode }) {
  return (
    <div className="flex flex-col items-center gap-3 py-10 text-center">
      <div className="grid h-12 w-12 place-items-center rounded-2xl bg-primary-soft text-xl text-primary">{icon}</div>
      <div className="font-semibold">{title}</div>
      {body && <div className="max-w-sm text-sm text-muted">{body}</div>}
      {action}
    </div>
  );
}

export const Spinner = ({ className }: { className?: string }) => (
  <span className={cx("inline-block h-4 w-4 animate-spin rounded-full border-2 border-current border-t-transparent", className)} />
);

/** A number input with a unit, quick presets and a Max button. */
export function AmountInput({
  label,
  value,
  onChange,
  unit,
  max,
  maxLabel,
  presets,
  hint,
  invalid,
}: {
  label: ReactNode;
  value: string;
  onChange: (v: string) => void;
  unit: string;
  max?: string;
  maxLabel?: string;
  presets?: string[];
  hint?: ReactNode;
  invalid?: string;
}) {
  const id = useId();
  return (
    <div>
      <div className="mb-1.5 flex items-baseline justify-between">
        <label htmlFor={id} className="label">
          {label}
        </label>
        {max !== undefined && (
          <button type="button" className="text-xs font-medium text-primary hover:underline" onClick={() => onChange(max)}>
            {maxLabel ?? "Max"}: {max.replace(/^(\d+)/, (i) => i.replace(/\B(?=(\d{3})+(?!\d))/g, ","))}
          </button>
        )}
      </div>
      <div className="relative">
        <input
          id={id}
          inputMode="decimal"
          autoComplete="off"
          className={cx("input num pr-20 text-lg", invalid && "border-bad focus:border-bad focus:ring-bad/30")}
          placeholder="0.00"
          value={value}
          onChange={(e) => onChange(e.target.value.replace(/[^\d.]/g, ""))}
          aria-invalid={!!invalid}
        />
        <span className="pointer-events-none absolute right-3.5 top-1/2 -translate-y-1/2 text-sm font-medium text-muted">{unit}</span>
      </div>
      {presets && (
        <div className="mt-2 flex flex-wrap gap-1.5">
          {presets.map((p) => (
            <button key={p} type="button" onClick={() => onChange(p)} className={cx("rounded-lg border px-2.5 py-1 text-xs font-medium transition", value === p ? "border-primary bg-primary-soft text-primary" : "border-line text-muted hover:text-ink")}>
              {p}
            </button>
          ))}
        </div>
      )}
      {invalid ? <p className="mt-1.5 text-xs text-bad">{invalid}</p> : hint && <p className="mt-1.5 text-xs text-muted">{hint}</p>}
    </div>
  );
}

export function CopyButton({ text, label }: { text: string; label?: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      type="button"
      className="rounded-md px-1.5 text-xs text-muted hover:text-primary"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(text);
          setDone(true);
          setTimeout(() => setDone(false), 1200);
        } catch {
          // clipboard unavailable
        }
      }}
      aria-label={`Copy ${label ?? "value"}`}
    >
      {done ? "Copied" : "Copy"}
    </button>
  );
}

/** Ticks every second between chain-time refreshes so countdowns move smoothly. */
export function useTicker(base: bigint | undefined): bigint | undefined {
  const [offset, setOffset] = useState(0);
  useEffect(() => {
    setOffset(0);
    const t = setInterval(() => setOffset((o) => o + 1), 1000);
    return () => clearInterval(t);
  }, [base]);
  return base === undefined ? undefined : base + BigInt(offset);
}

export function Row({ label, value, strong, tone }: { label: ReactNode; value: ReactNode; strong?: boolean; tone?: Tone }) {
  const color = tone === "good" ? "text-good" : tone === "bad" ? "text-bad" : tone === "warn" ? "text-warn" : "";
  return (
    <div className={cx("flex items-center justify-between gap-4 py-1.5 text-sm", strong && "border-t border-line pt-2.5 font-semibold")}>
      <span className="text-muted">{label}</span>
      <span className={cx("num text-right", color)}>{value}</span>
    </div>
  );
}
