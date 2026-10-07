/** FE-003: the flow continues only once every listed disclosure is ticked. */
import { useState } from "react";
import { createPortal } from "react-dom";
import { Check, ShieldCheck, X } from "lucide-react";
import { acknowledge, DISCLOSURES, type DisclosureId } from "../lib/optara/disclosures.ts";
import { cx } from "./ui.tsx";

export function DisclosureModal({
  ids,
  onAccept,
  onCancel,
}: {
  ids: DisclosureId[];
  onAccept: () => void;
  onCancel: () => void;
}) {
  const [ticked, setTicked] = useState<Set<DisclosureId>>(new Set());
  const all = ids.every((i) => ticked.has(i));

  const toggleAll = () => {
    if (all) {
      setTicked(new Set());
    } else {
      setTicked(new Set(ids));
    }
  };

  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/70 backdrop-blur-md animate-in fade-in duration-200"
      role="dialog"
      aria-modal="true"
      aria-labelledby="disclosure-title"
    >
      <div className="relative max-h-[90vh] w-full max-w-lg overflow-hidden rounded-3xl border border-line bg-surface p-6 shadow-2xl sm:p-7">
        {/* Glow */}
        <div className="pointer-events-none absolute -right-20 -top-20 h-48 w-48 rounded-full bg-primary/20 blur-3xl" />

        {/* Header */}
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-2xl bg-primary-soft text-primary">
              <ShieldCheck className="h-5 w-5" />
            </div>
            <div>
              <h2 id="disclosure-title" className="text-lg font-bold tracking-tight text-ink">
                Before you continue
              </h2>
              <p className="text-xs text-muted">Please read and confirm. You'll only be asked once.</p>
            </div>
          </div>
          <button
            onClick={onCancel}
            className="rounded-full p-1.5 text-muted hover:bg-surface-2 hover:text-ink transition"
            aria-label="Close"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        {/* Quick select-all shortcut */}
        <div className="mt-4 flex justify-end">
          <button
            type="button"
            onClick={toggleAll}
            className="text-xs font-semibold text-primary hover:underline"
          >
            {all ? "Deselect all" : "Select all"}
          </button>
        </div>

        {/* Disclosures list */}
        <ul className="mt-2 max-h-[50vh] overflow-y-auto space-y-2.5 pr-1">
          {ids.map((id) => {
            const on = ticked.has(id);
            const item = DISCLOSURES[id];
            if (!item) return null;
            return (
              <li key={id}>
                <label
                  className={cx(
                    "flex cursor-pointer items-start gap-3 rounded-2xl border p-3.5 transition-all",
                    on
                      ? "border-primary bg-primary-soft"
                      : "border-line bg-surface-2/60 hover:border-primary/50"
                  )}
                >
                  <input
                    type="checkbox"
                    className="mt-0.5 h-4 w-4 rounded accent-[var(--primary)]"
                    checked={on}
                    onChange={() =>
                      setTicked((s) => {
                        const n = new Set(s);
                        if (n.has(id)) n.delete(id);
                        else n.add(id);
                        return n;
                      })
                    }
                  />
                  <span>
                    <span className="block text-xs font-bold text-ink">{item.title}</span>
                    <span className="block text-[11px] text-muted leading-relaxed mt-0.5">
                      {item.text}
                    </span>
                  </span>
                </label>
              </li>
            );
          })}
        </ul>

        {/* Action Buttons */}
        <div className="mt-6 flex gap-3 pt-3 border-t border-line">
          <button type="button" className="btn-ghost flex-1 text-xs" onClick={onCancel}>
            Not now
          </button>
          <button
            type="button"
            className="btn-primary flex-1 text-xs font-bold"
            disabled={!all}
            onClick={() => {
              acknowledge(ids);
              onAccept();
            }}
          >
            I understand, continue
          </button>
        </div>
      </div>
    </div>,
    document.body
  );
}
