import Link from "next/link";
import type { ReactNode } from "react";
import { cva } from "class-variance-authority";

import { IncompleteDataNotice } from "@/features/reports/components/incomplete-data-notice";

/* StatTile — one figure on OW 08, and a way into the rows behind it (DESIGN-CONTRACTS StatTile,
 * DashboardGrid; ^ref-58 acceptance).
 *
 * `href` IS REQUIRED. Every tile is reconcilable to source records (M12); a figure with no
 * drill-down path does not belong on the grid, so a tile without one does not compile.
 *
 * ZERO AND NEGATIVE ARE DISTINCT STATES: zero is muted, negative is `--color-danger` with a
 * minus sign (the caller formats it; never parentheses). The value wraps and never shrinks or
 * truncates, so −999,999.99 at 360px grows the tile instead.
 *
 * AT MOST ONE NOTE (the contract). `incomplete` replaces the value with IncompleteDataNotice.
 *
 * Size: min-height 96px. The contract's 40px `num-display` is `text-display` here — the largest
 * numeric step tokens.css defines.
 */

const tile = cva(
  "flex min-h-24 flex-col gap-2 rounded-lg border p-4 hover:border-border-strong " +
    "focus-visible:outline-2 focus-visible:outline-focus-ring",
  {
    variants: {
      tone: {
        neutral: "border-border bg-surface",
        success: "border-success bg-success-subtle",
        warning: "border-warning bg-warning-subtle",
        danger: "border-danger bg-danger-subtle",
      },
    },
    defaultVariants: { tone: "neutral" },
  },
);

const figure = cva("text-display break-words tabular-nums", {
  variants: {
    sign: {
      positive: "text-text-primary",
      zero: "text-text-muted",
      negative: "text-danger",
    },
  },
  defaultVariants: { sign: "positive" },
});

export type StatTileProps = {
  label: string;
  value: string;
  unit?: string;
  sign?: "positive" | "zero" | "negative";
  tone?: "neutral" | "success" | "warning" | "danger";
  href: string;
  note?: ReactNode;
  incomplete?: { figure: string; missing: string[] };
};

export function StatTile({
  label,
  value,
  unit,
  sign,
  tone,
  href,
  note,
  incomplete,
}: StatTileProps) {
  return (
    <Link href={href} className={tile({ tone })}>
      <span className="text-label text-text-secondary">{label}</span>
      {incomplete ? (
        <IncompleteDataNotice
          figure={incomplete.figure}
          missing={incomplete.missing}
        />
      ) : (
        <span className={figure({ sign })}>
          {value}
          {unit ? (
            <span className="text-body text-text-secondary"> {unit}</span>
          ) : null}
        </span>
      )}
      {note}
    </Link>
  );
}
