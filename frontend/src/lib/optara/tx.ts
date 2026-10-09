/**
 * Sending transactions: simulate first (a revert becomes a readable message before the wallet opens), then send
 * with the gas limit above the estimate (DD-36) and wait for the receipt.
 */
import { encodeDeployData, type Abi, type Account, type ContractFunctionArgs, type ContractFunctionName, type Hex, type TransactionReceipt, type WalletClient } from "viem";
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

export interface DeployCall<abi extends Abi = Abi> {
  abi: abi;
  bytecode: Hex;
  args: readonly unknown[];
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

export async function deploy(wallet: Wallet, call: DeployCall, onSent?: (hash: Hex) => void): Promise<TransactionReceipt> {
  try {
    const data = encodeDeployData(call as any);
    const gas = withGasBuffer(await publicClient.estimateGas({ account: wallet.account, data }));
    const hash = await wallet.deployContract({ ...(call as any), account: wallet.account, chain: CHAIN, gas });
    onSent?.(hash);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success" || !receipt.contractAddress) throw new TxError("The deployment failed on chain. Nothing changed; try again.");
    return receipt;
  } catch (e) {
    if (e instanceof TxError) throw e;
    const f = friendlyError(e);
    // A constructor that reverts without a reason usually means bad code or a zero address in its arguments.
    const msg = !f.rejected && !f.name ? "The contract couldn't be created: the chain rejected its code or settings. Nothing changed." : f.message;
    throw new TxError(msg, f.name, f.rejected);
  }
}
