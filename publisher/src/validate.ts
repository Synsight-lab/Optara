/**
 * INDEXER_AND_KEEPERS.md §5.1 "Validate": every on-chain acceptance check (ORACLES.md §3.4, mirrored from
 * VolSurfaceOracle.submitReport / proveNodes) plus the off-chain no-arbitrage checks the contract leaves to the
 * publisher: calendar on every node and butterfly on every tenor. A publisher signs only a report with no
 * violations; cosigners re-run this before signing.
 */
import type { SurfaceReport } from "@optara/sdk";
import { butterflyViolations } from "./svi.ts";

const YEAR = 31_536_000;
const WAD = 1e18;

export type ViolationCode = "DOMAIN" | "SEQUENCE" | "TIME" | "TENORS" | "KNODES" | "IV_BOUNDS" | "LEAF_IV" | "CALENDAR" | "BUTTERFLY" | "IV_MOVE";
export interface Violation {
  code: ViolationCode;
  detail: string;
}

export interface SurfaceConfigView {
  maxReportLifetime: number;
  maxIvMoveBps: number;
  maxConfidenceBps: number;
  minIvBps: number;
  maxIvBps: number;
}

export interface HeaderView {
  surfaceSeq: bigint;
  validAfter: bigint;
  tenorTimestamps: readonly bigint[];
  atmTotalVarianceByTenor: readonly bigint[];
}

export interface ValidationContext {
  chainId: bigint;
  surface: `0x${string}`;
  now: bigint; // latest block time
  config: SurfaceConfigView;
  header: HeaderView;
  emergency: boolean;
}

const ivOf = (w: number, tenor: bigint, from: bigint) => Math.sqrt(w / (Number(tenor - from) / YEAR));
const EPS = 1e-9;

/** VolSurfaceOracle._oldAtmIv: the stored surface's ATM IV at `t` (linear in total variance, nearest tenor outside). */
function storedAtmIv(h: HeaderView, t: bigint): number {
  const tenors = h.tenorTimestamps.filter((x) => x !== 0n);
  const w = h.atmTotalVarianceByTenor.map((x) => Number(x) / WAD);
  if (t < tenors[0]!) return ivOf(w[0]!, tenors[0]!, h.validAfter);
  const last = tenors.length - 1;
  if (t > tenors[last]!) return ivOf(w[last]!, tenors[last]!, h.validAfter);
  for (let i = 0; i < tenors.length; i++) {
    if (tenors[i] === t) return ivOf(w[i]!, t, h.validAfter);
    if (tenors[i]! > t) {
      const [ta, tb] = [tenors[i - 1]!, tenors[i]!];
      const wt = w[i - 1]! + ((w[i]! - w[i - 1]!) * Number(t - ta)) / Number(tb - ta);
      return ivOf(wt, t, h.validAfter);
    }
  }
  throw new Error("unreachable");
}

export function validateReport(r: SurfaceReport, grid: readonly (readonly bigint[])[], ctx: ValidationContext): Violation[] {
  const v: Violation[] = [];
  const add = (code: ViolationCode, detail: string) => v.push({ code, detail });

  if (r.chainId !== ctx.chainId || r.verifyingContract.toLowerCase() !== ctx.surface.toLowerCase()) add("DOMAIN", "chain id or oracle address");
  if (r.surfaceSeq <= ctx.header.surfaceSeq || r.validAfter < ctx.header.validAfter) add("SEQUENCE", `seq ${r.surfaceSeq} after ${ctx.header.surfaceSeq}`);
  if (r.validAfter > ctx.now || ctx.now >= r.expiresAt || r.expiresAt - r.validAfter > BigInt(ctx.config.maxReportLifetime)) {
    add("TIME", `validAfter ${r.validAfter}, expiresAt ${r.expiresAt}, now ${ctx.now}`);
  }

  // Tenors and ATM variance (VolSurfaceOracle._checkGrid)
  const n = r.tenorTimestamps.findIndex((t) => t === 0n) === -1 ? 4 : r.tenorTimestamps.findIndex((t) => t === 0n);
  if (n === 0 || r.tenorTimestamps[0]! <= r.validAfter) add("TENORS", "no tenor after validAfter");
  for (let i = 0; i < 4; i++) {
    if (i < n) {
      if (r.atmTotalVarianceByTenor[i] === 0n) add("TENORS", `ATM variance 0 at tenor ${i}`);
      if (i > 0 && r.tenorTimestamps[i]! <= r.tenorTimestamps[i - 1]!) add("TENORS", "tenors not increasing");
      if (i > 0 && r.atmTotalVarianceByTenor[i]! < r.atmTotalVarianceByTenor[i - 1]!) add("CALENDAR", `ATM variance falls at tenor ${i}`);
    } else if (r.tenorTimestamps[i] !== 0n || r.atmTotalVarianceByTenor[i] !== 0n) add("TENORS", "non-zero trailing tenor");
  }
  const m = r.kNodes.length;
  if (m === 0 || m > 32) add("KNODES", `${m} nodes`);
  for (let j = 1; j < m; j++) if (r.kNodes[j]! <= r.kNodes[j - 1]!) add("KNODES", "nodes not strictly increasing");

  if (r.surfaceMinIvBps < ctx.config.minIvBps || r.surfaceMaxIvBps > ctx.config.maxIvBps || r.surfaceMinIvBps > r.surfaceMaxIvBps) {
    add("IV_BOUNDS", `report bounds [${r.surfaceMinIvBps}, ${r.surfaceMaxIvBps}] vs product [${ctx.config.minIvBps}, ${ctx.config.maxIvBps}]`);
  }
  const lo = r.surfaceMinIvBps / 10_000;
  const hi = r.surfaceMaxIvBps / 10_000;
  for (let i = 0; i < n; i++) {
    const iv = ivOf(Number(r.atmTotalVarianceByTenor[i]!) / WAD, r.tenorTimestamps[i]!, r.validAfter);
    if (iv < lo * (1 + EPS) || iv > hi * (1 - EPS)) add("IV_BOUNDS", `ATM IV ${iv.toFixed(4)} at tenor ${i} outside the report bounds`);
  }
  // Every leaf must prove (proveNodes rejects a leaf whose IV is outside the report bounds: R_NODE_IV).
  if (grid.length !== n) add("TENORS", `grid has ${grid.length} rows for ${n} tenors`);
  grid.forEach((row, t) =>
    row.forEach((w, j) => {
      const iv = ivOf(Number(w) / WAD, r.tenorTimestamps[t]!, r.validAfter);
      if (!(iv > lo * (1 + EPS) && iv < hi * (1 - EPS))) add("LEAF_IV", `leaf (${t}, ${j}) IV ${iv.toFixed(4)}`);
    }),
  );

  // Calendar on every node; butterfly on every tenor (the contract's linear-in-k interpolation).
  const k = r.kNodes.map((x) => Number(x) / WAD);
  for (let t = 1; t < grid.length; t++) {
    grid[t]!.forEach((w, j) => {
      if (w < grid[t - 1]![j]!) add("CALENDAR", `total variance falls between tenors ${t - 1} and ${t} at node ${j}`);
    });
  }
  grid.forEach((row, t) => {
    for (const msg of butterflyViolations(k, row.map((w) => Number(w) / WAD))) add("BUTTERFLY", `tenor ${t}: ${msg}`);
  });

  // ATM move against the stored surface (unless emergency mode is on), as VolSurfaceOracle._checkIvMove.
  if (ctx.header.surfaceSeq !== 0n && !ctx.emergency) {
    for (let i = 0; i < n; i++) {
      const t = r.tenorTimestamps[i]!;
      const ivNew = ivOf(Number(r.atmTotalVarianceByTenor[i]!) / WAD, t, r.validAfter);
      const ivOld = storedAtmIv(ctx.header, t);
      if (Math.abs(ivNew - ivOld) * 10_000 > ctx.config.maxIvMoveBps * ivOld * (1 - EPS)) {
        add("IV_MOVE", `tenor ${i}: ATM IV ${ivOld.toFixed(4)} -> ${ivNew.toFixed(4)} exceeds ${ctx.config.maxIvMoveBps} bps`);
      }
    }
  }
  return v;
}
