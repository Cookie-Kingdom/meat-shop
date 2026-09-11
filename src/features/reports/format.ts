import { divRound, fromHundredths } from "@/lib/format/number";
import type { Num } from "@/features/reports/types";

/* Range totals for OW 08, in exact hundredths.
 *
 * WHY THE SCREEN ADDS AT ALL. A view cannot take a date range, and every per-row figure is the
 * database's (220, 230, 010). What the tiles show is the sum of the rows in the Owner's chosen
 * range. Those sums are done here in integer satang / centi-kilograms (bigint), never in a JS
 * float, so 0.1 + 0.2 never reaches a tile. A numeric(12,2) value is below 10^10, so value × 100
 * is below 2^53 and Math.round recovers its hundredths exactly.
 *
 * ponytail: client-side range sums over rows already read. Upgrade path, if ranges get long
 * enough to matter: PostgREST aggregates (`select=revenue_thb.sum()`) once they are enabled.
 */

const ZERO = BigInt(0);

/** A stored two-decimal figure as hundredths. Null (unknown) stays null. */
export function toCents(value: Num): bigint | null {
  if (value === null || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? BigInt(Math.round(n * 100)) : null;
}

/** Σ of known values, in hundredths. Callers decide what an unknown means before summing. */
export function sumCents(values: Num[]): bigint {
  return values.reduce<bigint>((s, v) => s + (toCents(v) ?? ZERO), ZERO);
}

/** Σ numerator / Σ denominator × 100, to two places, in hundredths of a percent — the weighted
 * form ADR-011 requires for Loss over several lots. Null when the denominator is zero. */
export function ratioPctCents(num: bigint, den: bigint): bigint | null {
  if (den === ZERO) return null;
  return divRound(num * BigInt(10000), den);
}

/** Hundredths as a signed display figure: a minus sign, never parentheses (StatTile). */
export function signedDp2(cents: bigint): string {
  return fromHundredths(cents).replace(/^-/, "−");
}

export function signOf(cents: bigint): "positive" | "zero" | "negative" {
  return cents === ZERO ? "zero" : cents < ZERO ? "negative" : "positive";
}

/** A `yyyy-mm-dd` search param, or the fallback when it is absent or malformed. */
export function isoDateOr(value: string, fallback: string): string {
  return /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : fallback;
}

export function unique(values: string[]): string[] {
  return [...new Set(values)];
}

/** Consecutive items grouped into at most `max` buckets, in order (S7: the chart downsamples;
 * 365 points never render at 360px). */
export function buckets<T>(items: T[], max: number): T[][] {
  const size = Math.max(1, Math.ceil(items.length / max));
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size)
    out.push(items.slice(i, i + size));
  return out;
}
