import { control } from "@/components/ui/controls";
import { cn } from "@/lib/utils";

/* The two entry atoms BR 03 and BR 08 need, server-side and uncontrolled, so a refusal that
 * redirects back re-fills them from the URL (lane B's fields.tsx pattern).
 *
 * Why not lane B's WeightField / CountField: BR 08 shows a saved count READ-ONLY on its retry
 * (PLAN-material-screens Finding 2), and the WeightField contract allows one 56px weight per
 * screen, while BR 03's SELF_COOK form has three. Both are 48px here. Empty = not recorded,
 * never 0. */

/** A rice weight in kg, two decimals at most (checked by the action). */
export function KgField({
  label,
  name,
  defaultValue,
  hint,
  readOnly = false,
}: {
  label: string;
  name: string;
  defaultValue?: string;
  hint?: string;
  readOnly?: boolean;
}) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-label text-text-secondary">{label}</span>
      <span className="flex items-center gap-2">
        <input
          type="text"
          inputMode="decimal"
          autoComplete="off"
          name={name}
          defaultValue={defaultValue}
          readOnly={readOnly}
          className={cn(control, "h-12 font-mono text-num-md tabular-nums", readOnly && "bg-surface-sunken")}
        />
        <span className="shrink-0 text-body text-text-secondary">กก.</span>
      </span>
      {hint ? <span className="text-caption text-text-muted">{hint}</span> : null}
    </label>
  );
}

/** A whole count (BR21): tubes, pieces, sheets. A decimal is refused by the action. */
export function WholeInput({
  label,
  name,
  unit,
  defaultValue,
  readOnly = false,
}: {
  label: string;
  name: string;
  unit: string;
  defaultValue?: string;
  readOnly?: boolean;
}) {
  return (
    <label className="flex items-center gap-2">
      <span className="sr-only">{label}</span>
      <input
        type="text"
        inputMode="numeric"
        pattern="[0-9]*"
        autoComplete="off"
        name={name}
        defaultValue={defaultValue}
        readOnly={readOnly}
        className={cn(control, "h-12 font-mono text-num-md tabular-nums", readOnly && "bg-surface-sunken")}
      />
      <span className="shrink-0 text-body text-text-secondary">{unit}</span>
    </label>
  );
}
