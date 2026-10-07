/**
 * The SDK against the deployed contracts (local stack on anvil): EIP-712 digests equal the oracle's, a report built
 * and signed here is accepted with its node proofs, and the settlement proof builder finds the round in force.
 */
import { afterAll, beforeAll, describe, expect, inject, it } from "vitest";
import {
  assembleReport,
  findRoundInForce,
  buildSettlementProof,
  MockPythSource,
  reportDigest,
  signReport,
  sortSignatures,
  toWad,
  totalVarianceFromIv,
  yearsBetween,
  volSurfaceOracleAbi,
  optionClearingAbi,
  liveSpotOracleAbi,
  settlementOracleAbi,
  aggregatorV3Abi,
  type OracleUpdate,
} from "../src/index.ts";
import { startLocalStack, stackAccount, stackProduct, increaseTime, latestTimestamp, type LocalStack } from "../src/testing/index.ts";

const mockAggregatorAbi = [
  {
    type: "function",
    name: "pushRound",
    stateMutability: "nonpayable",
    inputs: [
      { name: "answer", type: "int256" },
      { name: "updatedAt", type: "uint256" },
    ],
    outputs: [{ name: "roundId", type: "uint80" }],
  },
] as const;

let s: LocalStack;
beforeAll(async () => {
  const { statePath, manifestPath } = inject("stack");
  s = await startLocalStack(statePath, manifestPath);
});
afterAll(() => s?.anvil.stop());

const RATIOS = [0.625, 0.875, 1, 1.125, 1.25, 1.625];

async function flatReport(seq: bigint, spot: number, iv: number) {
  const p = stackProduct(s.manifest);
  const now = await latestTimestamp(s.anvil.rpcUrl);
  const kNodes = RATIOS.map((r) => toWad(Math.log(r)));
  const w = p.expiries.map((t) => toWad(totalVarianceFromIv(iv, yearsBetween(now, t))));
  return assembleReport({
    chainId: 31337n,
    verifyingContract: s.manifest.proxies.VolSurfaceOracle.proxy,
    productId: p.productId,
    underlying: p.weth,
    settlementAsset: p.usdc,
    seq,
    validAfter: now,
    lifetime: 900n,
    tenors: p.expiries,
    kNodes,
    w: w.map((v) => kNodes.map(() => v)),
    atm: w,
    surfaceMinIvBps: 1000,
    surfaceMaxIvBps: 50_000,
    confidenceBps: 100,
    sourceCount: 3,
  });
}

describe("surface reports", () => {
  it("the TypeScript EIP-712 digest equals VolSurfaceOracle.reportDigest", async () => {
    const { report } = await flatReport(2n, 4000, 0.6);
    const onChain = await s.test.readContract({
      address: s.manifest.proxies.VolSurfaceOracle.proxy,
      abi: volSurfaceOracleAbi,
      functionName: "reportDigest",
      args: [report],
    });
    expect(reportDigest(report)).toBe(onChain);
  });

  it("a report signed here is accepted, its leaves prove, and the surface prices a series", async () => {
    const p = stackProduct(s.manifest);
    const { report, grid } = await flatReport(2n, 4000, 0.6);
    const [a, b] = [stackAccount(2), stackAccount(3)];
    const signatures = sortSignatures([
      { signer: a.address, signature: await signReport(report, a) },
      { signer: b.address, signature: await signReport(report, b) },
    ]);
    const spot = new MockPythSource(() => 4000, () => latestTimestamp(s.anvil.rpcUrl));
    const nodes = [];
    for (let t = 0; t < 2; t++) for (let j = 0; j < 6; j++) nodes.push(grid.nodeProof(t, j));
    const u: OracleUpdate = {
      spotUpdates: await spot.updates([p.pythFeedId]),
      spotProductIds: [p.productId],
      reports: [report],
      reportSignatures: [signatures],
      nodes,
    };
    const fee = await s.test.readContract({
      address: s.manifest.proxies.LiveSpotOracle.proxy,
      abi: liveSpotOracleAbi,
      functionName: "updateFee",
      args: [u.spotUpdates],
    });
    const keeper = stackAccount(4);
    const hash = await s.test.writeContract({
      account: keeper,
      address: s.manifest.proxies.OptionClearing.proxy,
      abi: optionClearingAbi,
      functionName: "updateOracles",
      args: [u],
      value: fee,
    });
    expect((await s.test.waitForTransactionReceipt({ hash })).status).toBe("success");

    const surface = s.manifest.proxies.VolSurfaceOracle.proxy;
    const h = await s.test.readContract({ address: surface, abi: volSurfaceOracleAbi, functionName: "header", args: [p.productId] });
    expect(h.surfaceSeq).toBe(2n);
    const [proven, w] = await s.test.readContract({ address: surface, abi: volSurfaceOracleAbi, functionName: "nodeValue", args: [p.productId, 1, 5] });
    expect(proven).toBe(true);
    expect(w).toBe(grid.w[1]![5]);
    const [spotWad] = await s.test.readContract({
      address: s.manifest.proxies.LiveSpotOracle.proxy,
      abi: liveSpotOracleAbi,
      functionName: "spotPrice",
      args: [p.productId],
    });
    expect(spotWad).toBe(4000n * 10n ** 18n);
    const [sigmas, status] = await s.test.readContract({
      address: surface,
      abi: volSurfaceOracleAbi,
      functionName: "impliedVols",
      args: [p.productId, spotWad, [4500n * 10n ** 18n], [p.expiries[0]!]],
    });
    expect(status).toBe(0);
    expect(Number(sigmas[0]) / 1e18).toBeCloseTo(0.6, 6);
  });
});

describe("settlement proofs", () => {
  it("finds the round in force at the observation end and the oracle verifies it", async () => {
    const p = stackProduct(s.manifest);
    const expiry = p.expiries[0]!;
    const deployer = stackAccount(0);
    const push = async (answer: bigint) => {
      const t = await latestTimestamp(s.anvil.rpcUrl);
      const hash = await s.test.writeContract({ account: deployer, address: p.settlementFeed, abi: mockAggregatorAbi, functionName: "pushRound", args: [answer, t] });
      await s.test.waitForTransactionReceipt({ hash });
    };
    // A round 10 minutes before expiry (inside the 1 h observation window), then one after expiry.
    await increaseTime(s.anvil.rpcUrl, expiry - 600n - (await latestTimestamp(s.anvil.rpcUrl)));
    await push(3900_00000000n);
    await increaseTime(s.anvil.rpcUrl, 900);
    await push(4100_00000000n);

    const r = await findRoundInForce(s.test, p.settlementFeed, expiry);
    expect(r.answer).toBe(3900_00000000n);
    expect(r.nextRoundId).not.toBe(0n);
    const latest = await s.test.readContract({ address: p.settlementFeed, abi: aggregatorV3Abi, functionName: "latestRoundData" });
    expect(r.nextRoundId).toBe(latest[0]);

    const proof = await buildSettlementProof(s.test, s.manifest.proxies.SettlementOracle.proxy, p.settlementConfigId, expiry);
    expect(proof.error).toBeUndefined();
    expect(proof.priceWad).toBe(3900n * 10n ** 18n);
    const earliest = await s.test.readContract({
      address: s.manifest.proxies.SettlementOracle.proxy,
      abi: settlementOracleAbi,
      functionName: "earliestFinalization",
      args: [p.settlementConfigId, expiry],
    });
    expect(await latestTimestamp(s.anvil.rpcUrl)).toBeGreaterThanOrEqual(earliest);
  });
});
