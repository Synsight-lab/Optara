/** FRONTEND.md §7: signed limits from the slippage setting. */
import { describe, expect, it } from "vitest";
import { clampSlippage, lessSlip, withSlip } from "./limits.ts";

describe("limits", () => {
  it("upper limits round up, lower limits round down", () => {
    expect(withSlip(1_000_000n, 100)).toBe(1_010_001n); // fee 1.00 → max 1.010001 at 1%
    expect(lessSlip(1_000_000n, 100)).toBe(990_000n); // qty → at least 99%
    expect(lessSlip(38_346n * 10n ** 18n, 50)).toBe(38_154_270n * 10n ** 15n); // 0.5%
  });

  it("slippage stays within 0.1%–10%", () => {
    expect(clampSlippage(0)).toBe(10);
    expect(clampSlippage(250)).toBe(250);
    expect(clampSlippage(5000)).toBe(1000);
  });
});
