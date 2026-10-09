/** FRONTEND.md §10: WAD values with 2–4 decimals, IV as a percentage, cash in the asset's native decimals. */

export const WAD = 10n ** 18n;

/** Groups the integer part with thin commas: 1234567 → "1,234,567". */
const group = (s: string) => s.replace(/\B(?=(\d{3})+(?!\d))/g, ",");

/** A fixed-point bigint with `decimals` decimals, shown with `dp` decimals (rounded half away from zero). */
export function fmtFixed(x: bigint, decimals: number, dp = 2): string {
  const neg = x < 0n;
  const shown = Math.min(dp, decimals);
  const q = 10n ** BigInt(decimals - shown);
  const v = ((neg ? -x : x) + q / 2n) / q;
  const unit = 10n ** BigInt(shown);
  const frac = (v % unit).toString().padStart(shown, "0");
  return `${neg && v !== 0n ? "−" : ""}${group((v / unit).toString())}${shown > 0 ? `.${frac}` : ""}`;
}

export const fmtWad = (x: bigint, dp = 2) => fmtFixed(x, 18, dp);
/** Below 1: four significant digits (0.02422, 0.001254), never fewer than 2 decimals. */
function fmtSmall(x: number): string {
  if (x === 0) return "0.00";
  // 4 significant digits: MON at $0.024224 reads $0.02422, not $0.0242
  const dp = Math.max(2, Math.min(18, 3 - Math.floor(Math.log10(Math.abs(x)))));
  return x.toFixed(dp).replace(/(\.\d{2,}?)0+$/, "$1");
}

/** An amount per option (premium, bid, ask, mark): 2 decimals from 1 up; small amounts keep 4 significant digits. */
export const fmtPrice = (x: bigint, dp = 2) => (x >= 10n ** 18n || x <= 0n ? fmtWad(x, dp) : fmtSmall(Number(x) / 1e18));

/** A price level (spot, strike, settlement price): whole numbers stay whole, cents shown when present, small prices keep 4 significant digits. */
export function fmtLevel(x: bigint): string {
  if (x > 0n && x < 10n ** 18n) return fmtSmall(Number(x) / 1e18);
  return x % 10n ** 16n === 0n && x % 10n ** 18n === 0n ? fmtWad(x, 0) : fmtWad(x, 2);
}

/** A level given as a plain number, same rules as fmtLevel. */
export function fmtLevelNum(x: number): string {
  if (x > 0 && x < 1) return fmtSmall(x);
  const whole = Math.abs(x - Math.round(x)) < 0.005;
  return x.toLocaleString("en-US", { minimumFractionDigits: whole ? 0 : 2, maximumFractionDigits: whole ? 0 : 2 });
}
export const fmtNative = (x: bigint, decimals: number, dp = 2) => fmtFixed(x, decimals, dp);
export const fmtUsd = (x: bigint, decimals = 6, dp = 2) => `$${fmtFixed(x, decimals, dp)}`;
/** IV (WAD) as a percentage: 0.6e18 → "60.0%". */
export const fmtIv = (sigmaWad: bigint, dp = 1) => `${fmtFixed(sigmaWad * 100n, 18, dp)}%`;
/** Option quantity (18 decimals), trailing zeros trimmed: 1.5e18 → "1.5". */
export function fmtQty(x: bigint): string {
  const s = fmtFixed(x, 18, 4);
  return s.includes(".") ? s.replace(/\.?0+$/, "") : s;
}

/** "1.25" → 1.25 × 10^decimals; undefined when not a valid non-negative number. */
export function parseFixed(input: string, decimals: number): bigint | undefined {
  const s = input.trim().replace(/,/g, "");
  if (!/^\d*\.?\d*$/.test(s) || s === "" || s === ".") return undefined;
  const [i = "0", f = ""] = s.split(".");
  if (f.length > decimals) return undefined;
  return BigInt(i || "0") * 10n ** BigInt(decimals) + BigInt((f + "0".repeat(decimals)).slice(0, decimals) || "0");
}
export const parseQty = (input: string) => parseFixed(input, 18);

export const shortAddr = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
export const shortHex = (h: string) => `${h.slice(0, 8)}…${h.slice(-6)}`;

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
/** Expiry timestamp → "Fri 9 Oct, 08:00 UTC". */
export function fmtExpiry(ts: bigint): string {
  const d = new Date(Number(ts) * 1000);
  const day = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getUTCDay()];
  return `${day} ${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}, ${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")} UTC`;
}
export const fmtExpiryShort = (ts: bigint) => {
  const d = new Date(Number(ts) * 1000);
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`;
};

/** Seconds → "3d 4h", "2h 05m", "45s"; non-positive → "now". */
export function fmtDuration(seconds: bigint | number): string {
  const s = Number(seconds);
  if (s <= 0) return "now";
  const d = Math.floor(s / 86_400);
  const h = Math.floor((s % 86_400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${String(m).padStart(2, "0")}m`;
  if (m > 0) return `${m}m ${String(s % 60).padStart(2, "0")}s`;
  return `${s}s`;
}

export const optionTypeName = (t: number) => (t === 0 ? "Call" : "Put");

/** "ETH 4,500 Call · 9 Oct" — from the series terms, never from the wrapper symbol (§10). */
export function seriesName(s: { underlyingSymbol?: string; strikeWad: bigint; optionType: number; expiry: bigint }): string {
  return `${s.underlyingSymbol ?? ""} ${fmtLevel(s.strikeWad)} ${optionTypeName(s.optionType)} · ${fmtExpiryShort(s.expiry)}`.trim();
}

/** bps → "3.00%". */
export const fmtBps = (bps: bigint | number, dp = 2) => `${(Number(bps) / 100).toFixed(dp)}%`;
