import type { Hex } from "viem";
import type { NodeProof, SurfaceReport } from "./surface.ts";

/** ORACLES.md §4: the argument of every risk-increasing entry point and of `OptionClearing.updateOracles`. */
export interface OracleUpdate {
  spotUpdates: readonly Hex[];
  spotProductIds: readonly Hex[];
  reports: readonly SurfaceReport[];
  reportSignatures: readonly (readonly Hex[])[];
  nodes: readonly NodeProof[];
}

export const emptyOracleUpdate = (): OracleUpdate => ({
  spotUpdates: [],
  spotProductIds: [],
  reports: [],
  reportSignatures: [],
  nodes: [],
});

/** Concatenates updates, dropping duplicate product ids and duplicate leaves. */
export function mergeOracleUpdates(...us: OracleUpdate[]): OracleUpdate {
  const out = emptyOracleUpdate() as { -readonly [K in keyof OracleUpdate]: any[] };
  const products = new Set<string>();
  const leaves = new Set<string>();
  const reports = new Set<string>();
  for (const u of us) {
    out.spotUpdates.push(...u.spotUpdates);
    for (const p of u.spotProductIds) if (!products.has(p)) (products.add(p), out.spotProductIds.push(p));
    u.reports.forEach((r, i) => {
      const k = `${r.productId}:${r.surfaceSeq}`;
      if (reports.has(k)) return;
      reports.add(k);
      out.reports.push(r);
      out.reportSignatures.push(u.reportSignatures[i]);
    });
    for (const n of u.nodes) {
      const k = `${n.productId}:${n.surfaceSeq}:${n.tenorIndex}:${n.nodeIndex}`;
      if (!leaves.has(k)) (leaves.add(k), out.nodes.push(n));
    }
  }
  return out;
}
