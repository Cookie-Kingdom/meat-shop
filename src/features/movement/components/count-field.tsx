import { Minus, Plus } from "lucide-react";

/* CountField (DESIGN-CONTRACTS.md) for OW 07's bag count. Integers only: anything that is
 * not a digit is dropped at the input layer. Steppers are on, because bag counts sit under 20
 * and each stepper is a 44 × 44 target for a gloved thumb. The minimum is 1, and a stepper
 * never goes below it. The count is REQUIRED (v0.2:108, BAG_COUNT_REQUIRED) and has no
 * default: an empty field is empty, not 1. */

const stepper =
  "flex size-11 shrink-0 items-center justify-center rounded-md border border-border bg-surface text-text-primary hover:bg-surface-raised focus-visible:outline-2 focus-visible:outline-focus-ring";

export function CountField({
  id,
  name,
  label,
  unit,
  value,
  onChange,
  hint,
}: {
  id: string;
  name: string;
  label: string;
  unit: string;
  value: string;
  onChange: (value: string) => void;
  hint?: string;
}) {
  const step = (d: number) =>
    onChange(String(Math.max(1, (Number(value) || 0) + d)));

  return (
    <div className="flex flex-col gap-1">
      <label htmlFor={id} className="text-label text-text-secondary">
        {label}
      </label>
      <div className="flex items-center gap-2">
        <button
          type="button"
          aria-label={`ลด${label}`}
          onClick={() => step(-1)}
          className={stepper}
        >
          <Minus aria-hidden className="size-5" />
        </button>
        <div className="flex h-12 min-w-0 flex-1 items-center gap-2 rounded-md border border-border bg-surface px-3 focus-within:outline-2 focus-within:outline-focus-ring">
          <input
            id={id}
            name={name}
            type="text"
            inputMode="numeric"
            pattern="[0-9]*"
            autoComplete="off"
            required
            value={value}
            onChange={(e) => onChange(e.target.value.replace(/\D/g, ""))}
            className="min-w-0 flex-1 bg-transparent text-num-md text-text-primary tabular-nums outline-none"
          />
          <span className="shrink-0 text-body text-text-secondary">{unit}</span>
        </div>
        <button
          type="button"
          aria-label={`เพิ่ม${label}`}
          onClick={() => step(1)}
          className={stepper}
        >
          <Plus aria-hidden className="size-5" />
        </button>
      </div>
      {hint ? <span className="text-caption text-text-muted">{hint}</span> : null}
    </div>
  );
}
