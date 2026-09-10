import Link from "next/link";
import { cva } from "class-variance-authority";

import { thaiDate } from "@/lib/format/date";
import { formatKg } from "../format";

/* SmokeDateChip — one chip per smoke DATE on BR 05 (DESIGN-CONTRACTS.md `SmokeDateChip`).
 *
 * FIFO IS BY DATE (v0.2:92, :188; PLAN-thaw.md Finding 3). The oldest date is highlighted and
 * marked เก่าที่สุด — a highlight, not a lock: picking a later date is allowed and brings up the
 * reason field. The lots inside a date are listed after it and are a choice, not a ranking.
 *
 * A link, not a button: choosing a date is a navigation (`?sd=`), so the page renders that
 * date's lots server-side with no client JavaScript.
 *
 * Deviation from the contract, recorded in PLAN-thaw.md: no bag count (v_branch_frozen_available
 * carries none), and the kg is shown only when the date holds ONE lot. A per-date total would be
 * a sum in TypeScript; each lot's kg is in the list below, straight from the view. */

const chip = cva(
  "flex min-h-14 w-full flex-col justify-center rounded-lg border px-4 py-2 text-left",
  {
    variants: {
      oldest: { true: "bg-accent-subtle", false: "bg-surface" },
      selected: {
        true: "border-accent outline-2 outline-accent",
        false: "border-border",
      },
    },
    defaultVariants: { oldest: false, selected: false },
  },
);

export function SmokeDateChip({
  smokeDate,
  lotCount,
  singleLotKg,
  isOldest,
  selected,
  href,
}: {
  smokeDate: string;
  lotCount: number;
  /** The one lot's available kg, when the date holds exactly one lot. */
  singleLotKg: number | null;
  isOldest: boolean;
  selected: boolean;
  href: string;
}) {
  return (
    <Link
      href={href}
      aria-current={selected ? "true" : undefined}
      className={chip({ oldest: isOldest, selected })}
    >
      <span className="flex items-center justify-between gap-2">
        <span className="text-body text-text-primary">
          รมควัน {thaiDate(smokeDate)}
        </span>
        {isOldest ? (
          <span className="rounded-md bg-accent px-2 text-caption text-accent-fg">
            เก่าที่สุด
          </span>
        ) : null}
      </span>
      <span className="text-caption text-text-secondary tabular-nums">
        {singleLotKg !== null
          ? `${formatKg(singleLotKg)} กก. แช่แข็ง · 1 ล็อต`
          : `${lotCount} ล็อต — เลือกล็อตด้านล่าง`}
      </span>
    </Link>
  );
}
