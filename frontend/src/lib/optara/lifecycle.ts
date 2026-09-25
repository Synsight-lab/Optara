/**
 * Lifecycle presentation rules (STATE_MACHINE.md sections 18-26 and 101, KURU_INTEGRATION.md sections 52-54, 60).
 * Pure functions so every rule is unit-tested.
 */

export type ChainSeriesStatus = 0 | 1 | 2 | 3; // NONE, ACTIVE, EXPIRED_UNSETTLED, SETTLED (SeriesStatus enum)

export type Lifecycle =
  | { kind: "ACTIVE" }
  | { kind: "AWAITING_PRICE" } // expired, before the escalation deadline
  | { kind: "ORACLE_STALLED" } // expired, escalation deadline passed, still unfinalized
  | { kind: "SETTLED"; payoffPerUnderlyingWad: bigint }
  | { kind: "UNKNOWN" };

export function lifecycleOf(status: ChainSeriesStatus, oracleStalled: boolean, payoffPerUnderlyingWad?: bigint): Lifecycle {
  if (status === 1) return { kind: "ACTIVE" };
  if (status === 2) return oracleStalled ? { kind: "ORACLE_STALLED" } : { kind: "AWAITING_PRICE" };
  if (status === 3) return { kind: "SETTLED", payoffPerUnderlyingWad: payoffPerUnderlyingWad ?? 0n };
  return { kind: "UNKNOWN" };
}

/** KUR-014: the expiry view never conflates waiting, stalled and finalized. */
export function lifecycleLabel(l: Lifecycle): string {
  switch (l.kind) {
    case "ACTIVE":
      return "Active";
    case "AWAITING_PRICE":
      return "Expired — awaiting final oracle price";
    case "ORACLE_STALLED":
      return "ORACLE_STALLED — escalation deadline passed without a valid price";
    case "SETTLED":
      return "Settled — redeemable";
    default:
      return "Unknown series";
  }
}

export type CloseAction = "closeShort" | "cancelUnfinalizedShort" | "redeemAndSync";

/**
 * KUR-015 / KURU_INTEGRATION.md section 60: once the writer holds identical longs, the correct Optara call depends
 * on the series state at execution time. A venue fill alone never closes anything.
 */
export function closeActionFor(l: Lifecycle): CloseAction | undefined {
  if (l.kind === "ACTIVE") return "closeShort";
  if (l.kind === "AWAITING_PRICE" || l.kind === "ORACLE_STALLED") return "cancelUnfinalizedShort";
  if (l.kind === "SETTLED") return "redeemAndSync";
  return undefined;
}

/** KUR-013 / PROTOCOL_SPEC.md section 41: shown and acknowledged before any acquisition path is offered. */
export const LIVENESS_DISCLOSURE =
  "Expiry is not a guaranteed payout date. Settlement needs a valid observation from this series' precommitted " +
  "oracle rule. If every approved source permanently fails, an unmatched long can remain unresolved indefinitely: " +
  "no price is ever invented and no one can force a payout. Writers keep full reserves for the group while it is " +
  "unresolved, and matching longs can still be cancelled against shorts.";

/** ORACLE_AND_SETTLEMENT.md section 19: the same limitation, disclosed to a writer before entering risk. */
export const WRITER_LIVENESS_DISCLOSURE =
  "Expiry does not release your margin. Your group's full worst-case requirement stays reserved until this " +
  "series' precommitted oracle rule produces a valid price. If every approved source permanently fails, that " +
  "reserve can stay locked indefinitely: no price is ever invented. You can still cancel shorts against identical " +
  "longs, unlock hedges your account no longer needs and withdraw proven free collateral.";

/** KURU_INTEGRATION.md sections 51 and 53. */
export const VENUE_BOUNDARY_NOTES = [
  "Premium received on a trading venue is not Optara margin until you deposit it here.",
  "Buying the long on a venue does not close your short: return it here to close.",
  "Venue balances never count as Optara collateral or locked hedges.",
];
