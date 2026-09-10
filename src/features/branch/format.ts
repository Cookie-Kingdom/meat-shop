/* Kg on the branch screens: two decimals, Thai grouping (numeric(12,2) in the DB, BR21).
 *
 * DISPLAY ONLY. Nothing here adds, subtracts or sums a weight — every figure a branch screen
 * shows is a column a view already computed (TDD-thaw.md, "nothing computes a balance in
 * TypeScript"). Kept in the feature rather than `src/lib/format/` on 10 Sep so two parallel
 * lanes do not each create a `lib/format/kg.ts`; promote it once a second feature needs it. */

const KG = new Intl.NumberFormat("th-TH", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

export function formatKg(value: number | string | null | undefined): string {
  if (value === null || value === undefined || value === "") return "—";
  const n = Number(value);
  return Number.isFinite(n) ? KG.format(n) : String(value);
}
