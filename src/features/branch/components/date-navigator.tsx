import Link from "next/link";

import { control } from "@/components/ui/controls";
import { cn } from "@/lib/utils";

/* DateNavigator — the day a branch screen is looking at (DESIGN-CONTRACTS.md `DateNavigator`).
 *
 * A GET form with a date input and two links: no client JavaScript (PLAN-thaw.md T9). The URL
 * is the state. Sticky, not fixed, so it stays visible above a form without colliding with
 * anything pinned at the bottom.
 *
 * The page decides the default — the OPEN report's date, not the calendar's (ADR-014, D07) —
 * and passes it in as `value`. `max` is today in Asia/Bangkok: a day in the future is not a day
 * anyone works in, and fn_open_daily_report refuses it anyway. */

const step =
  "inline-flex size-12 shrink-0 items-center justify-center rounded-md border border-border bg-surface text-h3 text-text-primary";

/** `iso` moved by `days`, computed on the UTC calendar so no timezone can shift it. */
function shift(iso: string, days: number): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function DateNavigator({
  value,
  max,
  basePath,
  params,
}: {
  value: string;
  max: string;
  basePath: string;
  /** Carried through every navigation, e.g. `{ location }`. */
  params: Record<string, string>;
}) {
  const href = (date: string) =>
    `${basePath}?${new URLSearchParams({ ...params, date }).toString()}`;
  const next = shift(value, 1);

  return (
    <div className="sticky top-0 z-10 -mx-4 flex items-center gap-2 border-b border-border bg-bg px-4 py-2 md:-mx-6 md:px-6">
      <Link href={href(shift(value, -1))} className={step} aria-label="วันก่อนหน้า">
        ‹
      </Link>
      <form method="get" action={basePath} className="flex min-w-0 flex-1 gap-2">
        {Object.entries(params).map(([k, v]) => (
          <input key={k} type="hidden" name={k} value={v} />
        ))}
        <input
          type="date"
          name="date"
          defaultValue={value}
          max={max}
          aria-label="วันที่"
          className={cn(control, "h-12 min-w-0 flex-1")}
        />
        <button type="submit" className={cn(step, "w-auto px-3 text-label")}>
          ไป
        </button>
      </form>
      {next <= max ? (
        <Link href={href(next)} className={step} aria-label="วันถัดไป">
          ›
        </Link>
      ) : (
        <span aria-disabled className={cn(step, "text-text-muted opacity-50")}>
          ›
        </span>
      )}
    </div>
  );
}
