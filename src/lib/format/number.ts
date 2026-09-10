/* kg / THB / % to exactly two decimals (CLAUDE.md: money and weight are numeric(12,2) in
 * the database and are shown to 2 decimals in the UI).
 *
 * TWO HALVES, AND ONLY THE SECOND ONE DOES ARITHMETIC.
 *
 * 1. Display — `kg()`, `thb()`, `pct()`. The value came from the database, which already
 *    computed it. These only print it.
 *
 * 2. Exact hundredths — `toHundredths()` and friends, as bigint. They exist for the figures
 *    a screen must show BEFORE the database has computed them: OW 01's PO total
 *    (PurchaseOrderForm, `computing` state) and OW 02's per-lot freight split (TransportForm:
 *    "shown per lot before submit"), plus the live variance a receipt shows. A JS `number`
 *    doing that arithmetic is how 0.1 + 0.2 reaches a receipt, so the preview works in integer
 *    satang and centi-kilograms and rounds half-up. That is what numeric round() does for the
 *    non-negative values these screens handle. The database's figure is still the one saved,
 *    and the screens say so.
 *
 * BigInt() calls rather than `100n` literals: the literals need an ES2020 target, and this
 * file must not be the reason the tsconfig target moves.
 */

const TWO_DP = new Intl.NumberFormat("th-TH", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

type Num = number | string | null | undefined;

function blank(value: Num): value is null | undefined | "" {
  return value === null || value === undefined || value === "";
}

/** A stored figure to two decimals with thousands separators. "—" when there is none: a
 * missing value is not zero, and printing 0.00 for it is the lie BR23 exists to prevent. */
export function dp2(value: Num): string {
  if (blank(value)) return "—";
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) ? TWO_DP.format(n) : "—";
}

export function kg(value: Num): string {
  return blank(value) ? "—" : `${dp2(value)} กก.`;
}

export function thb(value: Num): string {
  return blank(value) ? "—" : `${dp2(value)} บาท`;
}

/** Percentages are stored as 20.00 meaning 20% (CLAUDE.md), so this never multiplies. */
export function pct(value: Num): string {
  return blank(value) ? "—" : `${dp2(value)}%`;
}

// ─── Exact hundredths ────────────────────────────────────────────────────────────────

const HUNDRED = BigInt(100);
const TWO = BigInt(2);

/** What a person typed, as hundredths: "1,234.5" → 123450. Null for anything that is not a
 * non-negative decimal with at most two places. A third decimal is refused, not rounded:
 * numeric(12,2) would round it away silently, and the weight typed is the weight meant. */
export function toHundredths(input: string): bigint | null {
  const s = input.replace(/,/g, "").trim();
  const m = /^(\d*)(?:\.(\d{0,2}))?$/.exec(s);
  if (!m) return null;
  const whole = m[1];
  const frac = m[2] ?? "";
  if (whole === "" && frac === "") return null;
  return BigInt(whole || "0") * HUNDRED + BigInt(frac.padEnd(2, "0"));
}

/** Hundredths back to "1,234.50" — display only. */
export function fromHundredths(h: bigint): string {
  const negative = h < BigInt(0);
  const abs = negative ? -h : h;
  const whole = (abs / HUNDRED).toLocaleString("th-TH");
  const frac = (abs % HUNDRED).toString().padStart(2, "0");
  return `${negative ? "-" : ""}${whole}.${frac}`;
}

/** Hundredths as the plain decimal string a form posts and an RPC takes: 123450 → "1234.50". */
export function hundredthsToDecimal(h: bigint): string {
  return fromHundredths(h).replace(/,/g, "");
}

/** round(n / d), half away from zero, for n ≥ 0 and d > 0 — numeric round()'s answer. */
export function divRound(n: bigint, d: bigint): bigint {
  return (n * TWO + d) / (TWO * d);
}

/** |actual − expected| / expected × 100 in hundredths of a percent, rounded to 2 places —
 * ADR-019's formula, the one fn_check_variance computes. Null when expected is zero: that is
 * the explicit zero-expected branch (a reason is required and no percentage is shown), never
 * a division. */
export function variancePctHundredths(
  actual: bigint,
  expected: bigint,
): bigint | null {
  if (expected === BigInt(0)) return null;
  const diff = actual > expected ? actual - expected : expected - actual;
  return divRound(diff * BigInt(10000), expected);
}
