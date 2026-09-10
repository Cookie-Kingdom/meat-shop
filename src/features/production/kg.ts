/* Weights on the CM screens (ADR-008, DESIGN.md decimal rule).
 *
 * THE ARITHMETIC IS INTEGER HUNDREDTHS OF A KILOGRAM, never floats. A running total of sixty
 * pack weights added as JS numbers drifts by a hundredth somewhere around row 40, and the
 * operator is comparing that total against a scale. Every weight the screen adds up is parsed
 * to an integer count of 0.01 kg first, summed, and only turned back into `12.34` to render
 * or to send. The database recomputes every stored total itself; these are previews.
 *
 * ponytail: lives in features/production rather than src/lib/format because eight lanes are
 * writing screens today and two of them inventing `src/lib/format/kg.ts` is an add/add
 * conflict that looks like two features (PARALLEL-LANES). Promote it at merge.
 */

/** The largest weight the UI accepts, in hundredths — 9999.99 kg (DESIGN-CONTRACTS, worst
 * case). A physical bound on the input, not a business number. */
export const MAX_KG_HUNDREDTHS = 999_999;

/** What the operator typed → hundredths, or null when it is not a weight: empty, a stray
 * character, a third decimal, or past 9999.99. `"0"` is 0, a legal weight distinct from empty. */
export function parseKg(raw: string): number | null {
  const s = raw.trim().replace(/,/g, "");
  const m = s.match(/^(\d{1,4})(?:\.(\d{0,2}))?$|^\.(\d{1,2})$/);
  if (!m) return null;
  const whole = Number(m[1] ?? "0");
  const frac = (m[2] ?? m[3] ?? "").padEnd(2, "0");
  const h = whole * 100 + Number(frac);
  return h <= MAX_KG_HUNDREDTHS ? h : null;
}

/** A numeric(12,2) as PostgREST returns it (a JSON number, sometimes a string) → hundredths. */
export function dbKg(v: number | string | null | undefined): number | null {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? Math.round(n * 100) : null;
}

/** Hundredths → the number sent to an RPC. 1234 → 12.34, which JSON prints as `12.34`. */
export function toKgNumber(h: number): number {
  return h / 100;
}

/** Hundredths → `12.34`, always two decimals, a minus sign and never parentheses. */
export function formatHundredths(h: number): string {
  const sign = h < 0 ? "-" : "";
  const abs = Math.abs(h);
  return `${sign}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, "0")}`;
}

/** A stored weight → `12.34`, or an em dash when there is none. Empty is not zero (REVIEW 8). */
export function formatKg(v: number | string | null | undefined): string {
  const h = dbKg(v);
  return h === null ? "—" : formatHundredths(h);
}

/** Keep a text field to what `parseKg` can accept while the operator is still typing — digits,
 * one point, two decimals, four whole digits. Returns the previous value for a rejected key. */
export function acceptKgKeystroke(prev: string, next: string): string {
  const s = next.replace(/,/g, "");
  return /^\d{0,4}(\.\d{0,2})?$/.test(s) ? s : prev;
}
