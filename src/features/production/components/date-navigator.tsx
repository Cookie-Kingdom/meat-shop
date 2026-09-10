import Link from "next/link";
import { ChevronLeft, ChevronRight } from "lucide-react";

/* DateNavigator (DESIGN-CONTRACTS): previous / DateInput / next, sticky at the top of CM 04 so
 * the operator never loses which day they are editing, keyboard open or not (S2, REVIEW 7).
 * The date lives in the URL — the page reads that day's log — so this is a GET form and two
 * links, and ships no client JavaScript. `event_date` is user-settable and defaults to today;
 * a future day is not offered (ADR-007). */

/** `yyyy-mm-dd` ± whole days, in UTC so no timezone can move the date. */
function shift(iso: string, days: number): string {
  const [y, m, d] = iso.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

const arrow =
  "inline-flex size-11 shrink-0 items-center justify-center rounded-md border border-border bg-surface text-text-primary hover:bg-surface-sunken";

export function DateNavigator({
  path,
  date,
  today,
}: {
  path: string;
  date: string;
  today: string;
}) {
  const next = shift(date, 1);
  return (
    <div className="sticky top-0 z-10 -mx-4 flex items-center gap-2 border-b border-border bg-surface px-4 py-1 md:-mx-6 md:px-6">
      <Link
        href={`${path}?date=${shift(date, -1)}`}
        aria-label="วันก่อนหน้า"
        className={arrow}
      >
        <ChevronLeft aria-hidden className="size-5" />
      </Link>
      <form
        method="get"
        action={path}
        className="flex min-w-0 flex-1 items-center gap-2"
      >
        <input
          type="date"
          name="date"
          defaultValue={date}
          max={today}
          aria-label="วันที่รมควัน"
          className="h-11 min-w-0 flex-1 rounded-md border border-border bg-surface px-2 font-mono text-num-md text-text-primary focus-visible:outline-2 focus-visible:outline-focus-ring"
        />
        <button
          type="submit"
          className="h-11 shrink-0 rounded-md border border-border px-3 text-label text-accent hover:bg-surface-sunken"
        >
          {date === today ? "วันนี้" : "ไป"}
        </button>
      </form>
      {next <= today ? (
        <Link
          href={`${path}?date=${next}`}
          aria-label="วันถัดไป"
          className={arrow}
        >
          <ChevronRight aria-hidden className="size-5" />
        </Link>
      ) : (
        <span aria-hidden className="size-11 shrink-0" />
      )}
    </div>
  );
}
