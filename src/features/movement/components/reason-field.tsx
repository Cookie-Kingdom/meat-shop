import { cn } from "@/lib/utils";

/* ReasonField (DESIGN-CONTRACTS.md) for OW 06's variance and OW 07's FIFO override.
 *
 * The PARENT decides when it exists, and renders it only then. That is how the contract's
 * worst case is met: correct the weight back inside the threshold and the field unmounts, so
 * its text is never submitted with a reason that no longer applies. The textarea is the only
 * holder of the `name`, so an unmounted field posts nothing.
 *
 * `required` is a mirror. The function that receives the form raises the named refusal
 * (VARIANCE_REASON_REQUIRED, FIFO_OVERRIDE_REASON_REQUIRED). This field says why, first. */

export function ReasonField({
  id,
  name,
  label,
  trigger,
  value,
  onChange,
  required,
}: {
  id: string;
  name: string;
  label: string;
  /** Thai — why a reason is now asked for. */
  trigger: string;
  value: string;
  onChange: (value: string) => void;
  required: boolean;
}) {
  return (
    <div
      className={cn(
        "flex flex-col gap-1 rounded-lg border p-3",
        required
          ? "border-danger bg-danger-subtle"
          : "border-warning bg-warning-subtle",
      )}
    >
      <label htmlFor={id} className="text-label text-text-primary">
        {label}
        {required ? <span className="text-danger"> *</span> : null}
      </label>
      <p className="text-caption text-text-secondary">{trigger}</p>
      <textarea
        id={id}
        name={name}
        rows={3}
        required={required}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="min-h-24 w-full rounded-md border border-border bg-surface px-3 py-2 text-body text-text-primary focus-visible:border-focus-ring focus-visible:outline-2 focus-visible:outline-focus-ring"
      />
    </div>
  );
}
