/**
 * FE-001: which Series-page actions are enabled, with the reason when not (FRONTEND.md §4, STATE_MACHINE.md §1–§2).
 * Pure: the page passes what it read; the tests walk every state.
 */
import type { GroupState, HealthState } from "./types.ts";

export type ActionKey = "buy" | "sell" | "write" | "wrap" | "unwrap" | "close" | "redeem" | "claim";

export interface ActionContext {
  connected: boolean;
  groupState: GroupState;
  productCloseOnly: boolean;
  /** Spot and surface fresh (new risk needs both). */
  dataFresh: boolean;
  /** A Kuru market is registered and tradable for this series. */
  marketTradable: boolean;
  hasAccount: boolean;
  /** undefined without an account */
  health?: HealthState;
  /** The account's signed balance in this series (18 decimals). */
  accountBalance: bigint;
  walletWrappers: bigint;
  /** Settlement credit to claim (numerator > 0). */
  credit: boolean;
}

export interface Availability {
  enabled: boolean;
  reason?: string;
}

const NEW_RISK_STATES: HealthState[] = ["HEALTHY"];

export function availability(action: ActionKey, c: ActionContext): Availability {
  const no = (reason: string): Availability => ({ enabled: false, reason });
  if (!c.connected) return no("Connect a wallet first.");
  const active = c.groupState === "ACTIVE";
  switch (action) {
    case "buy":
      if (!active) return no("This option has expired.");
      if (!c.marketTradable) return no("No order book for this option yet.");
      return { enabled: true };
    case "sell":
      if (!active) return no("This option has expired.");
      if (!c.marketTradable) return no("No order book for this option yet.");
      if (c.walletWrappers === 0n) return no("You don't hold any of these option tokens.");
      return { enabled: true };
    case "write":
      if (!active) return no("This option has expired.");
      if (c.productCloseOnly) return no("This market is closing-only right now.");
      if (!c.dataFresh) return no("Price data is delayed. New positions are paused.");
      if (!c.hasAccount) return no("Create an account and deposit collateral first.");
      if (!c.health || !NEW_RISK_STATES.includes(c.health)) return no("Your account is below its margin requirement. Deposit or reduce positions.");
      return { enabled: true };
    case "wrap":
      if (!active) return no("This option has expired.");
      if (c.accountBalance <= 0n) return no("You have no long position in your account for this option.");
      if (c.productCloseOnly) return no("This market is closing-only right now.");
      if (!c.dataFresh) return no("Price data is delayed. Try again shortly.");
      if (!c.health || !NEW_RISK_STATES.includes(c.health)) return no("Your account needs more margin first.");
      return { enabled: true };
    case "unwrap":
      if (!active) return no("This option has expired.");
      if (!c.hasAccount) return no("Create an account first.");
      if (c.walletWrappers === 0n) return no("You don't hold any of these option tokens.");
      return { enabled: true };
    case "close":
      if (!["ACTIVE", "EXPIRED", "ORACLE_STALLED"].includes(c.groupState)) return no("This expiry is already being settled.");
      if (c.accountBalance >= 0n) return no("You have no short position in this option.");
      if (c.walletWrappers === 0n) return no("You need matching option tokens in your wallet to burn against this short.");
      return { enabled: true };
    case "redeem":
      if (c.groupState !== "REDEEMABLE") return no(c.groupState === "ACTIVE" ? "Payouts open after expiry and settlement." : "Payouts open once every account is settled.");
      if (c.walletWrappers === 0n) return no("You don't hold any of these option tokens.");
      return { enabled: true };
    case "claim":
      if (c.groupState !== "REDEEMABLE") return no("Payouts aren't open yet.");
      if (!c.credit) return no("Nothing to claim for this account.");
      return { enabled: true };
  }
}
