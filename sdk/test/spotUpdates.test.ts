import { describe, expect, it } from "vitest";
import { isRedstoneFeedId, spotUpdatesByProduct } from "../src/pyth.ts";
import { stringToHex } from "viem";

describe("spot updates per product", () => {
  const ETH = ("0x" + "11".repeat(32)) as `0x${string}`;
  const USDC = ("0x" + "33".repeat(32)) as `0x${string}`;
  const MON = stringToHex("MON", { size: 32 }); // a RedStone feed id
  const USDC_RS = stringToHex("USDC", { size: 32 });

  it("recognizes RedStone feed ids", () => {
    expect(isRedstoneFeedId(MON)).toBe(true);
    expect(isRedstoneFeedId(ETH)).toBe(false);
  });

  it("fetches providers in parallel, shares feeds within a provider and keeps the products whose provider works", async () => {
    const calls: string[][] = [];
    const spot = {
      updates: async (ids: readonly `0x${string}`[]) => {
        calls.push([...ids]);
        if (ids.some(isRedstoneFeedId)) throw new Error("RedStone gateway: 403\nmore detail");
        return [`0xpyth${ids.length}` as `0x${string}`];
      },
    };
    const r = await spotUpdatesByProduct(spot, [
      { productId: "0xaa", feedIds: [MON, USDC_RS] },
      { productId: "0xbb", feedIds: [ETH, USDC] },
      { productId: "0xcc", feedIds: [USDC] },
    ]);
    expect(r.productIds).toEqual(["0xbb", "0xcc"]);
    expect(r.updates).toEqual(["0xpyth2"]); // one Pyth request for ETH and USDC, USDC not fetched twice
    expect(r.failed).toEqual([{ productId: "0xaa", error: "RedStone gateway: 403" }]);
    expect(calls.length).toBe(2);
  });

  it("does not wait for a hanging provider longer than the other one takes to fail or answer", async () => {
    let pythDoneAt = 0;
    const start = Date.now();
    const spot = {
      updates: (ids: readonly `0x${string}`[]) =>
        ids.some(isRedstoneFeedId)
          ? new Promise<`0x${string}`[]>((_, reject) => setTimeout(() => reject(new Error("timeout")), 300))
          : Promise.resolve().then(() => {
              pythDoneAt = Date.now() - start;
              return ["0xpyth" as `0x${string}`];
            }),
    };
    const r = await spotUpdatesByProduct(spot, [
      { productId: "0xaa", feedIds: [MON] },
      { productId: "0xbb", feedIds: [ETH] },
    ]);
    expect(pythDoneAt).toBeLessThan(100); // started at once, not after MON's 300 ms
    expect(r.productIds).toEqual(["0xbb"]);
  });
});
