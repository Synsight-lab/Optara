/** FRONTEND.md §4: fresh oracle data for risk-increasing transactions (publisher `/oracle-update`). */
import { decodeFunctionResult, encodeFunctionData, parseAbi, type Abi, type Address, type Hex } from "viem";
import { emptyOracleUpdate, liveSpotOracleAbi, optionClearingAbi, oracleUpdateFromJson, type OracleUpdate } from "@optara/sdk";
import { PUBLISHER_URL } from "../../config/network.ts";
import { ADDR, publicClient } from "./client.ts";

export class NoPublisherError extends Error {
  constructor() {
    super("No surface publisher is configured (VITE_PUBLISHER_URL), so prices can't be refreshed.");
  }
}

/** Spot for every product the account holds plus the traded series', the newest signed surface, missing leaves. */
export async function fetchOracleUpdate(accountId: bigint | undefined, series: readonly Hex[] = [], fetchImpl: typeof fetch = fetch): Promise<OracleUpdate> {
  if (!PUBLISHER_URL) throw new NoPublisherError();
  const q = new URLSearchParams();
  if (accountId !== undefined) q.set("account", accountId.toString());
  if (series.length) q.set("series", series.join(","));
  const res = await fetchImpl(`${PUBLISHER_URL}/oracle-update?${q}`);
  if (!res.ok) throw new Error(`The price service answered ${res.status}. Try again in a moment.`);
  return oracleUpdateFromJson(await res.json());
}

/** The provider fee to attach (`value`) for an update's spot blobs. */
export const oracleFee = (u: OracleUpdate) =>
  u.spotUpdates.length === 0
    ? Promise.resolve(0n)
    : publicClient.readContract({ address: ADDR.spot, abi: liveSpotOracleAbi, functionName: "updateFee", args: [u.spotUpdates] });

export { emptyOracleUpdate };

/** Multicall3: the same address on every chain, Monad included. */
const MULTICALL3: Address = "0xcA11bde05977b3631167028862bE2a173976CA11";
const multicall3Abi = parseAbi([
  "struct Call3Value { address target; bool allowFailure; uint256 value; bytes callData; }",
  "struct Result { bool success; bytes returnData; }",
  "function aggregate3Value(Call3Value[] calls) payable returns (Result[] returnData)",
]);
/** Simulated sender, given a balance by state override so it can attach the provider fee. */
const SIM_SENDER: Address = "0x000000000000000000000000000000000000dEaD";

export interface ContractRead {
  address: Address;
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
}

/**
 * Runs `reads` as they would return right after `updateOracles(u)`, in one `eth_call` through Multicall3. Nothing is
 * sent and no gas is spent. Each result is undefined when that read reverted; throws when the update itself fails.
 */
export async function readAfterUpdate(u: OracleUpdate, reads: readonly ContractRead[]): Promise<unknown[]> {
  const fee = await oracleFee(u);
  const calls = [
    { target: ADDR.clearing, allowFailure: false, value: fee, callData: encodeFunctionData({ abi: optionClearingAbi, functionName: "updateOracles", args: [u] }) },
    ...reads.map((r) => ({ target: r.address, allowFailure: true, value: 0n, callData: encodeFunctionData(r as Parameters<typeof encodeFunctionData>[0]) })),
  ];
  const { result } = await publicClient.simulateContract({
    address: MULTICALL3,
    abi: multicall3Abi,
    functionName: "aggregate3Value",
    args: [calls],
    value: fee,
    account: SIM_SENDER,
    stateOverride: [{ address: SIM_SENDER, balance: fee + 10n ** 18n }],
  });
  return result.slice(1).map((r, i) =>
    r.success ? decodeFunctionResult({ abi: reads[i]!.abi, functionName: reads[i]!.functionName, data: r.returnData } as Parameters<typeof decodeFunctionResult>[0]) : undefined,
  );
}
