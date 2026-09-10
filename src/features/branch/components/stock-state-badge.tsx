import { cva } from "class-variance-authority";

import { formatKg } from "../format";

/* StockStateBadge — frozen or ready weight (DESIGN-CONTRACTS.md `StockStateBadge`).
 *
 * TWO STATES, NEVER SUMMED (BR19). A screen that shows both shows two badges — 7.00 แช่แข็ง and
 * 3.00 พร้อมขาย after a 3.00 thaw of 10.00 — so the operator can see nothing was deducted twice.
 * Frozen takes the cool accent, ready takes success. */

const badge = cva(
  "inline-flex items-baseline gap-1 whitespace-nowrap rounded-md border px-2 tabular-nums",
  {
    variants: {
      state: {
        frozen: "border-accent bg-accent-subtle text-accent",
        ready: "border-success bg-success-subtle text-success",
      },
      size: {
        sm: "py-0.5 text-num-sm",
        md: "py-1 text-num-md",
      },
    },
    defaultVariants: { size: "md" },
  },
);

const LABEL = { frozen: "แช่แข็ง", ready: "พร้อมขาย" } as const;

export function StockStateBadge({
  state,
  weightKg,
  size,
}: {
  state: "frozen" | "ready";
  weightKg: number | string;
  size?: "sm" | "md";
}) {
  return (
    <span className={badge({ state, size })}>
      <span>{formatKg(weightKg)}</span>
      <span className="text-caption">{LABEL[state]}</span>
    </span>
  );
}
