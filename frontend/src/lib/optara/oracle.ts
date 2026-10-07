/** FRONTEND.md §4: fresh oracle data for risk-increasing transactions (publisher `/oracle-update`). */
import type { Hex } from "viem";
import { emptyOracleUpdate, liveSpotOracleAbi, oracleUpdateFromJson, type OracleUpdate } from "@optara/sdk";
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
