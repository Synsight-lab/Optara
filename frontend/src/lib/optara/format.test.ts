import { describe, expect, it } from "vitest";
import { formatUnitsTrim, formatWad, parseUnitsStrict, formatExpiry, shortHex } from "./format.ts";

describe("fixed-point formatting", () => {
  it("formats native and WAD units without trailing zeros", () => {
    expect(formatUnitsTrim(1_500_000n, 6)).toBe("1.5");
    expect(formatUnitsTrim(5_000_000n, 6)).toBe("5");
    expect(formatUnitsTrim(-2_000_001n, 6)).toBe("-2.000001");
    expect(formatWad(12_500_000_000_000_000_000n)).toBe("12.5");
    expect(formatWad(1n, 6)).toBe("0");
  });
  it("parses exactly and rejects excess precision or junk", () => {
    expect(parseUnitsStrict("1.5", 6)).toBe(1_500_000n);
    expect(parseUnitsStrict("0.000001", 6)).toBe(1n);
    expect(parseUnitsStrict("3", 18)).toBe(3n * 10n ** 18n);
    expect(() => parseUnitsStrict("0.0000001", 6)).toThrow(/decimal places/);
    expect(() => parseUnitsStrict("-1", 6)).toThrow();
    expect(() => parseUnitsStrict("1e6", 6)).toThrow();
  });
  it("formats dates and hex", () => {
    expect(formatExpiry(1_798_761_600n)).toBe("2027-01-01 00:00 UTC");
    expect(shortHex("0x1234567890abcdef1234567890abcdef12345678", 4)).toBe("0x1234…5678");
  });
});
