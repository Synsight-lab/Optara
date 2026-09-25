import { useState } from "react";
import { useAccount, useConfig } from "wagmi";
import { writeContract, waitForTransactionReceipt } from "wagmi/actions";
import { BaseError, ContractFunctionRevertedError, type Abi } from "viem";
import { useQueryClient } from "@tanstack/react-query";

export interface TxStep {
  label: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  request: { address: `0x${string}`; abi: Abi | readonly unknown[]; functionName: string; args: readonly any[] };
}

/** Human-readable reason for a failed call: the custom error name from the ABI when available. */
export function explainError(e: unknown): string {
  if (e instanceof BaseError) {
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    if (revert?.data?.errorName) {
      const args = revert.data.args?.map((a) => (typeof a === "bigint" ? a.toString() : String(a))).join(", ");
      return `${revert.data.errorName}${args ? `(${args})` : ""}`;
    }
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}

/** Runs one or more transactions in order (e.g. exact approve, then deposit), refreshing reads afterwards. */
export function TxButton({ steps, disabled, onDone }: { steps: TxStep[]; disabled?: boolean; onDone?: () => void }) {
  const config = useConfig();
  const { isConnected } = useAccount();
  const queryClient = useQueryClient();
  const [state, setState] = useState<{ busy: boolean; step?: string; error?: string; ok?: boolean }>({ busy: false });

  async function run() {
    setState({ busy: true });
    try {
      for (const s of steps) {
        setState({ busy: true, step: s.label });
        const hash = await writeContract(config, s.request as never);
        const receipt = await waitForTransactionReceipt(config, { hash });
        if (receipt.status !== "success") throw new Error(`${s.label} reverted`);
      }
      setState({ busy: false, ok: true });
      await queryClient.invalidateQueries();
      onDone?.();
    } catch (e) {
      setState({ busy: false, error: explainError(e) });
    }
  }

  const last = steps[steps.length - 1];
  return (
    <div className="flex flex-col gap-1">
      <button
        className="rounded bg-indigo-600 px-3 py-1.5 text-sm font-medium hover:bg-indigo-500 disabled:opacity-40"
        disabled={disabled || !isConnected || state.busy || steps.length === 0}
        onClick={run}
      >
        {state.busy ? `${state.step ?? "Sending"}…` : steps.length > 1 ? `${steps.map((s) => s.label).join(" + ")}` : last?.label}
      </button>
      {state.error && <span className="text-xs text-red-400">Rejected: {state.error}</span>}
      {state.ok && <span className="text-xs text-emerald-400">Confirmed on chain.</span>}
    </div>
  );
}
