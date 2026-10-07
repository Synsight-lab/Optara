/** Fixed point helpers (WAD = 1e18) and the surface lookups of `OptionPricer` (MATH.md §5). */

export const WAD = 10n ** 18n;
export const YEAR = 365n * 24n * 3600n; // FixedPoint.YEAR

/** A float as WAD, rounded to the nearest unit. Use only for off-chain values that are then signed or compared. */
export function toWad(x: number): bigint {
  if (!Number.isFinite(x)) throw new Error(`not finite: ${x}`);
  // 1e18 exceeds 2^53: scale through 1e9 twice to keep 15+ significant digits.
  const hi = Math.trunc(x);
  const lo = x - hi;
  return BigInt(hi) * WAD + BigInt(Math.round(lo * 1e9)) * 10n ** 9n;
}

export const fromWad = (x: bigint): number => Number(x) / 1e18;

/** ln(strike / spot) as a float. The contract's `lnWad` agrees to ~1e-18; callers add node margins for that. */
export const logMoneyness = (strikeWad: bigint, spotWad: bigint): number => Math.log(Number(strikeWad) / Number(spotWad));

/** `OptionPricer.findTenors`: tenors a ≤ b bracketing the expiry, or undefined if outside the reported tenors. */
export function findTenors(tenors: readonly bigint[], expiry: bigint): [number, number] | undefined {
  let n = 0;
  while (n < 4 && n < tenors.length && tenors[n] !== 0n) n++;
  if (n === 0 || expiry < tenors[0]! || expiry > tenors[n - 1]!) return undefined;
  for (let i = 0; ; i++) {
    if (tenors[i] === expiry) return [i, i];
    if (tenors[i]! > expiry) return [i - 1, i];
  }
}

/** `OptionPricer.findNodes` on a float log-moneyness against WAD nodes. */
export function findNodes(kNodes: readonly bigint[], k: number): [number, number] {
  const m = kNodes.length;
  if (m === 0) throw new Error("empty grid");
  const kw = toWad(k);
  if (kw <= kNodes[0]!) return [0, 0];
  if (kw >= kNodes[m - 1]!) return [m - 1, m - 1];
  for (let j = 0; ; j++) {
    if (kw <= kNodes[j + 1]!) return kw === kNodes[j + 1] ? [j + 1, j + 1] : [j, j + 1];
  }
}

/** σ = sqrt(w / τ) with τ in years (floats). */
export const ivFromTotalVariance = (w: number, tauYears: number): number => Math.sqrt(w / tauYears);
export const totalVarianceFromIv = (iv: number, tauYears: number): number => iv * iv * tauYears;
export const yearsBetween = (from: bigint, to: bigint): number => Number(to - from) / Number(YEAR);
