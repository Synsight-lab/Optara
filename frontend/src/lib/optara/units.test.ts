/** FRONTEND.md §11 "Units": formatting, parsing, health classification. */
import { describe, expect, it } from "vitest";
import { fmtDuration, fmtFixed, fmtIv, fmtPrice, fmtQty, fmtWad, parseFixed, parseQty, seriesName } from "./format.ts";
import { classifyHealth, healthBar } from "./health.ts";
import type { Health } from "./types.ts";

const E18 = 10n ** 18n;

describe("format", () => {
  it("fixed point with grouping and half-up rounding", () => {
    expect(fmtFixed(1_234_567_891n, 6, 2)).toBe("1,234.57");
    expect(fmtFixed(-1_005_000n, 6, 2)).toBe("−1.01");
    expect(fmtFixed(-4n, 6, 2)).toBe("0.00"); // no negative zero
    expect(fmtWad(4000n * E18, 0)).toBe("4,000");
    expect(fmtFixed(5n, 0, 2)).toBe("5");
  });
  it("IV as a percentage, quantities trimmed, tiny prices marked", () => {
    expect(fmtIv(6n * 10n ** 17n)).toBe("60.0%");
    expect(fmtQty(15n * 10n ** 17n)).toBe("1.5");
    expect(fmtQty(2n * E18)).toBe("2");
    expect(fmtPrice(10n ** 15n)).toBe("<0.01");
    expect(fmtPrice(0n)).toBe("0.00");
    expect(fmtPrice(69_54n * 10n ** 16n)).toBe("69.54");
  });
  it("parses decimals exactly and refuses junk or excess precision", () => {
    expect(parseFixed("1.25", 6)).toBe(1_250_000n);
    expect(parseFixed("1,000", 6)).toBe(1_000_000_000n);
    expect(parseFixed(".5", 18)).toBe(5n * 10n ** 17n);
    expect(parseFixed("1.1234567", 6)).toBeUndefined();
    expect(parseFixed("abc", 6)).toBeUndefined();
    expect(parseFixed("", 6)).toBeUndefined();
    expect(parseQty("0.01")).toBe(10n ** 16n);
  });
  it("durations and names", () => {
    expect(fmtDuration(0)).toBe("now");
    expect(fmtDuration(45)).toBe("45s");
    expect(fmtDuration(3 * 86_400 + 4 * 3600)).toBe("3d 4h");
    expect(fmtDuration(2 * 3600 + 5 * 60)).toBe("2h 05m");
    expect(seriesName({ underlyingSymbol: "ETH", strikeWad: 4500n * E18, optionType: 0, expiry: 1791532800n })).toBe("ETH 4,500 Call · 9 Oct");
  });
});

const h = (state: Health["state"], equity: bigint, im: bigint, mm: bigint, fresh = true): Health => ({ state, equity, initialMargin: im, maintenanceMargin: mm, fresh });

describe("health (FRONTEND.md §5)", () => {
  it("classifies every state with its tone and message", () => {
    expect(classifyHealth(undefined, false)).toMatchObject({ tone: "neutral", label: "No account" });
    expect(classifyHealth(h("HEALTHY", 5n, 0n, 0n), false)).toMatchObject({ label: "No risk" });
    expect(classifyHealth(h("HEALTHY", 5n, 3n, 1n), true)).toMatchObject({ tone: "good", message: "You can open new positions." });
    expect(classifyHealth(h("CLOSE_ONLY", 2n, 3n, 1n), true)).toMatchObject({ tone: "warn", message: "New risk blocked. Deposit or reduce positions." });
    expect(classifyHealth(h("LIQUIDATABLE", 0n, 3n, 1n), true)).toMatchObject({ tone: "bad", message: "Your positions can be liquidated now." });
    expect(classifyHealth(h("INSOLVENT", -1n, 3n, 1n), true).tone).toBe("bad");
    expect(classifyHealth(h("HEALTHY", 5n, 3n, 1n, false), true).stale).toBe(true);
  });
  it("places equity, IM and MM on one bar", () => {
    const b = healthBar(h("HEALTHY", 3890n, 3418n, 1447n));
    expect(b.imPct).toBeGreaterThan(b.mmPct);
    expect(b.equityPct).toBeGreaterThan(b.imPct);
    expect(healthBar(h("LIQUIDATABLE", -5n, 10n, 5n)).equityPct).toBe(0);
  });
});
