import { useState, type ReactNode } from "react";
import {
  lifecycleLabel, LIVENESS_DISCLOSURE, VENUE_BOUNDARY_NOTES, WRITER_LIVENESS_DISCLOSURE, type Lifecycle,
} from "../lib/optara/lifecycle.ts";
import { parseUnitsStrict } from "../lib/optara/format.ts";

export function Card({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <section className="rounded-lg border border-slate-800 bg-slate-900/60 p-4">
      {title && <h2 className="mb-3 text-sm font-semibold uppercase tracking-wide text-slate-400">{title}</h2>}
      {children}
    </section>
  );
}

export function StatusBadge({ lifecycle }: { lifecycle: Lifecycle }) {
  const color: Record<Lifecycle["kind"], string> = {
    ACTIVE: "bg-emerald-900 text-emerald-200",
    AWAITING_PRICE: "bg-amber-900 text-amber-200",
    ORACLE_STALLED: "bg-red-900 text-red-200",
    SETTLED: "bg-sky-900 text-sky-200",
    UNKNOWN: "bg-slate-800",
  };
  return <span data-testid="lifecycle" className={`rounded px-2 py-0.5 text-xs ${color[lifecycle.kind]}`}>{lifecycleLabel(lifecycle)}</span>;
}

/**
 * KUR-013 / ORACLE_AND_SETTLEMENT.md section 19: the paths inside stay hidden until the settlement-liveness risk has
 * been shown and acknowledged. `buyer` gates acquisition of a long; `writer` gates entering a short.
 */
export function LivenessGate({ children, role = "buyer" }: { children: ReactNode; role?: "buyer" | "writer" }) {
  const [ack, setAck] = useState(false);
  const writer = role === "writer";
  return (
    <div className="space-y-3">
      <p data-testid="liveness-disclosure" className="rounded border border-amber-800 bg-amber-950/40 p-3 text-sm text-amber-100">
        {writer ? WRITER_LIVENESS_DISCLOSURE : LIVENESS_DISCLOSURE}
      </p>
      {!writer && (
        <ul className="list-disc pl-5 text-xs text-slate-400">
          {VENUE_BOUNDARY_NOTES.map((n) => <li key={n}>{n}</li>)}
        </ul>
      )}
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} />
        {writer ? "I understand expiry does not release my margin." : "I understand expiry is not a guaranteed payout date."}
      </label>
      {ack && <div data-testid={writer ? "write-paths" : "acquisition-paths"}>{children}</div>}
    </div>
  );
}

/** Decimal input that yields exact integer units, or an error for invalid precision. */
export function AmountInput({ label, decimals, onChange }: { label: string; decimals: number; onChange: (v: bigint | undefined) => void }) {
  const [text, setText] = useState("");
  const [err, setErr] = useState<string>();
  return (
    <label className="flex flex-col gap-1 text-sm">
      <span className="text-slate-400">{label}</span>
      <input
        className="rounded border border-slate-700 bg-slate-950 px-2 py-1"
        value={text}
        inputMode="decimal"
        placeholder="0.0"
        onChange={(e) => {
          setText(e.target.value);
          if (e.target.value === "") {
            setErr(undefined);
            onChange(undefined);
            return;
          }
          try {
            const v = parseUnitsStrict(e.target.value, decimals);
            setErr(undefined);
            onChange(v);
          } catch (x) {
            setErr((x as Error).message);
            onChange(undefined);
          }
        }}
      />
      {err && <span className="text-xs text-red-400">{err}</span>}
    </label>
  );
}

export function Row({ k, v }: { k: string; v: ReactNode }) {
  return (
    <div className="flex justify-between gap-4 border-b border-slate-800/60 py-1 text-sm">
      <span className="text-slate-400">{k}</span>
      <span className="text-right font-mono">{v}</span>
    </div>
  );
}
