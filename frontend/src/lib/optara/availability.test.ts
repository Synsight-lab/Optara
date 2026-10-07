/** FE-001: action buttons enabled/disabled per STATE_MACHINE.md for every state. */
import { describe, expect, it } from "vitest";
import { availability, type ActionContext, type ActionKey } from "./availability.ts";
import { GROUP_STATES, HEALTH_STATES, type GroupState, type HealthState } from "./types.ts";

const base: ActionContext = {
  connected: true,
  groupState: "ACTIVE",
  productCloseOnly: false,
  dataFresh: true,
  marketTradable: true,
  hasAccount: true,
  health: "HEALTHY",
  accountBalance: 0n,
  walletWrappers: 0n,
  credit: false,
};
const on = (a: ActionKey, c: Partial<ActionContext>) => availability(a, { ...base, ...c }).enabled;

describe("FE-001 actions by group state (STATE_MACHINE.md §1)", () => {
  // what each group state allows, with the holdings that would make the action otherwise possible
  const expected: Record<GroupState, Record<ActionKey, boolean>> = {
    ACTIVE: { buy: true, sell: true, write: true, wrap: true, unwrap: true, close: true, redeem: false, claim: false },
    EXPIRED: { buy: false, sell: false, write: false, wrap: false, unwrap: false, close: true, redeem: false, claim: false },
    ORACLE_STALLED: { buy: false, sell: false, write: false, wrap: false, unwrap: false, close: true, redeem: false, claim: false },
    FINALIZED: { buy: false, sell: false, write: false, wrap: false, unwrap: false, close: false, redeem: false, claim: false },
    ALL_SETTLED: { buy: false, sell: false, write: false, wrap: false, unwrap: false, close: false, redeem: false, claim: false },
    REDEEMABLE: { buy: false, sell: false, write: false, wrap: false, unwrap: false, close: false, redeem: true, claim: true },
  };
  for (const state of GROUP_STATES) {
    it(state, () => {
      for (const [action, want] of Object.entries(expected[state]) as [ActionKey, boolean][]) {
        const holdings: Partial<ActionContext> =
          action === "wrap" ? { accountBalance: 10n } : action === "close" ? { accountBalance: -10n, walletWrappers: 10n } : { walletWrappers: 10n, credit: true };
        const a = availability(action, { ...base, ...holdings, groupState: state });
        expect([action, a.enabled]).toEqual([action, want]);
        if (!a.enabled) expect(a.reason).toBeTruthy();
      }
    });
  }
});

describe("FE-001 actions by account health (STATE_MACHINE.md §2)", () => {
  const riskIncreasing: ActionKey[] = ["write", "wrap"];
  const alwaysAllowed: ActionKey[] = ["unwrap", "close"];
  for (const health of HEALTH_STATES) {
    it(health, () => {
      for (const a of riskIncreasing) expect(on(a, { health: health as HealthState, accountBalance: 10n })).toBe(health === "HEALTHY");
      for (const a of alwaysAllowed) expect(on(a, { health: health as HealthState, accountBalance: -10n, walletWrappers: 10n })).toBe(true);
    });
  }
});

describe("FE-001 other conditions", () => {
  it("everything needs a wallet", () => {
    for (const a of ["buy", "sell", "write", "wrap", "unwrap", "close", "redeem", "claim"] as ActionKey[]) {
      expect(availability(a, { ...base, connected: false })).toEqual({ enabled: false, reason: "Connect a wallet first." });
    }
  });
  it("new risk needs an open product, fresh data and an account; trading needs a market", () => {
    expect(on("write", { productCloseOnly: true })).toBe(false);
    expect(on("write", { dataFresh: false })).toBe(false);
    expect(on("write", { hasAccount: false, health: undefined })).toBe(false);
    expect(on("buy", { marketTradable: false })).toBe(false);
    expect(on("sell", { walletWrappers: 0n })).toBe(false);
    expect(on("buy", { productCloseOnly: true, dataFresh: false })).toBe(true); // buying on Kuru adds no protocol risk
  });
  it("closing needs a short and wrappers; redeeming needs wrappers; claiming needs a credit", () => {
    expect(on("close", { accountBalance: 5n, walletWrappers: 5n })).toBe(false);
    expect(on("close", { accountBalance: -5n, walletWrappers: 0n })).toBe(false);
    expect(on("redeem", { groupState: "REDEEMABLE", walletWrappers: 0n })).toBe(false);
    expect(on("claim", { groupState: "REDEEMABLE", credit: false })).toBe(false);
  });
});
