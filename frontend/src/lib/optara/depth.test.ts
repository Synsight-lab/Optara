import { describe, expect, it } from "vitest";
import { fillFromAsks } from "./depth.ts";

const W = 10n ** 18n;
const asks = [
  { price: 2n * W, size: 5n * W }, // 5 options at 2  = 10
  { price: 3n * W, size: 10n * W }, // 10 options at 3 = 30
];

describe("fillFromAsks", () => {
  it("reports the whole book without a budget", () => {
    const f = fillFromAsks(asks);
    expect(f.depthQty).toBe(15n * W);
    expect(f.depthCost).toBe(40n * W);
    expect(f.qty).toBe(0n);
    expect(f.exhausted).toBe(false);
  });

  it("fills inside the best level", () => {
    const f = fillFromAsks(asks, 4n * W);
    expect(f.qty).toBe(2n * W);
    expect(f.cost).toBe(4n * W);
    expect(f.levels).toBe(1);
  });

  it("walks into deeper levels at their price, not the best ask", () => {
    const f = fillFromAsks(asks, 16n * W); // 10 buys 5 at 2, 6 buys 2 at 3
    expect(f.qty).toBe(7n * W);
    expect(f.cost).toBe(16n * W);
    expect(f.levels).toBe(2);
    expect(f.exhausted).toBe(false);
  });

  it("caps at the book and flags the refund", () => {
    const f = fillFromAsks(asks, 100n * W);
    expect(f.qty).toBe(15n * W);
    expect(f.cost).toBe(40n * W);
    expect(f.exhausted).toBe(true);
  });

  it("handles an empty book", () => {
    const f = fillFromAsks([], 10n * W);
    expect(f).toMatchObject({ qty: 0n, depthQty: 0n, exhausted: false });
  });
});
