import type { ComponentProps } from "react";
import { cva } from "class-variance-authority";

import { cn } from "@/lib/utils";

/* WeightField, MoneyField and PercentField — `design/DESIGN-CONTRACTS.md` → `WeightField`,
 * `MoneyField`. Shared because OW 01 and OW 02 both enter kilograms and baht: two screens in
 * lane F, which is the promotion rule in PARALLEL-LANES.md.
 *
 * A TEXT INPUT WITH inputMode="decimal", NOT type="number". type="number" drops a trailing
 * zero, accepts "1e3", and on some Android keyboards in a Thai locale has no decimal key at
 * all. The string typed is what gets posted, and the server parses it exactly
 * (`toHundredths`, src/lib/format/number.ts). Thousands separators are never inserted into
 * the value — display only (MoneyField worst case).
 *
 * Sizes from the contract: WeightField is 56px (`h-14`, --h-row) with the value at `num-lg`.
 * MoneyField and PercentField are 48px (`h-12`, --tap-write) at `num-md`. The contract allows
 * exactly one WeightField per screen at 56px, and that is the caller's job to keep.
 *
 * ABSENT IS A SECURITY STATE (MoneyField contract, BR15). These components are rendered only
 * in `(owner)` trees. An L3 route must not import MoneyField at all — not disabled, not
 * blurred, because a disabled field still ships its value to the client.
 *
 * Works in both a Server Component (defaultValue) and a client one (value/onChange). There is
 * no state here, so there is no "use client" either.
 */

const frame = cva(
  "flex items-center gap-2 rounded-md border px-3 focus-within:outline-2 focus-within:outline-focus-ring",
  {
    variants: {
      size: {
        weight: "h-14",
        money: "h-12",
      },
      invalid: {
        true: "border-danger",
        false: "border-border focus-within:border-focus-ring",
      },
      readOnly: {
        true: "bg-surface-sunken",
        false: "bg-surface",
      },
    },
    defaultVariants: { size: "weight", invalid: false, readOnly: false },
  },
);

const valueText = cva(
  "w-full min-w-0 bg-transparent text-right text-text-primary tabular-nums outline-none",
  {
    variants: {
      size: {
        weight: "text-num-lg",
        money: "text-num-md",
      },
    },
    defaultVariants: { size: "weight" },
  },
);

type FieldProps = Omit<ComponentProps<"input">, "type" | "size" | "inputMode"> & {
  label: string;
  /** Helper or ceiling text, shown before the user hits it — e.g. `ส่งได้อีกไม่เกิน 30.00 กก.`. */
  hint?: string;
  /** Replaces the hint and marks the field. */
  error?: string;
};

function DecimalField({
  size,
  unit,
  label,
  hint,
  error,
  readOnly,
  className,
  ...input
}: FieldProps & { size: "weight" | "money"; unit: string }) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-label text-text-secondary">{label}</span>
      <span
        className={frame({
          size,
          invalid: Boolean(error),
          readOnly: Boolean(readOnly),
        })}
      >
        <input
          type="text"
          inputMode="decimal"
          autoComplete="off"
          readOnly={readOnly}
          aria-invalid={error ? true : undefined}
          className={cn(valueText({ size }), className)}
          {...input}
        />
        <span className="shrink-0 text-body text-text-secondary">{unit}</span>
      </span>
      {error ? (
        <span className="text-caption text-danger">{error}</span>
      ) : hint ? (
        <span className="text-caption text-text-muted">{hint}</span>
      ) : null}
    </label>
  );
}

export function WeightField(props: FieldProps) {
  return <DecimalField {...props} size="weight" unit="กก." />;
}

export function MoneyField(props: FieldProps) {
  return <DecimalField {...props} size="money" unit="บาท" />;
}

/** A stored percentage: 10.00 means 10% (CLAUDE.md), never 0.10. */
export function PercentField(props: FieldProps) {
  return <DecimalField {...props} size="money" unit="%" />;
}
