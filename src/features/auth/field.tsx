/* The `Label` / `TextInput` / `FormField` atoms in `design/COMPONENT-INVENTORY.md` are
 * not built yet and are not this card. This is the auth form's own field, sized for the
 * same one-handed phone every operator screen targets — 48px, 16px text so iOS does not
 * zoom on focus. It moves into `components/` when the second feature needs it. */

export function Field({
  label,
  name,
  type,
  autoComplete,
  autoFocus,
}: {
  label: string;
  name: string;
  type: "email" | "password";
  autoComplete: string;
  autoFocus?: boolean;
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <label htmlFor={name} className="text-label text-text-secondary">
        {label}
      </label>
      <input
        id={name}
        name={name}
        type={type}
        required
        autoComplete={autoComplete}
        autoFocus={autoFocus}
        className="h-12 rounded-md border border-border bg-surface px-3 text-base text-text-primary outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
      />
    </div>
  );
}
