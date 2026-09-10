import { cva } from "class-variance-authority";

/* The two lot states OW 05's queue can show (card ^ref-37). A slice of `LotStateBadge`
 * (DESIGN-CONTRACTS.md), scoped to what `v_lot_return_pending` returns. The full 11-state
 * badge belongs to the screens that show all eleven.
 *
 * The contract's `RETURN_PENDING` is not a `lot_state` value. The enum has `LOT_CLOSED`, and a
 * closed lot with no pickup date is exactly what that contract row describes (BR17). An
 * unknown value renders neutral with the raw identifier, per the contract: a schema drift is
 * caught in review, not shown as an empty chip. */

const badge = cva(
  "inline-flex h-7 shrink-0 items-center rounded-full px-3 text-caption font-medium",
  {
    variants: {
      tone: {
        warning: "bg-warning-subtle text-warning",
        accent: "bg-accent-subtle text-accent",
        neutral: "bg-surface-sunken text-text-secondary",
      },
    },
    defaultVariants: { tone: "neutral" },
  },
);

const STATES: Record<string, { label: string; tone: "warning" | "accent" }> = {
  LOT_CLOSED: { label: "รอกำหนดวันรับ", tone: "warning" },
  RETURN_SCHEDULED: { label: "นัดวันรับแล้ว", tone: "accent" },
};

export function ReturnStateBadge({ state }: { state: string }) {
  const known = STATES[state];
  return (
    <span className={badge({ tone: known?.tone })}>
      {known?.label ?? state}
    </span>
  );
}
