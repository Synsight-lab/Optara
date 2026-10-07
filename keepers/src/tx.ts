import type { Abi, Account, Chain, ContractFunctionArgs, ContractFunctionName, Hex, PublicClient, Transport, WalletClient } from "viem";
import { withGasBuffer } from "@optara/sdk";

export type Log = (msg: string) => void;

export interface Ctx {
  client: PublicClient;
  wallet: WalletClient<Transport, Chain, Account>;
  log: Log;
  /** Gas limit = estimate × (1 + gasBufferBps / 10,000); see `withGasBuffer`. Default 1,000. */
  gasBufferBps?: bigint;
}

/**
 * Simulates, sends and waits. Returns the receipt status and the simulated return value; a simulation revert is
 * returned as `{ ok: false, error }` (keepers race each other, so a revert is an expected outcome, not a crash).
 */
export async function sendTx<const abi extends Abi, fn extends ContractFunctionName<abi, "nonpayable" | "payable">>(
  ctx: Ctx,
  call: { address: Hex; abi: abi; functionName: fn; args: ContractFunctionArgs<abi, "nonpayable" | "payable", fn>; value?: bigint },
): Promise<{ ok: true; hash: Hex; result: unknown } | { ok: false; error: string }> {
  let request: unknown;
  let result: unknown;
  let gas: bigint;
  try {
    ({ request, result } = await ctx.client.simulateContract({ account: ctx.wallet.account, ...(call as any) }));
    gas = withGasBuffer(await ctx.client.estimateContractGas({ account: ctx.wallet.account, ...(call as any) }), ctx.gasBufferBps);
  } catch (e) {
    return { ok: false, error: shortError(e) };
  }
  const hash = await ctx.wallet.writeContract({ ...(request as any), gas });
  const receipt = await ctx.client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") return { ok: false, error: `reverted on chain (${hash})` };
  return { ok: true, hash, result };
}

/** The decoded error name and args when viem has them, else the first line. */
export function shortError(e: unknown): string {
  const err = e as { walk?: (fn: (x: any) => boolean) => any; shortMessage?: string; message?: string };
  const revert = err.walk?.((x: any) => x?.name === "ContractFunctionRevertedError") as { data?: { errorName?: string; args?: unknown[] }; signature?: string } | undefined;
  if (revert?.data?.errorName) return `${revert.data.errorName}(${(revert.data.args ?? []).map(String).join(", ")})`;
  if (revert?.signature) return `custom error ${revert.signature}`;
  return (err.shortMessage ?? err.message ?? String(e)).split("\n")[0]!;
}
