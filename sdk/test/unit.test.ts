import { describe, expect, it } from "vitest";
import { decodeAbiParameters, keccak256, toHex, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  MerkleTree,
  SurfaceGrid,
  encodeMockPyth,
  findNodes,
  findTenors,
  mergeOracleUpdates,
  emptyOracleUpdate,
  sortSignatures,
  surfaceLeaf,
  toWad,
  WAD,
} from "../src/index.ts";

const leaf = (i: number) => keccak256(toHex(i));

describe("MerkleTree (OpenZeppelin sorted pairs)", () => {
  it("every leaf's proof verifies, for every tree size 1..33", () => {
    for (let n = 1; n <= 33; n++) {
      const leaves = Array.from({ length: n }, (_, i) => leaf(i));
      const t = new MerkleTree(leaves);
      leaves.forEach((l, i) => expect(MerkleTree.verify(t.proof(i), t.root, l)).toBe(true));
      expect(MerkleTree.verify(t.proof(0), t.root, leaf(999))).toBe(false);
    }
  });

  it("a single leaf is its own root", () => {
    expect(new MerkleTree([leaf(7)]).root).toBe(leaf(7));
  });
});

describe("SurfaceGrid", () => {
  it("leaves are row-major (tenor, node) and proofs carry the leaf values", () => {
    const pid = keccak256(toHex("p"));
    const g = new SurfaceGrid(pid, 3n, [
      [1n, 2n, 3n],
      [4n, 5n, 6n],
    ]);
    const p = g.nodeProof(1, 2);
    expect(p.totalVarianceWad).toBe(6n);
    expect(MerkleTree.verify(p.proof, g.tree.root, surfaceLeaf(pid, 3n, 1, 2, 6n))).toBe(true);
    expect(() => g.nodeProof(2, 0)).toThrow();
  });
});

describe("OptionPricer lookups", () => {
  const tenors = [100n, 200n, 300n, 0n];
  it("findTenors brackets or matches, refuses outside", () => {
    expect(findTenors(tenors, 150n)).toEqual([0, 1]);
    expect(findTenors(tenors, 200n)).toEqual([1, 1]);
    expect(findTenors(tenors, 300n)).toEqual([2, 2]);
    expect(findTenors(tenors, 99n)).toBeUndefined();
    expect(findTenors(tenors, 301n)).toBeUndefined();
    expect(findTenors([0n, 0n, 0n, 0n], 1n)).toBeUndefined();
  });
  it("findNodes brackets, matches exactly, extrapolates flat", () => {
    const k = [toWad(-0.5), 0n, toWad(0.5)];
    expect(findNodes(k, -1)).toEqual([0, 0]);
    expect(findNodes(k, -0.2)).toEqual([0, 1]);
    expect(findNodes(k, 0)).toEqual([1, 1]);
    expect(findNodes(k, 0.3)).toEqual([1, 2]);
    expect(findNodes(k, 2)).toEqual([2, 2]);
  });
  it("toWad keeps sub-unit precision", () => {
    expect(toWad(1.5)).toBe(15n * 10n ** 17n);
    expect(toWad(-0.25)).toBe(-(WAD / 4n));
  });
});

describe("signatures", () => {
  it("sorted by signer, duplicates refused", () => {
    const a = privateKeyToAccount(`0x${"11".repeat(32)}`);
    const b = privateKeyToAccount(`0x${"22".repeat(32)}`);
    const [lo, hi] = BigInt(a.address) < BigInt(b.address) ? [a, b] : [b, a];
    expect(sortSignatures([{ signer: hi.address, signature: "0x02" }, { signer: lo.address, signature: "0x01" }])).toEqual(["0x01", "0x02"]);
    expect(() => sortSignatures([{ signer: a.address, signature: "0x01" }, { signer: a.address, signature: "0x02" }])).toThrow(/duplicate/);
  });
});

describe("MockPyth blobs", () => {
  it("encode the layout MockPyth decodes", () => {
    const id = keccak256(toHex("feed"));
    const blob = encodeMockPyth(id, 400_000_000_000n, -8, 1234n, 5n);
    const [d0, d1, d2, d3, d4] = decodeAbiParameters(
      [{ type: "bytes32" }, { type: "int64" }, { type: "uint64" }, { type: "int32" }, { type: "uint256" }],
      blob,
    );
    expect([d0, d1, d2, d3, d4]).toEqual([id, 400_000_000_000n, 5n, -8, 1234n]);
  });
});

describe("mergeOracleUpdates", () => {
  it("drops duplicate products, reports and leaves", () => {
    const pid = keccak256(toHex("p")) as Hex;
    const g = new SurfaceGrid(pid, 1n, [[1n, 2n]]);
    const u = { ...emptyOracleUpdate(), spotUpdates: ["0x01" as Hex], spotProductIds: [pid], nodes: [g.nodeProof(0, 0)] };
    const m = mergeOracleUpdates(u, u);
    expect(m.spotProductIds).toEqual([pid]);
    expect(m.nodes).toHaveLength(1);
    expect(m.spotUpdates).toHaveLength(2);
  });
});
