import type { Hex } from "viem";
import type { NodeProof, SurfaceReport } from "./surface.ts";
import type { OracleUpdate } from "./oracleUpdate.ts";

/** JSON with bigints as decimal strings (the service APIs' wire format). */
export const toJson = (value: unknown): string => JSON.stringify(value, (_, v) => (typeof v === "bigint" ? v.toString() : v));

const big = (v: unknown, what: string): bigint => {
  if (typeof v === "bigint") return v;
  if (typeof v === "string" && /^-?\d+$/.test(v)) return BigInt(v);
  if (typeof v === "number" && Number.isSafeInteger(v)) return BigInt(v);
  throw new Error(`${what}: not an integer`);
};
const num = (v: unknown, what: string): number => {
  const n = typeof v === "string" ? Number(v) : v;
  if (typeof n !== "number" || !Number.isSafeInteger(n)) throw new Error(`${what}: not a small integer`);
  return n;
};
const hex = (v: unknown, what: string): Hex => {
  if (typeof v !== "string" || !/^0x[0-9a-fA-F]*$/.test(v)) throw new Error(`${what}: not hex`);
  return v as Hex;
};
const four = (v: unknown, what: string) => {
  if (!Array.isArray(v) || v.length !== 4) throw new Error(`${what}: needs 4 entries`);
  return [big(v[0], what), big(v[1], what), big(v[2], what), big(v[3], what)] as const;
};

export function reportFromJson(o: any): SurfaceReport {
  return {
    chainId: big(o.chainId, "chainId"),
    verifyingContract: hex(o.verifyingContract, "verifyingContract"),
    productId: hex(o.productId, "productId"),
    underlying: hex(o.underlying, "underlying"),
    settlementAsset: hex(o.settlementAsset, "settlementAsset"),
    surfaceSeq: big(o.surfaceSeq, "surfaceSeq"),
    validAfter: big(o.validAfter, "validAfter"),
    expiresAt: big(o.expiresAt, "expiresAt"),
    spotReferenceId: hex(o.spotReferenceId, "spotReferenceId"),
    surfaceRoot: hex(o.surfaceRoot, "surfaceRoot"),
    tenorTimestamps: four(o.tenorTimestamps, "tenorTimestamps"),
    atmTotalVarianceByTenor: four(o.atmTotalVarianceByTenor, "atmTotalVarianceByTenor"),
    kNodes: (o.kNodes as unknown[]).map((k) => big(k, "kNodes")),
    surfaceMinIvBps: num(o.surfaceMinIvBps, "surfaceMinIvBps"),
    surfaceMaxIvBps: num(o.surfaceMaxIvBps, "surfaceMaxIvBps"),
    confidenceBps: num(o.confidenceBps, "confidenceBps"),
    sourceCount: num(o.sourceCount, "sourceCount"),
    liquidityScore: num(o.liquidityScore, "liquidityScore"),
    maxBidAskWidthBps: num(o.maxBidAskWidthBps, "maxBidAskWidthBps"),
    lastCalibrationTime: big(o.lastCalibrationTime, "lastCalibrationTime"),
    riskParameterSetId: hex(o.riskParameterSetId, "riskParameterSetId"),
  };
}

export const nodeProofFromJson = (o: any): NodeProof => ({
  productId: hex(o.productId, "productId"),
  surfaceSeq: big(o.surfaceSeq, "surfaceSeq"),
  tenorIndex: num(o.tenorIndex, "tenorIndex"),
  nodeIndex: num(o.nodeIndex, "nodeIndex"),
  totalVarianceWad: big(o.totalVarianceWad, "totalVarianceWad"),
  proof: (o.proof as unknown[]).map((p) => hex(p, "proof")),
});

export const oracleUpdateFromJson = (o: any): OracleUpdate => ({
  spotUpdates: (o.spotUpdates as unknown[]).map((x) => hex(x, "spotUpdates")),
  spotProductIds: (o.spotProductIds as unknown[]).map((x) => hex(x, "spotProductIds")),
  reports: (o.reports as unknown[]).map(reportFromJson),
  reportSignatures: (o.reportSignatures as unknown[][]).map((l) => l.map((x) => hex(x, "reportSignatures"))),
  nodes: (o.nodes as unknown[]).map(nodeProofFromJson),
});
