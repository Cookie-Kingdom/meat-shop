import type { ReactNode } from "react";

import { cn } from "@/lib/utils";

/* S4's SummaryRow (design/LAYOUT-SKELETONS.md): label left at most 60% wide, value right,
 * tabular and right-aligned. The `trace` line under it is F13 — it names the inputs and the
 * source record the figure came from, so no number on these screens stands alone. */

export function SummaryRow({
  label,
  value,
  trace,
  emphasis = false,
}: {
  label: string;
  value: string;
  trace?: ReactNode;
  emphasis?: boolean;
}) {
  return (
    <div className="flex flex-col gap-0.5 border-b border-border py-3 last:border-b-0">
      <div className="flex items-baseline justify-between gap-3">
        <span className="max-w-[60%] text-body text-text-secondary">
          {label}
        </span>
        <span
          className={cn(
            "text-right text-text-primary tabular-nums",
            emphasis ? "text-num-md" : "text-body",
          )}
        >
          {value}
        </span>
      </div>
      {trace ? <p className="text-caption text-text-muted">{trace}</p> : null}
    </div>
  );
}
