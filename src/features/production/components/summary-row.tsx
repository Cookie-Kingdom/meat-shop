import { cva } from "class-variance-authority";

/* SummaryRow (DESIGN-CONTRACTS): label left at no more than 60% of the row, value right,
 * monospace and tabular. A missing value renders as an em dash with the reason beside it —
 * never as 0.00 (REVIEW 11, 17). */

const value = cva("text-right font-mono tabular-nums", {
  variants: {
    emphasis: {
      normal: "text-num-md text-text-primary",
      strong: "text-num-lg text-text-primary",
    },
  },
  defaultVariants: { emphasis: "normal" },
});

export function SummaryRow({
  label,
  value: shown,
  unit,
  emphasis,
  missing,
}: {
  label: string;
  /** Already formatted (`12.34`), or null when there is nothing to show. */
  value: string | null;
  unit?: string;
  emphasis?: "normal" | "strong";
  /** Why the value is missing, shown in its place. */
  missing?: string;
}) {
  return (
    <div className="flex min-h-11 items-center justify-between gap-3 border-b border-border py-2 last:border-b-0">
      <dt className="max-w-3/5 text-body-sm text-text-secondary">{label}</dt>
      <dd className="flex items-baseline gap-1">
        {shown === null ? (
          <span className="text-body-sm text-text-muted">
            —{missing ? ` ${missing}` : ""}
          </span>
        ) : (
          <>
            <span className={value({ emphasis })}>{shown}</span>
            {unit ? (
              <span className="text-caption text-text-secondary">{unit}</span>
            ) : null}
          </>
        )}
      </dd>
    </div>
  );
}
