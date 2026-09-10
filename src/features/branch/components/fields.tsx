import { control } from "@/components/ui/controls";
import { cn } from "@/lib/utils";

/* The three entry atoms BR 02 and BR 05 need (DESIGN-CONTRACTS.md `WeightField`, `CountField`,
 * `ReasonField`), written server-side: uncontrolled inputs with `defaultValue`, so a refusal that
 * redirects back re-fills them from the URL and nobody re-types a weight with wet hands.
 *
 * Here and not in `components/shared/` on purpose (PARALLEL-LANES.md): lanes A, C, D and G may
 * each need the same atoms today, and two lanes each creating `shared/weight-field.tsx` is a
 * conflict that looks like two features. Promote when the lanes merge.
 *
 * What these cannot do without client JavaScript, and do not pretend to: the live over-max mark
 * and the live hidden→required reason. The database decides both at submit (ADR-004), and the
 * page re-renders with the reason field required and the values kept. */

/** The one big weight per screen: 56px, numeric keypad, kg suffix. `0.00` is a real value. */
export function WeightField({
  label,
  name,
  defaultValue,
  hint,
  required = true,
}: {
  label: string;
  name: string;
  defaultValue?: string;
  hint?: string;
  required?: boolean;
}) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-label text-text-secondary">{label}</span>
      <span className="flex h-14 items-center gap-2 rounded-md border border-border bg-surface px-3 focus-within:border-focus-ring focus-within:outline-2 focus-within:outline-focus-ring">
        <input
          type="text"
          inputMode="decimal"
          autoComplete="off"
          name={name}
          required={required}
          defaultValue={defaultValue}
          className="min-w-0 flex-1 bg-transparent font-mono text-num-lg tabular-nums text-text-primary outline-none"
        />
        <span className="text-body text-text-secondary">กก.</span>
      </span>
      {hint ? <span className="text-caption text-text-muted">{hint}</span> : null}
    </label>
  );
}

/** A whole count. Decimal input is refused by the action; empty means not counted, never 0. */
export function CountField({
  label,
  name,
  unit,
  defaultValue,
  hint,
}: {
  label: string;
  name: string;
  unit: string;
  defaultValue?: string;
  hint?: string;
}) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-label text-text-secondary">{label}</span>
      <span className="flex items-center gap-2">
        <input
          type="text"
          inputMode="numeric"
          pattern="[0-9]*"
          autoComplete="off"
          name={name}
          defaultValue={defaultValue}
          className={cn(control, "h-12 font-mono text-num-md tabular-nums")}
        />
        <span className="text-body text-text-secondary">{unit}</span>
      </span>
      {hint ? <span className="text-caption text-text-muted">{hint}</span> : null}
    </label>
  );
}

/** Why a number does not match, or why FIFO was skipped. When `required`, the Thai `trigger`
 * line says why it is now required, and the page renders it ABOVE the field that caused it. */
export function ReasonField({
  label,
  name,
  required = false,
  trigger,
  defaultValue,
}: {
  label: string;
  name: string;
  required?: boolean;
  trigger?: string;
  defaultValue?: string;
}) {
  return (
    <label className="flex flex-col gap-1">
      {trigger ? (
        <span className="rounded-md border border-warning bg-warning-subtle p-2 text-body-sm text-text-primary">
          {trigger}
        </span>
      ) : null}
      <span className="text-label text-text-secondary">
        {label}
        {required ? " (ต้องระบุ)" : ""}
      </span>
      <textarea
        name={name}
        rows={3}
        required={required}
        defaultValue={defaultValue}
        className={cn(control, "h-auto py-2")}
      />
    </label>
  );
}
