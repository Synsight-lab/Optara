/**
 * Building blocks for long-form pages (docs and blog). Headings get stable ids so the docs' "On this page" list and
 * shared links can jump to them.
 */
import { Children, isValidElement, type ReactNode } from "react";
import { Link } from "react-router";
import { AlertTriangle, ArrowRight, Info, Lightbulb, Link2, ShieldCheck } from "lucide-react";
import { cx } from "./ui.tsx";

export const slugify = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");

function textOf(node: ReactNode): string {
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(textOf).join("");
  if (isValidElement<{ children?: ReactNode }>(node)) return textOf(node.props.children);
  return "";
}

export function H2({ children, id }: { children: ReactNode; id?: string }) {
  const anchor = id ?? slugify(textOf(children));
  return (
    <h2 id={anchor} data-toc="2" className="prose-h2 group">
      <a href={`#${anchor}`} className="prose-anchor" aria-label="Link to this section">
        <Link2 className="h-4 w-4" />
      </a>
      {children}
    </h2>
  );
}

export function H3({ children, id }: { children: ReactNode; id?: string }) {
  const anchor = id ?? slugify(textOf(children));
  return (
    <h3 id={anchor} data-toc="3" className="prose-h3">
      {children}
    </h3>
  );
}

export const P = ({ children }: { children: ReactNode }) => <p className="prose-p">{children}</p>;
export const Lead = ({ children }: { children: ReactNode }) => <p className="prose-lead">{children}</p>;
export const UL = ({ children }: { children: ReactNode }) => <ul className="prose-ul">{children}</ul>;
export const B = ({ children }: { children: ReactNode }) => <strong className="font-semibold text-ink">{children}</strong>;
export const Code = ({ children }: { children: ReactNode }) => <code className="prose-code">{children}</code>;

/** An internal docs link, or an app link when it starts with /app. */
export function A({ to, children }: { to: string; children: ReactNode }) {
  if (/^https?:/.test(to))
    return (
      <a href={to} target="_blank" rel="noreferrer" className="prose-link">
        {children}
      </a>
    );
  return (
    <Link to={to} className="prose-link">
      {children}
    </Link>
  );
}

const CALLOUT = {
  note: { icon: Info, cls: "border-primary/30 bg-primary-soft", iconCls: "text-primary", title: "Note" },
  tip: { icon: Lightbulb, cls: "border-good/30 bg-good/8", iconCls: "text-good", title: "Tip" },
  warn: { icon: AlertTriangle, cls: "border-warn/35 bg-warn/8", iconCls: "text-warn", title: "Watch out" },
  safe: { icon: ShieldCheck, cls: "border-good/30 bg-good/8", iconCls: "text-good", title: "Safety" },
};

export function Callout({ kind = "note", title, children }: { kind?: keyof typeof CALLOUT; title?: string; children: ReactNode }) {
  const c = CALLOUT[kind];
  return (
    <div className={cx("my-6 flex gap-3 rounded-2xl border p-4", c.cls)}>
      <c.icon className={cx("mt-0.5 h-5 w-5 shrink-0", c.iconCls)} />
      <div className="min-w-0 text-[15px] leading-7 text-muted">
        <div className="mb-0.5 font-semibold text-ink">{title ?? c.title}</div>
        {children}
      </div>
    </div>
  );
}

/** Numbered steps with a connecting rail. Each child is one step: <Step title="...">body</Step>. */
export function Steps({ children }: { children: ReactNode }) {
  const items = Children.toArray(children);
  return (
    <ol className="my-6 space-y-0">
      {items.map((child, i) => (
        <li key={i} className="relative flex gap-4 pb-6 last:pb-0">
          {i < items.length - 1 && <span className="absolute left-[15px] top-9 bottom-1 w-px bg-line" />}
          <span className="num grid h-8 w-8 shrink-0 place-items-center rounded-full border border-primary/35 bg-primary-soft text-sm font-bold text-primary">
            {i + 1}
          </span>
          <div className="min-w-0 pt-1">{child}</div>
        </li>
      ))}
    </ol>
  );
}

export function Step({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <>
      <div className="font-semibold text-ink">{title}</div>
      {children && <div className="mt-1 text-[15px] leading-7 text-muted">{children}</div>}
    </>
  );
}

export function Table({ head, rows, compact }: { head: ReactNode[]; rows: ReactNode[][]; compact?: boolean }) {
  return (
    <div className="my-6 overflow-x-auto rounded-2xl border border-line">
      <table className={cx("w-full border-collapse text-left text-sm", head.length > 2 && "min-w-[520px]")}>
        <thead>
          <tr className="bg-surface-2/70">
            {head.map((h, i) => (
              <th key={i} className="px-4 py-2.5 text-[12px] font-bold uppercase tracking-[0.06em] text-faint">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} className="border-t border-line">
              {r.map((c, j) => (
                <td key={j} className={cx("align-top text-muted", compact ? "px-4 py-2" : "px-4 py-3 leading-6", j === 0 && "font-semibold text-ink")}>
                  {c}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** A left-to-right flow of boxes, wrapping on small screens. */
export function Flow({ items, caption }: { items: { title: string; text?: string; tone?: "primary" | "good" | "warn" }[]; caption?: string }) {
  return (
    <figure className="my-7">
      <div className="flex flex-col items-stretch gap-2 md:flex-row md:items-center">
        {items.map((it, i) => (
          <div key={i} className="flex flex-col items-center gap-2 md:flex-1 md:flex-row">
            <div
              className={cx(
                "w-full rounded-2xl border p-3.5 text-center",
                it.tone === "good" ? "border-good/35 bg-good/8" : it.tone === "warn" ? "border-warn/35 bg-warn/8" : it.tone === "primary" ? "border-primary/35 bg-primary-soft" : "border-line bg-surface-2/60",
              )}
            >
              <div className="text-sm font-semibold text-ink">{it.title}</div>
              {it.text && <div className="mt-1 text-xs leading-5 text-muted">{it.text}</div>}
            </div>
            {i < items.length - 1 && <ArrowRight className="h-4 w-4 shrink-0 rotate-90 text-faint md:rotate-0" />}
          </div>
        ))}
      </div>
      {caption && <figcaption className="mt-3 text-center text-xs text-faint">{caption}</figcaption>}
    </figure>
  );
}

/** A grid of small titled cards, e.g. key concepts. */
export function Cards({ items, cols = 2 }: { items: { title: string; text: ReactNode; to?: string; icon?: ReactNode }[]; cols?: 2 | 3 }) {
  return (
    <div className={cx("my-6 grid gap-3", cols === 3 ? "sm:grid-cols-3" : "sm:grid-cols-2")}>
      {items.map((it) => {
        const inner = (
          <>
            <div className="flex items-center gap-2 font-semibold text-ink">
              {it.icon}
              {it.title}
            </div>
            <div className="mt-1.5 text-sm leading-6 text-muted">{it.text}</div>
          </>
        );
        const cls = "group rounded-2xl border border-line bg-surface-2/40 p-4 transition hover:-translate-y-0.5 hover:border-primary/40 hover:bg-primary-soft/50";
        if (it.to && /^https?:/.test(it.to))
          return (
            <a key={it.title} href={it.to} target="_blank" rel="noreferrer" className={cls}>
              {inner}
            </a>
          );
        return it.to ? (
          <Link key={it.title} to={it.to} className={cls}>
            {inner}
          </Link>
        ) : (
          <div key={it.title} className="rounded-2xl border border-line bg-surface-2/40 p-4">
            {inner}
          </div>
        );
      })}
    </div>
  );
}

/** A worked example: inputs on the left, the arithmetic, and the result. */
export function Example({ title, lines, result }: { title: string; lines: [ReactNode, ReactNode][]; result: [ReactNode, ReactNode] }) {
  return (
    <div className="my-6 overflow-hidden rounded-2xl border border-line">
      <div className="border-b border-line bg-surface-2/70 px-4 py-2.5 text-[12px] font-bold uppercase tracking-[0.06em] text-faint">{title}</div>
      <div className="divide-y divide-line">
        {lines.map(([k, v], i) => (
          <div key={i} className="flex items-baseline justify-between gap-4 px-4 py-2.5 text-sm">
            <span className="text-muted">{k}</span>
            <span className="num text-right font-medium text-ink">{v}</span>
          </div>
        ))}
        <div className="flex items-baseline justify-between gap-4 bg-primary-soft px-4 py-3 text-sm">
          <span className="font-semibold text-ink">{result[0]}</span>
          <span className="num text-right font-display text-base font-bold text-ink">{result[1]}</span>
        </div>
      </div>
    </div>
  );
}

export function Formula({ children }: { children: ReactNode }) {
  return <pre className="prose-pre">{children}</pre>;
}
