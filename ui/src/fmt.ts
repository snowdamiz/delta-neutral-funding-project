// Fixed-point helpers for the read API's {atoms, scale} money/quantity contract.
// Atoms are u64/u128 decimal strings and routinely exceed Number.MAX_SAFE_INTEGER,
// so every conversion goes through BigInt and never through parseFloat.

export type Fixed = { atoms: string; scale: number };

/** Exact decimal string for a {atoms, scale} pair. No rounding, no grouping. */
export function toDecimalString(fp: Fixed | null | undefined): string | null {
  if (!fp || fp.atoms == null) return null;
  return place(BigInt(fp.atoms), Number(fp.scale ?? 0));
}

/** Round a {atoms, scale} pair to `dp` decimals, half away from zero. */
export function round(fp: Fixed | null | undefined, dp: number): string | null {
  if (!fp || fp.atoms == null) return null;
  const scale = Number(fp.scale ?? 0);
  let v = BigInt(fp.atoms);
  const neg = v < 0n;
  if (neg) v = -v;

  if (dp >= scale) {
    v *= 10n ** BigInt(dp - scale);
  } else {
    const div = 10n ** BigInt(scale - dp);
    const rem = v % div;
    v /= div;
    if (rem * 2n >= div) v += 1n; // half away from zero
  }
  return place(neg ? -v : v, dp);
}

/** Human display: rounded to `dp`, thousands-grouped. `+12,345.67` when signed. */
export function fmt(
  fp: Fixed | null | undefined,
  dp = 2,
  opts: { signed?: boolean } = {},
): string {
  const s = round(fp, dp);
  if (s === null) return "—";
  const neg = s.startsWith("-");
  const [int = "", frac] = (neg ? s.slice(1) : s).split(".");
  const grouped = int.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const sign = neg ? "-" : opts.signed ? "+" : "";
  return sign + grouped + (frac ? "." + frac : "");
}

/** Numeric value of a fixed-point pair. Display/statistics only — never money math. */
export function toNumber(fp: Fixed | null | undefined): number {
  const s = toDecimalString(fp);
  return s === null ? 0 : Number(s);
}

/** Place a decimal point `scale` digits from the right of a BigInt. */
function place(v: bigint, scale: number): string {
  const neg = v < 0n;
  let digits = (neg ? -v : v).toString();
  if (scale > 0) {
    digits = digits.padStart(scale + 1, "0");
    digits = digits.slice(0, -scale) + "." + digits.slice(-scale);
  }
  return (neg ? "-" : "") + digits;
}

/** Compact age string from a millisecond count. */
export function age(ms: string | number | null | undefined): string {
  const n = Number(ms);
  if (!Number.isFinite(n)) return "—";
  const s = Math.floor(n / 1000);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
}

export const num = (v: unknown): string =>
  v == null ? "—" : Number(v).toLocaleString("en-US");

export const clock = (ts: string | number | null | undefined): string =>
  ts ? new Date(ts).toLocaleTimeString("en-GB", { hour12: false }) : "—";

/** Strip the deployment prefix so run ids read as `jitosol-carry`, not `local-jitosol-carry`. */
export const shortId = (s: string | null | undefined): string =>
  String(s ?? "").replace(/^local-/, "");
