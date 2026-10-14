import { describe, expect, it } from "vitest";
import { parseQty, qtyStepError, roundDownQty } from "../lib/optara/format.ts";

describe("option quantities", () => {
  it("reads a decimal comma as a decimal point, never as thousands", () => {
    expect(parseQty("0,03")).toBe(3n * 10n ** 16n);
    expect(parseQty("1,5")).toBe(15n * 10n ** 17n);
    expect(parseQty("0.03")).toBe(3n * 10n ** 16n);
    expect(parseQty("1,000")).toBe(1000n * 10n ** 18n);
  });

  it("accepts quantities on the 0.01-option step and explains the others", () => {
    expect(qtyStepError(parseQty("0.03"))).toBeUndefined();
    expect(qtyStepError(parseQty("2"))).toBeUndefined();
    expect(qtyStepError(parseQty("0.025"))).toMatch(/steps of 0\.01/);
    expect(qtyStepError(parseQty("0.033"))).toMatch(/steps of 0\.01/);
    expect(qtyStepError(undefined)).toBeUndefined();
  });

  it("rounds a max down to the step", () => {
    expect(roundDownQty(28_700_000_000_000_000n)).toBe(20_000_000_000_000_000n); // 0.0287 -> 0.02
    expect(roundDownQty(5n * 10n ** 18n)).toBe(5n * 10n ** 18n);
  });
});
