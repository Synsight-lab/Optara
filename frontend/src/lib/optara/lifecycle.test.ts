import { describe, expect, it } from "vitest";
import { closeActionFor, lifecycleLabel, lifecycleOf } from "./lifecycle.ts";

describe("KUR-014: expiry view distinguishes awaiting-price, ORACLE_STALLED and finalized", () => {
  it("maps on-chain status and the stalled flag to distinct states", () => {
    expect(lifecycleOf(1, false).kind).toBe("ACTIVE");
    expect(lifecycleOf(2, false).kind).toBe("AWAITING_PRICE");
    expect(lifecycleOf(2, true).kind).toBe("ORACLE_STALLED");
    expect(lifecycleOf(3, false, 5n)).toEqual({ kind: "SETTLED", payoffPerUnderlyingWad: 5n });
    expect(lifecycleOf(0, false).kind).toBe("UNKNOWN");
  });
  it("labels are all different and never claim a payout before finalization", () => {
    const labels = [lifecycleOf(1, false), lifecycleOf(2, false), lifecycleOf(2, true), lifecycleOf(3, false, 0n)].map(lifecycleLabel);
    expect(new Set(labels).size).toBe(4);
    expect(labels[1]).toMatch(/awaiting final oracle price/);
    expect(labels[2]).toMatch(/ORACLE_STALLED/);
    expect(labels[1]).not.toMatch(/redeem/i);
  });
});

describe("KUR-015: buy-to-close that crosses expiry never reports a close from a fill", () => {
  it("chooses the Optara call from the execution-time state", () => {
    expect(closeActionFor(lifecycleOf(1, false))).toBe("closeShort");
    expect(closeActionFor(lifecycleOf(2, false))).toBe("cancelUnfinalizedShort");
    expect(closeActionFor(lifecycleOf(2, true))).toBe("cancelUnfinalizedShort");
    expect(closeActionFor(lifecycleOf(3, false, 1n))).toBe("redeemAndSync");
    expect(closeActionFor(lifecycleOf(0, false))).toBeUndefined();
  });
});
