import { kg } from "@/lib/format/weight";
import { cn } from "@/lib/utils";

/* WeightField (DESIGN-CONTRACTS.md) — the one big weight input on an S1/S2 screen. It is 56px
 * tall (`--h-row`, not yet a token in tokens.css), with the value at `num-lg`, a `กก.` suffix,
 * and `inputMode="decimal"`, because a single WeightField on a one-submit screen uses the OS
 * keypad (contract, corrected 2026-09-08).
 *
 * `max` is a physical ceiling and is shown BEFORE the user reaches it (`ไม่เกิน … กก.`). On
 * OW 07 it is the lot's central balance: asking for more than central holds is the one hard
 * stop in the allocation flow (FifoAllocator contract, BR24), and the parent disables submit
 * on it. The database refuses it again (INSUFFICIENT_CENTRAL_STOCK). */

export function WeightField({
  id,
  name,
  label,
  value,
  onChange,
  max,
  maxLabel,
  invalid,
  helper,
}: {
  id: string;
  name: string;
  label: string;
  value: string;
  onChange: (value: string) => void;
  max?: number;
  /** Thai — what the ceiling is. */
  maxLabel?: string;
  invalid?: boolean;
  helper?: string;
}) {
  return (
    <div className="flex flex-col gap-1">
      <label htmlFor={id} className="text-label text-text-secondary">
        {label}
      </label>
      <div
        className={cn(
          "flex h-14 items-center gap-2 rounded-md border bg-surface px-3 focus-within:outline-2 focus-within:outline-focus-ring",
          invalid ? "border-danger" : "border-border",
        )}
      >
        <input
          id={id}
          name={name}
          type="text"
          inputMode="decimal"
          autoComplete="off"
          required
          placeholder="0.00"
          aria-invalid={invalid || undefined}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          className="min-w-0 flex-1 bg-transparent text-num-lg text-text-primary tabular-nums outline-none"
        />
        <span className="shrink-0 text-body text-text-secondary">กก.</span>
      </div>
      {max !== undefined ? (
        <span
          className={cn(
            "text-caption tabular-nums",
            invalid ? "text-danger" : "text-text-muted",
          )}
        >
          ไม่เกิน {kg(max)} กก.{maxLabel ? ` — ${maxLabel}` : ""}
        </span>
      ) : null}
      {helper ? (
        <span className="text-caption text-text-muted">{helper}</span>
      ) : null}
    </div>
  );
}
