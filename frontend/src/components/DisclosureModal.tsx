/** FE-003: the flow continues only once every listed disclosure is ticked. */
import { useState } from "react";
import { createPortal } from "react-dom";
import { acknowledge, DISCLOSURES, type DisclosureId } from "../lib/optara/disclosures.ts";
import { cx } from "./ui.tsx";

export function DisclosureModal({ ids, onAccept, onCancel }: { ids: DisclosureId[]; onAccept: () => void; onCancel: () => void }) {
  const [ticked, setTicked] = useState<Set<DisclosureId>>(new Set());
  const all = ids.every((i) => ticked.has(i));
  // Portalled: a card's backdrop-filter would otherwise become the containing block of this fixed overlay.
  return createPortal(
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/60 p-4 backdrop-blur-sm" role="dialog" aria-modal="true" aria-labelledby="disclosure-title">
      <div className="card max-h-[90vh] w-full max-w-lg overflow-y-auto bg-surface p-6 shadow-[var(--shadow-glow)]">
        <h2 id="disclosure-title" className="text-lg font-semibold">
          Before you continue
        </h2>
        <p className="mt-1 text-sm text-muted">Please read and confirm. You'll only be asked once.</p>
        <ul className="mt-5 space-y-2.5">
          {ids.map((id) => {
            const on = ticked.has(id);
            return (
              <li key={id}>
                <label className={cx("flex cursor-pointer gap-3 rounded-xl border p-3.5 transition", on ? "border-primary bg-primary-soft" : "border-line hover:border-primary/50")}>
                  <input
                    type="checkbox"
                    className="mt-0.5 h-4 w-4 accent-[var(--primary)]"
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
                    <span className="block text-sm font-semibold">{DISCLOSURES[id].title}</span>
                    <span className="block text-sm text-muted">{DISCLOSURES[id].text}</span>
                  </span>
                </label>
              </li>
            );
          })}
        </ul>
        <div className="mt-6 flex gap-3">
          <button className="btn-ghost flex-1" onClick={onCancel}>
            Not now
          </button>
          <button
            className="btn-primary flex-1"
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
    document.body,
  );
}
