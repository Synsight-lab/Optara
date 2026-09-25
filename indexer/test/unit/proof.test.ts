import { describe, expect, it } from "vitest";
import type { PublicClient } from "viem";
import { findRoundInForce } from "../../src/proof.ts";

/** Minimal fake Chainlink proxy: rounds of one phase with increasing updatedAt. */
function fakeFeed(phase: bigint, times: bigint[]) {
  const id = (agg: bigint) => (phase << 64n) | agg;
  let calls = 0;
  const client = {
    readContract: async ({ functionName, args }: { functionName: string; args?: [bigint] }) => {
      calls++;
      if (functionName === "latestRoundData") {
        const agg = BigInt(times.length);
        return [id(agg), 100n + agg, 0n, times[times.length - 1]!, id(agg)];
      }
      const agg = args![0] & ((1n << 64n) - 1n);
      const t = times[Number(agg) - 1];
      if (t === undefined) throw new Error("No data present");
      return [args![0], 100n + agg, 0n, t, args![0]];
    },
  } as unknown as PublicClient;
  return { client, id, calls: () => calls };
}

describe("round-in-force search", () => {
  const times = Array.from({ length: 1000 }, (_, i) => BigInt(1000 + i * 60));
  it("finds the last round with updatedAt <= T and its immediate successor", async () => {
    const f = fakeFeed(2n, times);
    const t = 1000n + 500n * 60n + 30n; // between round 501 and 502
    const p = await findRoundInForce(f.client, "0x0000000000000000000000000000000000000001", t);
    expect(p.roundId).toBe(f.id(501n));
    expect(p.nextRoundId).toBe(f.id(502n));
    expect(p.updatedAt <= t).toBe(true);
    expect(f.calls()).toBeLessThan(20); // binary search, not a linear scan
  });
  it("uses the latest round (nextRoundId = 0) when nothing newer exists", async () => {
    const f = fakeFeed(1n, times);
    const p = await findRoundInForce(f.client, "0x0000000000000000000000000000000000000001", 10_000_000n);
    expect(p.roundId).toBe(f.id(1000n));
    expect(p.nextRoundId).toBe(0n);
  });
  it("treats an exact timestamp match as in force", async () => {
    const f = fakeFeed(1n, times);
    const p = await findRoundInForce(f.client, "0x0000000000000000000000000000000000000001", times[9]!);
    expect(p.roundId).toBe(f.id(10n));
    expect(p.nextRoundId).toBe(f.id(11n));
  });
  it("fails when no round of the feed is in force at T", async () => {
    const f = fakeFeed(1n, times);
    await expect(findRoundInForce(f.client, "0x0000000000000000000000000000000000000001", 5n)).rejects.toThrow(/no round/);
  });
});

/** Fake Chainlink proxy with several phases: phases[i] holds the updatedAt list of phase i + 1. */
function phasedFeed(phases: bigint[][]) {
  const id = (phase: bigint, agg: bigint) => (phase << 64n) | agg;
  const client = {
    readContract: async ({ functionName, args }: { functionName: string; args?: [bigint] }) => {
      if (functionName === "latestRoundData") {
        const phase = BigInt(phases.length);
        const agg = BigInt(phases[phases.length - 1]!.length);
        return [id(phase, agg), 7n, 0n, phases[phases.length - 1]![Number(agg) - 1]!, id(phase, agg)];
      }
      const phase = args![0] >> 64n;
      const agg = args![0] & ((1n << 64n) - 1n);
      const t = phases[Number(phase) - 1]?.[Number(agg) - 1];
      if (t === undefined) throw new Error("No data present");
      return [args![0], 7n, 0n, t, args![0]];
    },
  } as unknown as PublicClient;
  return { client, id };
}

describe("round-in-force search across Chainlink phases (matches the adapter's isImmediateSuccessor)", () => {
  const feed = "0x0000000000000000000000000000000000000001" as const;
  const p1 = Array.from({ length: 37 }, (_, i) => BigInt(1000 + i * 10)); // 1000..1360
  const p2 = Array.from({ length: 50 }, (_, i) => BigInt(5000 + i * 10)); // 5000..5490

  it("proves the last round of the previous phase with the first round of the new phase as successor", async () => {
    const f = phasedFeed([p1, p2]);
    const p = await findRoundInForce(f.client, feed, 4000n); // after phase 1 ended, before phase 2 began
    expect(p.roundId).toBe(f.id(1n, 37n));
    expect(p.nextRoundId).toBe(f.id(2n, 1n));
    expect(p.updatedAt).toBe(1360n);
  });

  it("binary-searches inside an older phase", async () => {
    const f = phasedFeed([p1, p2]);
    const p = await findRoundInForce(f.client, feed, 1105n); // between phase-1 rounds 11 (1100) and 12 (1110)
    expect(p.roundId).toBe(f.id(1n, 11n));
    expect(p.nextRoundId).toBe(f.id(1n, 12n));
  });

  it("walks back more than one phase", async () => {
    const p3 = [9000n, 9010n];
    const f = phasedFeed([p1, p2, p3]);
    const p = await findRoundInForce(f.client, feed, 1365n);
    expect(p.roundId).toBe(f.id(1n, 37n));
    expect(p.nextRoundId).toBe(f.id(2n, 1n));
  });

  it("fails when T precedes the feed's first round", async () => {
    const f = phasedFeed([p1, p2]);
    await expect(findRoundInForce(f.client, feed, 999n)).rejects.toThrow(/no round/);
  });
});
