import { cva } from "class-variance-authority";

import {
  acceptKgKeystroke,
  formatHundredths,
  parseKg,
} from "@/features/production/kg";

/* WeightField (DESIGN-CONTRACTS) — "every yield number traces back to a value typed here".
 *
 * A controlled text input with `inputMode="decimal"`: on an S1 screen one value is one
 * submit, so the OS keypad is right (the in-app NumericKeypad is CM 04's, for sixty entries in
 * a row). Keystrokes past two decimals or four whole digits are refused at the input, so a
 * slipped key never becomes a weight.
 *
 * OVER-MAX IS A FIRST-CLASS STATE. With a `max`, the ceiling is printed under the field before
 * the operator reaches it (`ไม่เกิน 98.00 กก.`) and the field is marked the moment it is
 * breached — CM 03's pre-smoke weight against the received weight. The database refuses it
 * again by name (POST_DRAIN_EXCEEDS_RECEIVED); this is the mirror, not the rule.
 *
 * `0.00` is legal and distinct from empty: a lot that produced nothing is a real record. */

const input = cva(
  "w-full rounded-md border bg-surface pr-12 pl-3 font-mono text-text-primary tabular-nums read-only:bg-surface-sunken focus-visible:outline-2 focus-visible:outline-focus-ring",
  {
    variants: {
      size: {
        /** The one primary weight on a screen: 56px at num-lg. */
        primary: "h-14 text-num-lg",
        /** Every other weight: 48px at num-md (still 16px, so iOS does not zoom). */
        secondary: "h-12 text-num-md",
      },
      invalid: {
        true: "border-danger",
        false: "border-border focus-visible:border-focus-ring",
      },
    },
    defaultVariants: { size: "primary", invalid: false },
  },
);

export function WeightField({
  id,
  label,
  value,
  onChange,
  max,
  maxLabel,
  error,
  helper,
  size,
  readOnly,
  autoFocus,
}: {
  id: string;
  label: string;
  value: string;
  onChange: (next: string) => void;
  /** Physical ceiling in hundredths of a kg, e.g. the received weight on CM 03. */
  max?: number | null;
  /** What the ceiling is, in Thai — "น้ำหนักที่รับเข้ามา". */
  maxLabel?: string;
  error?: string | null;
  helper?: string;
  size?: "primary" | "secondary";
  readOnly?: boolean;
  autoFocus?: boolean;
}) {
  const typed = value === "" ? null : parseKg(value);
  const overMax = max != null && typed !== null && typed > max;
  const message =
    error ??
    (overMax
      ? `เกิน${maxLabel ?? "ค่าสูงสุด"} (${formatHundredths(max)} กก.)`
      : null);
  const describedBy = `${id}-note`;

  return (
    <div className="flex flex-col gap-1">
      <label htmlFor={id} className="text-label text-text-secondary">
        {label}
      </label>
      <div className="relative">
        <input
          id={id}
          type="text"
          inputMode="decimal"
          autoComplete="off"
          enterKeyHint="done"
          value={value}
          onChange={(e) => onChange(acceptKgKeystroke(value, e.target.value))}
          readOnly={readOnly}
          autoFocus={autoFocus}
          aria-invalid={message ? true : undefined}
          aria-describedby={describedBy}
          className={input({ size, invalid: Boolean(message) })}
        />
        <span className="pointer-events-none absolute inset-y-0 right-3 flex items-center text-caption text-text-secondary">
          กก.
        </span>
      </div>
      <p id={describedBy} className="text-caption">
        {message ? (
          <span className="text-danger">{message}</span>
        ) : max != null ? (
          <span className="text-text-secondary">
            ไม่เกิน{" "}
            <span className="font-mono tabular-nums">
              {formatHundredths(max)}
            </span>{" "}
            กก.{maxLabel ? ` (${maxLabel})` : ""}
          </span>
        ) : helper ? (
          <span className="text-text-muted">{helper}</span>
        ) : null}
      </p>
    </div>
  );
}
