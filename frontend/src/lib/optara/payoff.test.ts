/** Display math (OPTION_SPEC.md §4, §10 examples): payouts, breakeven, moves, money formatting. */
import { describe, expect, it } from "vitest";
import { breakeven, chartRange, extremes, inTheMoney, niceTicks, overFairValue, legOf, moveNeeded, moveText, niceStep, payoutPerOption, priceLevel, profitAt, usd } from "./payoff.ts";

const E18 = 10n ** 18n;
const call4500 = legOf({ optionType: 0, strikeWad: 4500n * E18, contractSizeWad: E18 });
const put3500 = legOf({ optionType: 1, strikeWad: 3500n * E18, contractSizeWad: E18 });
const monCall = legOf({ optionType: 0, strikeWad: 4n * E18, contractSizeWad: 100n * E18 });

describe("payoff", () => {
  it("matches the OPTION_SPEC examples, including contract size", () => {
    expect(payoutPerOption(call4500, 5200)).toBe(700);
    expect(payoutPerOption(call4500, 4100)).toBe(0);
    expect(payoutPerOption(put3500, 3000)).toBe(500);
    expect(payoutPerOption(monCall, 5)).toBe(100);
  });

  it("profit for buyers and writers is mirror-image", () => {
    expect(profitAt(call4500, "long", 2, 120, 5200)).toBe(1160);
    expect(profitAt(call4500, "short", 2, 120, 5200)).toBe(-1160);
    expect(profitAt(call4500, "long", 1, 120, 4000)).toBe(-120); // loss capped at the cost
    expect(profitAt(call4500, "short", 1, 120, 4000)).toBe(120); // writer keeps the premium
  });

  it("breakeven adds the cost per underlying unit", () => {
    expect(breakeven(call4500, 120)).toBe(4620);
    expect(breakeven(put3500, 150)).toBe(3350);
    expect(breakeven(monCall, 50)).toBe(4.5); // 50 per option over 100 MON
    expect(breakeven(put3500, 4000)).toBeUndefined();
  });

  it("move needed is measured in the option's direction", () => {
    expect(moveNeeded(call4500, 4000, 4500)).toBeCloseTo(0.125);
    expect(moveNeeded(put3500, 4000, 3500)).toBeCloseTo(0.125);
    expect(moveText(call4500, 0.125)).toBe("rise 12.5%");
    expect(moveText(put3500, 0.125)).toBe("fall 12.5%");
    expect(moveText(put3500, -0.01)).toBe("already there");
    expect(moveText(call4500, 0.0002)).toBe("rise under 0.1%");
    expect(moveText(put3500, 0.125, 1, true)).toBe("falls 12.5%");
    expect(inTheMoney(call4500, 4600)).toBe(true);
    expect(inTheMoney(put3500, 3600)).toBe(false);
  });

  it("formats money and levels", () => {
    expect(usd(12.5)).toBe("$12.50");
    expect(usd(-12.5)).toBe("−$12.50");
    expect(usd(1234.4, { sign: true })).toBe("+$1,234");
    expect(priceLevel(4620)).toBe("$4,620");
    expect(priceLevel(4.5)).toBe("$4.50");
    expect(priceLevel(0.0248)).toBe("$0.0248");
    expect(priceLevel(0.024224)).toBe("$0.02422");
    expect(usd(0.0123)).toBe("$0.0123");
    expect(niceStep(4000)).toBe(200);
    expect(niceStep(0.0243)).toBeCloseTo(0.001);
    expect(niceStep(81_688)).toBe(5000);
  });

  it("best and worst case per side", () => {
    expect(extremes(call4500, "long", 2, 120)).toEqual({ maxGain: "unlimited", maxLoss: 240 });
    expect(extremes(put3500, "long", 1, 150)).toEqual({ maxGain: 3350, maxLoss: 150 });
    expect(extremes(call4500, "short", 1, 120)).toEqual({ maxGain: 120, maxLoss: "unlimited" });
    expect(extremes(put3500, "short", 1, 150)).toEqual({ maxGain: 150, maxLoss: 3350 });
  });

  it("chart range and round ticks", () => {
    const [lo, hi] = chartRange([4000, 4500, 4620]);
    expect(lo).toBeLessThan(4000);
    expect(hi).toBeGreaterThan(4620);
    expect(niceTicks(0, 1000, 5)).toEqual([0, 200, 400, 600, 800, 1000]);
    expect(niceTicks(-55, 820, 4)).toEqual([0, 200, 400, 600, 800]);
    expect(niceTicks(0.013, 0.038, 5)[0]).toBeCloseTo(0.015);
  });

  it("price paid against fair value", () => {
    expect(overFairValue(0.002686, 0.002336)).toBeCloseTo(0.1498, 3);
    expect(overFairValue(1, 0)).toBeUndefined();
    expect(overFairValue(1, undefined)).toBeUndefined();
    expect(overFairValue(0.9, 1)).toBeCloseTo(-0.1);
  });
});
