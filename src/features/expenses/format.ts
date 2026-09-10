/* OW 09 display helpers (card ^ref-54). Kept in the feature, not `lib/format/`, so this lane
 * does not collide with lane F's `lib/format/number.ts`; the coordinator consolidates at
 * merge.
 *
 * Formatting only. No money arithmetic happens here — the month total comes from the view
 * (repo CLAUDE.md). ADR-010: months read in Asia/Bangkok, th-TH renders the Buddhist era. */

const THB = new Intl.NumberFormat("th-TH", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

const THAI_MONTH = new Intl.DateTimeFormat("th-TH", {
  timeZone: "Asia/Bangkok",
  month: "long",
  year: "numeric",
});

/** Money to 2 decimals. `null` is "—", never 0.00: an absent total is not a zero total. */
export function thb(value: number | null): string {
  return value === null ? "—" : THB.format(value);
}

/** `YYYY-MM`, month 01–12 — the same rule `owner_expenses_month_valid` holds. */
export function isMonth(value: string): boolean {
  return /^\d{4}-(0[1-9]|1[0-2])$/.test(value);
}

/** `2026-09` → `กันยายน 2569`. */
export function thaiMonth(month: string): string {
  return THAI_MONTH.format(new Date(`${month}-01T12:00:00+07:00`));
}

/** `2026-01`, -1 → `2025-12`. Calendar arithmetic for the month links, not money. */
export function shiftMonth(month: string, by: number): string {
  const [y, m] = month.split("-").map(Number);
  const d = new Date(Date.UTC(y, m - 1 + by, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}
