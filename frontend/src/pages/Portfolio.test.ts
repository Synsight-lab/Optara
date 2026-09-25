import { describe, expect, it } from "vitest";
import { depositLimit, scaleByRho } from "./Portfolio.tsx";
import type { RiskStateView } from "../lib/optara/types.ts";

const base: RiskStateView = {
  asset: "0x0000000000000000000000000000000000000001", assetSymbol: "USDT", assetDecimals: 6, cash: 0n, effectiveCash: 0n,
  requiredMargin: 0n, freeCollateral: 0n, deficit: 0n, hasUnsyncedMaturedGroups: false, assetStatus: 0, rhoWad: 0n,
};

describe("deposit rules mirror the core (PROTOCOL_SPEC.md section 10)", () => {
  it("normal asset: deposits allowed", () => expect(depositLimit(base)).toEqual({ allowed: true }));
  it("restricted asset: cure deposit only, capped at the deficit", () => {
    expect(depositLimit({ ...base, assetStatus: 1 }).allowed).toBe(false);
    expect(depositLimit({ ...base, assetStatus: 1, deficit: 7n })).toMatchObject({ allowed: true, max: 7n });
  });
  it("wind-down: deposits permanently disabled", () => expect(depositLimit({ ...base, assetStatus: 2 }).allowed).toBe(false));
});

describe("wind-down outflow preview matches FixedPointMath.scaleByRho (floor(rho * amount))", () => {
  it("rounds down and never pays more than the ledger amount", () => {
    expect(scaleByRho(1_000_000n, 9n * 10n ** 17n)).toBe(900_000n);
    expect(scaleByRho(3n, 5n * 10n ** 17n)).toBe(1n); // 1.5 -> 1
    expect(scaleByRho(7n, 10n ** 18n - 1n)).toBe(6n); // rho < 1 always pays strictly less on small amounts
  });
});
