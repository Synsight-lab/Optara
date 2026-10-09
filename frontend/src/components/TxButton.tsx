/**
 * Runs an action's steps with a visible stepper: approvals are skipped when not needed, each step shows
 * "confirm in your wallet" then "confirming"; failures become plain messages (FE-004). Disclosures are acknowledged
 * first (FE-003).
 */
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useChainId, useConfig, useConnection, useSwitchChain } from "wagmi";
import { getWalletClient } from "wagmi/actions";
import type { TransactionReceipt } from "viem";
import { CHAIN, EXPLORER_URL, IS_LOCAL_FORK, NETWORK_LABEL } from "../config/network.ts";
import type { Step } from "../lib/optara/actions.ts";
import { pendingDisclosures, type DisclosureId } from "../lib/optara/disclosures.ts";
import { TxError, type Wallet } from "../lib/optara/tx.ts";
import { useToasts } from "../state.tsx";
import { DisclosureModal } from "./DisclosureModal.tsx";
import { TestWalletConfirm, type TestConfirmRequest } from "./TestWalletConfirm.tsx";
import { Spinner, cx } from "./ui.tsx";

type Phase = "idle" | "wallet" | "mining" | "done" | "failed";

export interface TxButtonProps {
  label: string;
  steps: Step[] | undefined;
  disabled?: boolean;
  disabledReason?: string;
  disclosures?: DisclosureId[];
  tone?: "primary" | "accent";
  onDone?: (receipts: TransactionReceipt[]) => void;
  successMessage?: string;
  /** What the action moves, in words, e.g. "1,000 USDC from your wallet into account #9". Shown when confirming. */
  summary?: string;
}

export function TxButton({ label, steps, disabled, disabledReason, disclosures = [], tone = "primary", onDone, successMessage, summary }: TxButtonProps) {
  const { isConnected, connector, address } = useConnection();
  // Test wallets sign without any popup (anvil holds their keys), so each transaction is confirmed in-app instead.
  const isTestWallet = connector?.type === "test";
  // A browser wallet on a local fork of a real chain shares that chain's id, so it would send to the REAL network.
  const browserOnFork = IS_LOCAL_FORK && !!connector && !isTestWallet;
  const [confirm, setConfirm] = useState<(TestConfirmRequest & { resolve: (ok: boolean) => void }) | undefined>();
  const askConfirm = (r: TestConfirmRequest) => new Promise<boolean>((resolve) => setConfirm({ ...r, resolve }));
  const chainId = useChainId();
  const { switchChain, isPending: switching } = useSwitchChain();
  const config = useConfig();
  const qc = useQueryClient();
  const { push } = useToasts();
  const [status, setStatus] = useState<Record<string, Phase>>({});
  const [running, setRunning] = useState(false);
  const [askDisclosures, setAskDisclosures] = useState<DisclosureId[]>([]);

  const wrongChain = isConnected && chainId !== CHAIN.id;

  async function run() {
    if (!steps) return;
    const pending = pendingDisclosures(disclosures);
    if (pending.length) return setAskDisclosures(pending);
    setRunning(true);
    let wallet: Wallet;
    try {
      wallet = (await getWalletClient(config, { chainId: CHAIN.id })) as Wallet;
    } catch (e) {
      setRunning(false);
      push({ tone: "bad", title: "Wallet not available", body: (e as Error).message.split("\n")[0] });
      return;
    }
    setStatus({});
    const receipts: TransactionReceipt[] = [];
    for (const [i, step] of steps.entries()) {
      try {
        if (step.done && (await step.done(wallet))) {
          setStatus((s) => ({ ...s, [step.key]: "done" }));
          continue;
        }
        setStatus((s) => ({ ...s, [step.key]: "wallet" }));
        if (isTestWallet) {
          const ok = await askConfirm({
            walletName: connector?.name ?? "Test wallet",
            address: address ?? wallet.account.address,
            action: label,
            stepLabel: step.label,
            stepHint: step.hint,
            stepIndex: i,
            stepCount: steps.length,
            summary,
          });
          setConfirm(undefined);
          if (!ok) throw new TxError("You rejected the transaction.", undefined, true);
        }
        const receipt = await step.run(wallet, () => setStatus((s) => ({ ...s, [step.key]: "mining" })));
        receipts.push(receipt);
        setStatus((s) => ({ ...s, [step.key]: "done" }));
      } catch (e) {
        setStatus((s) => ({ ...s, [step.key]: "failed" }));
        const rejected = e instanceof TxError && e.rejected;
        push({ tone: rejected ? "info" : "bad", title: rejected ? "Cancelled" : `${step.label} didn't go through`, body: (e as Error).message });
        setRunning(false);
        return;
      }
    }
    setRunning(false);
    const last = receipts[receipts.length - 1];
    push({ tone: "good", title: successMessage ?? "Done", hash: last?.transactionHash });
    await qc.invalidateQueries();
    onDone?.(receipts);
  }

  if (!isConnected) return <button className="btn-ghost w-full !py-3 text-[15px]" disabled>Connect wallet to continue</button>;
  if (browserOnFork) {
    return (
      <div className="space-y-1.5">
        <button className="btn-ghost w-full !py-3 text-[15px]" disabled>
          Use a test wallet on this fork
        </button>
        <p className="text-center text-[13px] leading-snug text-warn">
          This local fork uses {NETWORK_LABEL[CHAIN.id] ?? CHAIN.name}'s network id, so a browser wallet would send this to the real
          network. Disconnect and pick a test wallet (Alice…Erin).
        </p>
      </div>
    );
  }
  if (wrongChain) {
    return (
      <button className="btn-primary w-full !py-3 text-[15px]" onClick={() => switchChain({ chainId: CHAIN.id })} disabled={switching}>
        {switching && <Spinner />} Switch to {NETWORK_LABEL[CHAIN.id] ?? CHAIN.name}
      </button>
    );
  }

  const showSteps = steps && steps.length > 1 && Object.keys(status).length > 0;
  return (
    <div className="space-y-2.5">
      <button
        className={cx(tone === "accent" ? "btn-accent" : "btn-primary", "w-full !py-3.5 text-[15px]")}
        disabled={disabled || running || !steps}
        onClick={run}
        title={disabled ? disabledReason : undefined}
      >
        {running && <Spinner />}
        {running ? (isTestWallet ? "Confirm in the window…" : "Confirm in wallet…") : label}
      </button>
      {disabled && disabledReason && <p className="text-center text-[13px] leading-snug text-muted">{disabledReason}</p>}
      {showSteps && (
        <ol className="space-y-1.5 rounded-xl border border-line bg-surface-2/70 p-3 text-sm">
          {steps!.map((s, i) => {
            const p = status[s.key] ?? "idle";
            return (
              <li key={s.key} className="flex items-center gap-2.5">
                <span className={cx("grid h-5 w-5 shrink-0 place-items-center rounded-full text-[11px] font-bold", p === "done" ? "bg-good text-[#04281c]" : p === "failed" ? "bg-bad text-white" : p === "idle" ? "bg-line text-muted" : "bg-primary text-white")}>
                  {p === "done" ? "✓" : p === "failed" ? "!" : p === "wallet" || p === "mining" ? <Spinner className="h-3 w-3" /> : i + 1}
                </span>
                <span className={cx("text-[13px]", p === "idle" && "text-muted")}>{s.label}</span>
                <span className="ml-auto text-xs text-muted">{p === "wallet" ? "Confirm in wallet" : p === "mining" ? "Confirming…" : ""}</span>
              </li>
            );
          })}
        </ol>
      )}
      {confirm && (
        <TestWalletConfirm req={confirm} onConfirm={() => confirm.resolve(true)} onReject={() => confirm.resolve(false)} />
      )}
      {askDisclosures.length > 0 && (
        <DisclosureModal
          ids={askDisclosures}
          onCancel={() => setAskDisclosures([])}
          onAccept={() => {
            setAskDisclosures([]);
            void run();
          }}
        />
      )}
    </div>
  );
}

export const explorerTx = (hash: string) => (EXPLORER_URL ? `${EXPLORER_URL}/tx/${hash}` : undefined);
