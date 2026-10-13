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

describe("feed pusher isolation", () => {
  it("pushes the feeds whose price source works when another one fails", async () => {
    const { FeedPusher } = await import("../src/feedPusher.ts");
    const ETH = ("0x" + "11".repeat(32)) as `0x${string}`;
    const MON = ("0x" + "22".repeat(32)) as `0x${string}`;
    const USDC = ("0x" + "33".repeat(32)) as `0x${string}`;
    const sent: { feed: string; answer: bigint }[] = [];
    const logs: string[] = [];
    const client = {
      getBlock: async () => ({ timestamp: 10_000n }),
      readContract: async ({ functionName }: { functionName: string }) => (functionName === "decimals" ? 8 : [1n, 1n, 0n, 0n, 1n]),
      simulateContract: async (req: { address: string; args: [bigint] }) => ({ request: req }),
      estimateContractGas: async () => 100_000n,
      waitForTransactionReceipt: async () => ({ status: "success" }),
    };
    const wallet = {
      account: { address: "0x0000000000000000000000000000000000000001" },
      writeContract: async (req: { address: string; args: [bigint] }) => {
        sent.push({ feed: req.address, answer: req.args[0] });
        return "0xabc";
      },
    };
    const prices = {
      prices: async (ids: readonly `0x${string}`[]) => {
        if (ids.includes(MON)) throw new Error("RedStone gateway: 403");
        return new Map([
          [ETH, { price: 250000000000n, expo: -8, publishTime: 1n }],
          [USDC, { price: 100000000n, expo: -8, publishTime: 1n }],
        ]);
      },
    };
    const pusher = new FeedPusher({ client, wallet, log: (m: string) => logs.push(m), gasBufferBps: 1000n } as never, {
      feeds: [
        { feed: "0x00000000000000000000000000000000000000aa", base: MON, quote: USDC, label: "MON / USDC" },
        { feed: "0x00000000000000000000000000000000000000bb", base: ETH, quote: USDC, label: "WETH / USDC" },
      ],
      prices,
      intervalSeconds: 300,
    });
    await pusher.tick();
    expect(sent.map((s) => s.feed)).toEqual(["0x00000000000000000000000000000000000000bb"]);
    expect(sent[0]!.answer).toBe(250000000000n);
    expect(logs.some((l) => l.includes("no price for MON / USDC") && l.includes("403"))).toBe(true);
  });
});
