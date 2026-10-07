/**
 * Sending transactions: simulate first (a revert becomes a readable message before the wallet opens), then send
 * with the gas limit above the estimate (DD-36) and wait for the receipt.
 */
import type { Abi, Account, ContractFunctionArgs, ContractFunctionName, Hex, TransactionReceipt, WalletClient } from "viem";
import { withGasBuffer } from "@optara/sdk";
import { CHAIN } from "../../config/network.ts";
import { publicClient } from "./client.ts";
import { friendlyError } from "./errors.ts";

export type Wallet = WalletClient & { account: Account };

export interface ContractCall<abi extends Abi = Abi, fn extends ContractFunctionName<abi, "nonpayable" | "payable"> = any> {
  address: Hex;
  abi: abi;
  functionName: fn;
  args: ContractFunctionArgs<abi, "nonpayable" | "payable", fn>;
  value?: bigint;
}

export class TxError extends Error {
  constructor(
    message: string,
    readonly errorName?: string,
    readonly rejected = false,
  ) {
    super(message);
  }
}

/** Simulates `call` from the wallet's account; throws a TxError with a readable message if it would revert. */
export async function simulate(wallet: Wallet, call: ContractCall): Promise<unknown> {
  try {
    const { result } = await publicClient.simulateContract({ account: wallet.account, ...(call as any) });
    return result;
  } catch (e) {
    const f = friendlyError(e);
    throw new TxError(f.message, f.name, f.rejected);
  }
}

export async function send(wallet: Wallet, call: ContractCall, onSent?: (hash: Hex) => void): Promise<TransactionReceipt> {
  await simulate(wallet, call);
  try {
    const gas = withGasBuffer(await publicClient.estimateContractGas({ account: wallet.account, ...(call as any) }));
    const hash = await wallet.writeContract({ ...(call as any), account: wallet.account, chain: CHAIN, gas });
    onSent?.(hash);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new TxError("The transaction failed on chain. Nothing changed; try again.");
    return receipt;
  } catch (e) {
    if (e instanceof TxError) throw e;
    const f = friendlyError(e);
    throw new TxError(f.message, f.name, f.rejected);
  }
}
