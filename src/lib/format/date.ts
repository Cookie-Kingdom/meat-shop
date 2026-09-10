/* ADR-010 — stored dates are read in Asia/Bangkok, pinned here rather than left to the
 * viewer's browser, and th-TH renders the Buddhist era the Owner actually reads (2569, not
 * 2026). The formatters are built once per module: an Intl formatter is not cheap. */

const THAI_DATE = new Intl.DateTimeFormat("th-TH", {
  timeZone: "Asia/Bangkok",
  dateStyle: "medium",
});

const THAI_DATE_TIME = new Intl.DateTimeFormat("th-TH", {
  timeZone: "Asia/Bangkok",
  dateStyle: "medium",
  timeStyle: "short",
});

const ISO_DATE = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Bangkok",
  dateStyle: "short",
});

export function thaiDate(iso: string): string {
  return THAI_DATE.format(new Date(iso));
}

export function thaiDateTime(iso: string): string {
  return THAI_DATE_TIME.format(new Date(iso));
}

/** Today in Asia/Bangkok as `yyyy-mm-dd`, for a date input's default and min.
 * `toISOString()` would be UTC, which is yesterday between 00:00 and 07:00 Bangkok — and a
 * config row dated a day early resolves a day early (ADR-010, R12). */
export function todayBangkok(): string {
  return ISO_DATE.format(new Date());
}
