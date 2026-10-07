import { encodeAbiParameters, hashTypedData, keccak256, concat, type Address, type Hex, type LocalAccount } from "viem";

/** ORACLES.md §3.1. WAD values are bigints; `tenorTimestamps` and `atmTotalVarianceByTenor` have 4 entries (unused 0). */
export interface SurfaceReport {
  chainId: bigint;
  verifyingContract: Address;
  productId: Hex;
  underlying: Address;
  settlementAsset: Address;
  surfaceSeq: bigint;
  validAfter: bigint;
  expiresAt: bigint;
  spotReferenceId: Hex;
  surfaceRoot: Hex;
  tenorTimestamps: readonly [bigint, bigint, bigint, bigint];
  atmTotalVarianceByTenor: readonly [bigint, bigint, bigint, bigint];
  kNodes: readonly bigint[];
  surfaceMinIvBps: number;
  surfaceMaxIvBps: number;
  confidenceBps: number;
  sourceCount: number;
  liquidityScore: number;
  maxBidAskWidthBps: number;
  lastCalibrationTime: bigint;
  riskParameterSetId: Hex;
}

/** ORACLES.md §4. */
export interface NodeProof {
  productId: Hex;
  surfaceSeq: bigint;
  tenorIndex: number;
  nodeIndex: number;
  totalVarianceWad: bigint;
  proof: readonly Hex[];
}

/** The EIP-712 types `VolSurfaceOracle.REPORT_TYPEHASH` hashes (fixed arrays and `kNodes` as EIP-712 arrays). */
export const SURFACE_REPORT_TYPES = {
  SurfaceReport: [
    { name: "chainId", type: "uint256" },
    { name: "verifyingContract", type: "address" },
    { name: "productId", type: "bytes32" },
    { name: "underlying", type: "address" },
    { name: "settlementAsset", type: "address" },
    { name: "surfaceSeq", type: "uint64" },
    { name: "validAfter", type: "uint64" },
    { name: "expiresAt", type: "uint64" },
    { name: "spotReferenceId", type: "bytes32" },
    { name: "surfaceRoot", type: "bytes32" },
    { name: "tenorTimestamps", type: "uint64[4]" },
    { name: "atmTotalVarianceByTenor", type: "uint256[4]" },
    { name: "kNodes", type: "int256[]" },
    { name: "surfaceMinIvBps", type: "uint32" },
    { name: "surfaceMaxIvBps", type: "uint32" },
    { name: "confidenceBps", type: "uint32" },
    { name: "sourceCount", type: "uint16" },
    { name: "liquidityScore", type: "uint32" },
    { name: "maxBidAskWidthBps", type: "uint32" },
    { name: "lastCalibrationTime", type: "uint64" },
    { name: "riskParameterSetId", type: "bytes32" },
  ],
} as const;

export const surfaceDomain = (chainId: bigint, verifyingContract: Address) =>
  ({ name: "Optara VolSurfaceOracle", version: "1", chainId, verifyingContract }) as const;

const typed = (r: SurfaceReport) =>
  ({
    domain: surfaceDomain(r.chainId, r.verifyingContract),
    types: SURFACE_REPORT_TYPES,
    primaryType: "SurfaceReport",
    message: { ...r, tenorTimestamps: [...r.tenorTimestamps], atmTotalVarianceByTenor: [...r.atmTotalVarianceByTenor], kNodes: [...r.kNodes] },
  }) as const;

/** Equal to `VolSurfaceOracle.reportDigest(r)`. */
export const reportDigest = (r: SurfaceReport): Hex => hashTypedData(typed(r));

export const signReport = (r: SurfaceReport, account: LocalAccount): Promise<Hex> => account.signTypedData(typed(r));

/** Signatures in the order the oracle requires: sorted by signer address, strictly increasing. */
export function sortSignatures(sigs: { signer: Address; signature: Hex }[]): Hex[] {
  const sorted = [...sigs].sort((a, b) => (BigInt(a.signer) < BigInt(b.signer) ? -1 : 1));
  for (let i = 1; i < sorted.length; i++) {
    if (BigInt(sorted[i]!.signer) === BigInt(sorted[i - 1]!.signer)) throw new Error(`duplicate signer ${sorted[i]!.signer}`);
  }
  return sorted.map((s) => s.signature);
}

/** ORACLES.md §3.2: `keccak256(abi.encode(productId, surfaceSeq, tenorIndex, nodeIndex, totalVarianceWad))`. */
export const surfaceLeaf = (productId: Hex, seq: bigint, tenorIndex: number, nodeIndex: number, w: bigint): Hex =>
  keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "uint64" }, { type: "uint8" }, { type: "uint8" }, { type: "uint256" }],
      [productId, seq, tenorIndex, nodeIndex, w],
    ),
  );

const hashPair = (a: Hex, b: Hex): Hex => (BigInt(a) < BigInt(b) ? keccak256(concat([a, b])) : keccak256(concat([b, a])));

/**
 * Sorted-pair Merkle tree (OpenZeppelin `MerkleProof`): leaves in the given order, adjacent pairs hashed, an odd
 * last node carried up unchanged.
 */
export class MerkleTree {
  readonly layers: Hex[][];

  constructor(leaves: readonly Hex[]) {
    if (leaves.length === 0) throw new Error("Merkle tree needs at least one leaf");
    this.layers = [[...leaves]];
    while (this.layers[this.layers.length - 1]!.length > 1) {
      const prev = this.layers[this.layers.length - 1]!;
      const next: Hex[] = [];
      for (let i = 0; i < prev.length; i += 2) next.push(i + 1 < prev.length ? hashPair(prev[i]!, prev[i + 1]!) : prev[i]!);
      this.layers.push(next);
    }
  }

  get root(): Hex {
    return this.layers[this.layers.length - 1]![0]!;
  }

  proof(index: number): Hex[] {
    const out: Hex[] = [];
    for (let l = 0; l < this.layers.length - 1; l++) {
      const layer = this.layers[l]!;
      const sibling = index ^ 1;
      if (sibling < layer.length) out.push(layer[sibling]!);
      index >>= 1;
    }
    return out;
  }

  static verify(proof: readonly Hex[], root: Hex, leaf: Hex): boolean {
    return proof.reduce((h, p) => hashPair(h, p), leaf) === root;
  }
}

/** A report's grid: `w[t][j]` for tenor t and node j, with its leaves (row-major) and tree. */
export class SurfaceGrid {
  readonly tree: MerkleTree;
  readonly leaves: Hex[];

  constructor(
    readonly productId: Hex,
    readonly seq: bigint,
    readonly w: readonly (readonly bigint[])[],
  ) {
    this.leaves = [];
    w.forEach((row, t) => row.forEach((v, j) => this.leaves.push(surfaceLeaf(productId, seq, t, j, v))));
    this.tree = new MerkleTree(this.leaves);
  }

  get nodesPerTenor(): number {
    return this.w[0]?.length ?? 0;
  }

  nodeProof(tenorIndex: number, nodeIndex: number): NodeProof {
    const v = this.w[tenorIndex]?.[nodeIndex];
    if (v === undefined) throw new Error(`no leaf (${tenorIndex}, ${nodeIndex})`);
    return {
      productId: this.productId,
      surfaceSeq: this.seq,
      tenorIndex,
      nodeIndex,
      totalVarianceWad: v,
      proof: this.tree.proof(tenorIndex * this.nodesPerTenor + nodeIndex),
    };
  }
}

export interface ReportInput {
  chainId: bigint;
  verifyingContract: Address;
  productId: Hex;
  underlying: Address;
  settlementAsset: Address;
  seq: bigint;
  validAfter: bigint;
  /** expiresAt − validAfter, ≤ the product's maxReportLifetime. */
  lifetime: bigint;
  /** 1–4 increasing tenor timestamps. */
  tenors: readonly bigint[];
  /** Increasing log-moneyness nodes (WAD), 1–32. */
  kNodes: readonly bigint[];
  /** Total variance (WAD) per tenor per node. */
  w: readonly (readonly bigint[])[];
  /** ATM total variance (WAD) per tenor. */
  atm: readonly bigint[];
  surfaceMinIvBps: number;
  surfaceMaxIvBps: number;
  confidenceBps: number;
  sourceCount: number;
  liquidityScore?: number;
  maxBidAskWidthBps?: number;
  lastCalibrationTime?: bigint;
  spotReferenceId?: Hex;
  riskParameterSetId?: Hex;
}

const ZERO32 = `0x${"0".repeat(64)}` as Hex;
const pad4 = (xs: readonly bigint[]) => [xs[0] ?? 0n, xs[1] ?? 0n, xs[2] ?? 0n, xs[3] ?? 0n] as const;

/** A complete report (root over the grid's leaves) and its grid, ready to sign. */
export function assembleReport(i: ReportInput): { report: SurfaceReport; grid: SurfaceGrid } {
  if (i.tenors.length < 1 || i.tenors.length > 4) throw new Error("1-4 tenors");
  if (i.w.length !== i.tenors.length || i.atm.length !== i.tenors.length) throw new Error("one grid row and ATM value per tenor");
  if (i.w.some((row) => row.length !== i.kNodes.length)) throw new Error("one leaf per node per tenor");
  const grid = new SurfaceGrid(i.productId, i.seq, i.w);
  const report: SurfaceReport = {
    chainId: i.chainId,
    verifyingContract: i.verifyingContract,
    productId: i.productId,
    underlying: i.underlying,
    settlementAsset: i.settlementAsset,
    surfaceSeq: i.seq,
    validAfter: i.validAfter,
    expiresAt: i.validAfter + i.lifetime,
    spotReferenceId: i.spotReferenceId ?? ZERO32,
    surfaceRoot: grid.tree.root,
    tenorTimestamps: pad4(i.tenors),
    atmTotalVarianceByTenor: pad4(i.atm),
    kNodes: i.kNodes,
    surfaceMinIvBps: i.surfaceMinIvBps,
    surfaceMaxIvBps: i.surfaceMaxIvBps,
    confidenceBps: i.confidenceBps,
    sourceCount: i.sourceCount,
    liquidityScore: i.liquidityScore ?? 0,
    maxBidAskWidthBps: i.maxBidAskWidthBps ?? 0,
    lastCalibrationTime: i.lastCalibrationTime ?? i.validAfter,
    riskParameterSetId: i.riskParameterSetId ?? ZERO32,
  };
  return { report, grid };
}
