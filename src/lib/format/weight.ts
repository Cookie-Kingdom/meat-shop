/* Weight, in kilograms, to exactly two decimals (CLAUDE.md — money and weight are
 * numeric(12,2) in the DB and two decimals in the UI).
 *
 * Display and input normalisation only. No arithmetic that the database should do happens
 * here: the one comparison the UI makes (the variance mirror) works in integer hundredths of
 * a kilogram, so 248.50 − 195.20 is 5330 hundredths and never 53.29999999. */

const KG = new Intl.NumberFormat("th-TH", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

/** `12.5` → `12.50`, `1234` → `1,234.00`. A missing value is an em dash, never `0.00` —
 * zero is a real weight (WeightField contract). */
export function kg(value: number | string | null | undefined): string {
  if (value === null || value === undefined || value === "") return "—";
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) ? KG.format(n) : String(value);
}

/** A typed weight → the canonical decimal string an RPC receives, or null when it is not a
 * weight: digits, at most two decimals, thousands commas ignored. numeric(12,2) holds ten
 * integer digits. */
export function parseKg(raw: string): string | null {
  const s = raw.replace(/,/g, "").trim();
  if (!/^\d{1,10}(\.\d{0,2})?$/.test(s)) return null;
  return s.endsWith(".") ? s.slice(0, -1) : s;
}

/** Hundredths of a kilogram as an integer — the exact form the UI compares in. */
export function toHundredths(value: number | string): number {
  if (typeof value === "number") return Math.round(value * 100);
  const [whole, frac = ""] = value.split(".");
  return Number(whole) * 100 + Number((frac + "00").slice(0, 2));
}
