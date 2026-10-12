import { describe, expect, it } from "vitest";
import { ratio } from "../src/feedPusher.ts";

describe("testnet feed price", () => {
  it("divides base by quote at the feed's decimals", () => {
    // ETH/USD 2552.49827955 (expo −8) ÷ USDC/USD 0.99990000 (expo −8) at 8 dp = 2552.75355490…
    expect(ratio({ price: 255249827955n, expo: -8 }, { price: 99990000n, expo: -8 }, 8)).toBe(255275355490n);
    // different exponents: MON/USD 0.02761907 (expo −8) ÷ USDC/USD 1.000 (expo −3)
    expect(ratio({ price: 2761907n, expo: -8 }, { price: 1000n, expo: -3 }, 8)).toBe(2761907n);
    expect(ratio({ price: 2761907n, expo: -8 }, undefined, 18)).toBe(27619070000000000n);
    expect(ratio(undefined, { price: 1n, expo: 0 }, 8)).toBeUndefined();
    expect(ratio({ price: 1n, expo: 0 }, { price: 0n, expo: 0 }, 8)).toBeUndefined();
  });
});
