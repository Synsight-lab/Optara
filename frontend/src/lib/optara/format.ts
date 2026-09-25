/** Formatting and parsing of the protocol's fixed-point units (MATH.md section 5). Display only. */

export const WAD = 10n ** 18n;

/** Decimal string of an integer scaled by 10^decimals, trailing zeros trimmed. */
export function formatUnitsTrim(value: bigint, decimals: number, maxFraction = decimals): string {
  const negative = value < 0n;
  const v = negative ? -value : value;
  const base = 10n ** BigInt(decimals);
  const int = v / base;
  let frac = (v % base).toString().padStart(decimals, "0").slice(0, maxFraction).replace(/0+$/, "");
  const s = frac.length ? `${int}.${frac}` : `${int}`;
  return negative ? `-${s}` : s;
}

export const formatWad = (v: bigint, maxFraction = 6): string => formatUnitsTrim(v, 18, maxFraction);

/** Parses a user-entered decimal into integer units; rejects more precision than the token supports. */
export function parseUnitsStrict(input: string, decimals: number): bigint {
  const s = input.trim();
  if (!/^\d+(\.\d+)?$/.test(s)) throw new Error("enter a positive decimal number");
  const [int, frac = ""] = s.split(".") as [string, string?];
  if (frac.length > decimals) throw new Error(`at most ${decimals} decimal places`);
  return BigInt(int) * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, "0") || "0");
}

export function formatExpiry(expiry: bigint | number): string {
  return new Date(Number(expiry) * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC";
}

export function shortHex(h: string, n = 6): string {
  return h.length > 2 * n + 2 ? `${h.slice(0, n + 2)}…${h.slice(-n)}` : h;
}
