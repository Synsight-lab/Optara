import { useToasts } from "../state.tsx";
import { explorerTx } from "./TxButton.tsx";
import { cx } from "./ui.tsx";

export function Toaster() {
  const { toasts, dismiss } = useToasts();
  return (
    <div className="pointer-events-none fixed bottom-4 right-4 z-50 flex w-[min(92vw,380px)] flex-col gap-2" aria-live="polite">
      {toasts.map((t) => {
        const link = t.hash ? explorerTx(t.hash) : undefined;
        return (
          <div key={t.id} className={cx("pointer-events-auto card rise flex gap-3 p-4 shadow-xl", t.tone === "good" && "border-good/40", t.tone === "bad" && "border-bad/40")}>
            <span className={cx("mt-0.5 grid h-6 w-6 shrink-0 place-items-center rounded-full text-xs font-bold", t.tone === "good" ? "bg-good text-black" : t.tone === "bad" ? "bg-bad text-white" : "bg-primary text-white")}>
              {t.tone === "good" ? "✓" : t.tone === "bad" ? "!" : "i"}
            </span>
            <div className="min-w-0 flex-1">
              <div className="text-sm font-semibold">{t.title}</div>
              {t.body && <div className="mt-0.5 text-sm text-muted">{t.body}</div>}
              {link && (
                <a className="mt-1 inline-block text-xs text-primary hover:underline" href={link} target="_blank" rel="noreferrer">
                  View transaction ↗
                </a>
              )}
            </div>
            <button className="self-start text-muted hover:text-ink" onClick={() => dismiss(t.id)} aria-label="Dismiss">
              ×
            </button>
          </div>
        );
      })}
    </div>
  );
}
