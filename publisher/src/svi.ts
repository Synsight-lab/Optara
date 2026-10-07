/**
 * Smile calibration (INDEXER_AND_KEEPERS.md §5.1 "Calibrate"): raw SVI per expiry,
 *   w(k) = a + b (ρ (k − m) + sqrt((k − m)² + σ²)),
 * fitted to total-variance quotes by weighted least squares (Nelder–Mead over an unconstrained parametrization
 * with b ≥ 0, |ρ| < 1, σ > 0 and a penalty keeping min w = a + b σ sqrt(1 − ρ²) ≥ 0).
 */

export interface Svi {
  a: number;
  b: number;
  rho: number;
  m: number;
  sigma: number;
}

export const sviW = (p: Svi, k: number): number => p.a + p.b * (p.rho * (k - p.m) + Math.sqrt((k - p.m) ** 2 + p.sigma ** 2));

export interface SmilePoint {
  k: number; // log-moneyness ln(K / S)
  w: number; // total variance σ² τ
  weight: number;
}

/** Minimizes f with Nelder–Mead from x0 (standard coefficients; restarts once from the best point). */
export function nelderMead(f: (x: number[]) => number, x0: number[], opts: { maxIter?: number; step?: number; tol?: number } = {}): number[] {
  const maxIter = opts.maxIter ?? 4000;
  const tol = opts.tol ?? 1e-14;
  let best = x0;
  for (let restart = 0; restart < 2; restart++) {
    const n = best.length;
    let simplex = [best, ...best.map((_, i) => best.map((v, j) => (i === j ? v + (opts.step ?? 0.2) * (Math.abs(v) > 1e-3 ? v : 1) : v)))];
    let values = simplex.map(f);
    for (let it = 0; it < maxIter; it++) {
      const order = values.map((v, i) => [v, i] as const).sort((a, b) => a[0] - b[0]);
      simplex = order.map(([, i]) => simplex[i]!);
      values = order.map(([v]) => v);
      if (Math.abs(values[n]! - values[0]!) <= tol * (Math.abs(values[0]!) + tol)) break;
      const centroid = Array.from({ length: n }, (_, j) => simplex.slice(0, n).reduce((s, x) => s + x[j]!, 0) / n);
      const along = (t: number) => centroid.map((c, j) => c + t * (simplex[n]![j]! - c));
      const reflected = along(-1);
      const fr = f(reflected);
      if (fr < values[0]!) {
        const expanded = along(-2);
        const fe = f(expanded);
        [simplex[n], values[n]] = fe < fr ? [expanded, fe] : [reflected, fr];
      } else if (fr < values[n - 1]!) {
        [simplex[n], values[n]] = [reflected, fr];
      } else {
        const contracted = fr < values[n]! ? along(-0.5) : along(0.5);
        const fc = f(contracted);
        if (fc < Math.min(fr, values[n]!)) {
          [simplex[n], values[n]] = [contracted, fc];
        } else {
          for (let i = 1; i <= n; i++) {
            simplex[i] = simplex[i]!.map((v, j) => simplex[0]![j]! + 0.5 * (v - simplex[0]![j]!));
            values[i] = f(simplex[i]!);
          }
        }
      }
    }
    best = simplex[values.indexOf(Math.min(...values))]!;
  }
  return best;
}

const toSvi = (x: number[]): Svi => ({ a: x[0]!, b: Math.exp(x[1]!), rho: Math.tanh(x[2]!), m: x[3]!, sigma: Math.exp(x[4]!) });

/** Fits one expiry's smile. Needs ≥ 5 points to determine the 5 parameters. */
export function fitSvi(points: readonly SmilePoint[]): { params: Svi; rmse: number } {
  if (points.length < 5) throw new Error(`SVI needs at least 5 quotes, got ${points.length}`);
  const wAtm = points.reduce((best, p) => (Math.abs(p.k) < Math.abs(best.k) ? p : best)).w;
  const wsum = points.reduce((s, p) => s + p.weight, 0);
  const objective = (x: number[]) => {
    const p = toSvi(x);
    let err = 0;
    for (const q of points) err += q.weight * (sviW(p, q.k) - q.w) ** 2;
    const minW = p.a + p.b * p.sigma * Math.sqrt(1 - p.rho ** 2);
    const penalty = minW < 0 ? 1e6 * minW * minW : 0;
    // Roger Lee's moment bound on the wings: b (1 + |ρ|) ≤ 4 (avoids arbitrage at extreme strikes).
    const lee = p.b * (1 + Math.abs(p.rho)) - 4;
    return err / wsum + penalty + (lee > 0 ? 1e6 * lee * lee : 0);
  };
  const x = nelderMead(objective, [wAtm * 0.5, Math.log(Math.max(wAtm, 1e-4)), -0.3, 0, Math.log(0.2)]);
  const params = toSvi(x);
  const rmse = Math.sqrt(points.reduce((s, q) => s + q.weight * (sviW(params, q.k) - q.w) ** 2, 0) / wsum);
  return { params, rmse };
}

/**
 * Butterfly-arbitrage check for the surface the contract evaluates: total variance linear in k between nodes
 * (MATH.md §5). Density ≥ 0 needs (a) no concave kink at an interior node (w' non-decreasing) and (b) Durrleman's
 * g(k) = (1 − k w' / (2w))² − (w'² / 4)(1/w + 1/4) ≥ 0 along every segment (w'' = 0 there). Returns violations.
 */
export function butterflyViolations(kNodes: readonly number[], w: readonly number[], tolerance = 1e-12): string[] {
  const out: string[] = [];
  const slope = (j: number) => (w[j + 1]! - w[j]!) / (kNodes[j + 1]! - kNodes[j]!);
  for (let j = 1; j < kNodes.length - 1; j++) {
    if (slope(j) < slope(j - 1) - tolerance) out.push(`concave kink at node ${j} (k=${kNodes[j]!.toFixed(4)})`);
  }
  for (let j = 0; j < kNodes.length - 1; j++) {
    const d = slope(j);
    for (let s = 0; s <= 20; s++) {
      const k = kNodes[j]! + ((kNodes[j + 1]! - kNodes[j]!) * s) / 20;
      const wk = w[j]! + d * (k - kNodes[j]!);
      if (wk <= 0) {
        out.push(`non-positive variance on segment ${j}`);
        break;
      }
      const g = (1 - (k * d) / (2 * wk)) ** 2 - ((d * d) / 4) * (1 / wk + 0.25);
      if (g < -tolerance) {
        out.push(`negative density on segment ${j} at k=${k.toFixed(4)} (g=${g.toExponential(2)})`);
        break;
      }
    }
  }
  return out;
}
