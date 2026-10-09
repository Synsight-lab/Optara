/**
 * The approval window for local test wallets. They have no browser extension (anvil holds their keys and signs), so
 * without this a transaction would go through with no confirmation at all. It stands in for the wallet popup:
 * the user sees what is about to happen and approves or rejects each transaction.
 */
import { createPortal } from "react-dom";
import { FlaskConical, X } from "lucide-react";
import { NETWORK_LABEL, CHAIN } from "../config/network.ts";
import { shortAddr } from "../lib/optara/format.ts";

export interface TestConfirmRequest {
  walletName: string;
  address: string;
  action: string;
  stepLabel: string;
  stepHint?: string;
  stepIndex: number;
  stepCount: number;
  summary?: string;
}

export function TestWalletConfirm({ req, onConfirm, onReject }: { req: TestConfirmRequest; onConfirm: () => void; onReject: () => void }) {
  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4 backdrop-blur-md"
      role="dialog"
      aria-modal="true"
      aria-labelledby="test-confirm-title"
      onKeyDown={(e) => e.key === "Escape" && onReject()}
    >
      <div className="relative w-full max-w-md rounded-3xl border border-line bg-surface p-6 shadow-2xl">
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-3">
            <div className="grid h-10 w-10 place-items-center rounded-2xl bg-accent/15 text-accent">
              <FlaskConical className="h-5 w-5" />
            </div>
            <div>
              <h2 id="test-confirm-title" className="text-lg font-bold tracking-tight">
                Confirm transaction
              </h2>
              <p className="text-xs text-muted">
                {req.walletName} · <span className="num">{shortAddr(req.address)}</span> · {NETWORK_LABEL[CHAIN.id] ?? CHAIN.name} (local)
              </p>
            </div>
          </div>
          <button onClick={onReject} className="rounded-full p-1.5 text-muted transition hover:bg-surface-2 hover:text-ink" aria-label="Reject">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="mt-5 space-y-3 rounded-2xl border border-line bg-surface-2/70 p-4">
          <div className="text-xs text-muted">{req.action}</div>
          <div>
            <div className="text-base font-bold">{req.stepLabel}</div>
            {req.stepCount > 1 && (
              <div className="text-xs text-muted">
                Transaction {req.stepIndex + 1} of {req.stepCount}
              </div>
            )}
          </div>
          {req.summary && <div className="num rounded-xl bg-surface px-3 py-2 text-[15px] font-semibold">{req.summary}</div>}
          {req.stepHint && <p className="text-[13px] leading-relaxed text-muted">{req.stepHint}</p>}
        </div>

        <p className="mt-3 text-xs leading-relaxed text-muted">
          Test wallets have no browser extension, so Optara asks you here. With MetaMask or Rabby, this is where your wallet
          would pop up. Test money only.
        </p>

        <div className="mt-5 grid grid-cols-2 gap-2">
          <button className="btn-ghost !py-3" onClick={onReject}>
            Reject
          </button>
          <button className="btn-primary !py-3" onClick={onConfirm} autoFocus>
            Confirm
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
