/**
 * FE-002: risk-increasing transactions fetch a fresh OracleUpdate when they run (not when built) and re-preview
 * (simulate the exact call with it) before sending; the provider fee goes in `value`.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { emptyOracleUpdate, type OracleUpdate } from "@optara/sdk";

const calls: string[] = [];
vi.mock("./client.ts", async (orig) => {
  const real = await orig<typeof import("./client.ts")>();
  return {
    ...real,
    publicClient: {
      simulateContract: vi.fn(async (args: any) => (calls.push(`simulate:${args.functionName}:${JSON.stringify(args.value?.toString())}`), { result: undefined, request: args })),
      estimateContractGas: vi.fn(async () => (calls.push("estimate"), 1_000_000n)),
      waitForTransactionReceipt: vi.fn(async () => (calls.push("receipt"), { status: "success", logs: [] })),
    },
  };
});

const { mintSteps, withdrawSteps, startAuctionSteps, depositSteps } = await import("./actions.ts");

const wallet = {
  account: { address: "0x0000000000000000000000000000000000000005" },
  writeContract: vi.fn(async (args: any) => (calls.push(`write:${args.functionName}:gas=${args.gas}`), "0xhash")),
} as any;

const series = { id: `0x${"aa".repeat(32)}`, settlementAsset: "0x00000000000000000000000000000000000000E2", assetSymbol: "USDC" } as any;

beforeEach(() => {
  calls.length = 0;
});

describe("FE-002 fresh oracle data before every risk-increasing send", () => {
  it("mint: fetch at run time, simulate with the update and fee, then send with a gas buffer", async () => {
    const update: OracleUpdate = { ...emptyOracleUpdate(), spotUpdates: ["0x01"], spotProductIds: [`0x${"11".repeat(32)}`] };
    const fetchOracleUpdate = vi.fn(async () => (calls.push("fetch"), update));
    const oracleFee = vi.fn(async () => (calls.push("fee"), 7n));
    const [step] = mintSteps(3n, series, 10n ** 18n, 5_000_000n, wallet.account.address, { fetchOracleUpdate, oracleFee });
    expect(fetchOracleUpdate).not.toHaveBeenCalled(); // nothing fetched when the action is built
    await step!.run(wallet);
    expect(fetchOracleUpdate).toHaveBeenCalledWith(3n, [series.id]);
    expect(calls).toEqual(["fetch", "fee", 'simulate:mintExternalLong:"7"', "estimate", "write:mintExternalLong:gas=1100000", "receipt"]);
    const sent = wallet.writeContract.mock.calls[0]![0];
    expect(sent.args[5]).toBe(update); // the update travels with the transaction
    expect(sent.value).toBe(7n);
  });

  it("withdraw and liquidation starts are risk-checked the same way", async () => {
    for (const steps of [withdrawSteps(3n, 1n, wallet.account.address, deps()), startAuctionSteps(3n, wallet.account.address, deps())]) {
      calls.length = 0;
      await steps[0]!.run(wallet);
      expect(calls.slice(0, 3)).toEqual(["fetch", "fee", expect.stringMatching(/^simulate:/)]);
    }
  });

  it("a revert in the re-preview stops before the wallet is asked", async () => {
    const { publicClient } = await import("./client.ts");
    (publicClient.simulateContract as any).mockRejectedValueOnce(new Error("NotHealthy"));
    const [step] = mintSteps(3n, series, 10n ** 18n, 1n, wallet.account.address, deps());
    wallet.writeContract.mockClear();
    await expect(step!.run(wallet)).rejects.toThrow();
    expect(wallet.writeContract).not.toHaveBeenCalled();
  });

  it("deposits need no oracle data", async () => {
    const steps = depositSteps(3n, series.settlementAsset, 1n, "USDC");
    expect(steps.map((s) => s.key)).toEqual([`approve-${series.settlementAsset}-${(await import("./client.ts")).ADDR.clearing}`, "deposit"]);
  });
});

function deps() {
  return {
    fetchOracleUpdate: vi.fn(async () => (calls.push("fetch"), emptyOracleUpdate())),
    oracleFee: vi.fn(async () => (calls.push("fee"), 0n)),
  };
}
