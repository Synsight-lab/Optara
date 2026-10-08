/** Shared primitives — quiet surfaces, one loud chart. Sentence case, no eyebrow caps. */
import { useEffect, useId, useState, type ReactNode } from "react";
import type { Tone } from "../lib/optara/health.ts";

export const cx = (...xs: (string | false | null | undefined)[]) => xs.filter(Boolean).join(" ");

export function Card({ children, className, title, action }: { children: ReactNode; className?: string; title?: ReactNode; action?: ReactNode }) {
  return (
    <section className={cx("card rise p-5 sm:p-6", className)}>
      {(title || action) && (
        <header className="mb-4 flex flex-wrap items-center justify-between gap-2">
          {title && <h2 className="font-display text-[17px] font-semibold tracking-tight">{title}</h2>}
          {action}
        </header>
      )}
      {children}
    </section>
  );
}

export function Ticket({ children, className }: { children: ReactNode; className?: string }) {
  return <section className={cx("ticket rise p-5 sm:p-6", className)}>{children}</section>;
}

const toneClass: Record<Tone | "primary" | "accent", string> = {
  good: "bg-good/12 text-good border border-good/25",
  warn: "bg-warn/12 text-warn border border-warn/25",
  bad: "bg-bad/12 text-bad border border-bad/25",
  neutral: "bg-surface-2 text-muted border border-line",
  primary: "bg-primary-soft text-primary border border-primary/25",
  accent: "bg-accent/12 text-accent border border-accent/25",
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
      <div className={cx("num font-display mt-1 truncate text-[22px] font-semibold tracking-tight", color)}>{value}</div>
      {sub && <div className="mt-0.5 truncate text-xs text-muted">{sub}</div>}
    </div>
  );
}

export const Skeleton = ({ className }: { className?: string }) => <div className={cx("animate-pulse rounded-xl bg-surface-2", className ?? "h-5 w-24")} />;

/** Plain-language hint on hover/focus (margin, IV…). */
export function Term({ children, tip }: { children: ReactNode; tip: string }) {
  const id = useId();
  return (
    <span className="group relative inline-flex cursor-help items-center gap-1 underline decoration-dotted decoration-faint/70 underline-offset-4" tabIndex={0} aria-describedby={id}>
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
            "rounded-lg font-semibold transition disabled:opacity-35 cursor-pointer",
            size === "sm" ? "px-2.5 py-1.5 text-[13px]" : "px-3.5 py-2 text-sm",
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
    <div className="flex flex-col items-center gap-2.5 px-4 py-10 text-center">
      <div className="font-display grid h-12 w-12 place-items-center rounded-2xl bg-primary-soft text-xl text-primary">{icon}</div>
      <div className="font-display text-[16px] font-semibold tracking-tight">{title}</div>
      {body && <div className="max-w-sm text-sm leading-relaxed text-muted">{body}</div>}
      {action && <div className="mt-2">{action}</div>}
    </div>
  );
}

export const Spinner = ({ className }: { className?: string }) => (
  <span className={cx("inline-block h-4 w-4 animate-spin rounded-full border-2 border-current border-t-transparent", className)} />
);

/** Large-tap-amount field with presets and wallet max. */
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
      <div className="mb-1.5 flex items-baseline justify-between gap-2">
        <label htmlFor={id} className="label">
          {label}
        </label>
        {max !== undefined && (
          <button type="button" className="text-[13px] font-semibold text-primary hover:underline cursor-pointer" onClick={() => onChange(max)}>
            {maxLabel ?? "Max"} · {max.replace(/^(\d+)/, (i) => i.replace(/\B(?=(\d{3})+(?!\d))/g, ","))}
          </button>
        )}
      </div>
      <div className="relative">
        <input
          id={id}
          inputMode="decimal"
          autoComplete="off"
          className={cx("input num font-display pr-20 text-[22px] font-semibold tracking-tight", invalid && "border-bad focus:border-bad focus:ring-bad/30")}
          placeholder="0.00"
          value={value}
          onChange={(e) => onChange(e.target.value.replace(/[^\d.]/g, ""))}
          aria-invalid={!!invalid}
        />
        <span className="pointer-events-none absolute right-3.5 top-1/2 -translate-y-1/2 text-sm font-semibold text-muted">{unit}</span>
      </div>
      {presets && (
        <div className="mt-2 flex flex-wrap gap-1.5">
          {presets.map((p) => (
            <button key={p} type="button" onClick={() => onChange(p)} className={cx("chip", value === p && "border-primary/50 bg-primary-soft text-primary")}>
              {p}
            </button>
          ))}
        </div>
      )}
      {invalid ? <p className="mt-1.5 text-[13px] font-medium text-bad">{invalid}</p> : hint && <p className="mt-1.5 text-[13px] text-muted">{hint}</p>}
    </div>
  );
}

export function CopyButton({ text, label }: { text: string; label?: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      type="button"
      className="rounded-md px-1.5 text-xs text-muted hover:text-primary cursor-pointer"
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
      <span className={cx("num text-right font-medium", color)}>{value}</span>
    </div>
  );
}

/** Collapsible fee / detail block — keeps tickets scannable. */
export function Details({ summary, children, defaultOpen = false }: { summary: ReactNode; children: ReactNode; defaultOpen?: boolean }) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className="rounded-xl border border-line bg-surface-2/60">
      <button type="button" onClick={() => setOpen((o) => !o)} aria-expanded={open} className="flex w-full items-center justify-between gap-3 px-3.5 py-2.5 text-left cursor-pointer">
        <span className="text-[13px] font-semibold">{summary}</span>
        <span className="text-muted text-sm">{open ? "–" : "+"}</span>
      </button>
      {open && <div className="border-t border-line px-3.5 py-2">{children}</div>}
    </div>
  );
}
