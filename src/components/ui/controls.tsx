import type { ReactNode } from "react";

/* Form atoms shared by the S8 screens (config, audit). Sized for one-handed phone entry
 * with wet or gloved hands: every control and every action is h-11, the 44px tap target.
 * The `Label` / `TextInput` / `FormField` atoms in `design/COMPONENT-INVENTORY.md`
 * replace these when that card lands. */

export const control =
  "h-11 w-full rounded-md border border-border bg-surface px-3 text-body text-text-primary " +
  "focus-visible:border-focus-ring focus-visible:outline-2 focus-visible:outline-focus-ring";

/** The primary action — a submit button, or a Link that starts a flow. */
export const actionButton =
  "inline-flex h-11 items-center justify-center rounded-md bg-accent px-4 text-label text-accent-fg hover:bg-accent-hover";

/** A secondary action written as a text link. Still a full-height tap target. */
export const actionLink =
  "inline-flex h-11 items-center text-label text-accent hover:underline";

export function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: ReactNode;
}) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-label text-text-secondary">{label}</span>
      {children}
      {hint ? (
        <span className="text-caption text-text-muted">{hint}</span>
      ) : null}
    </label>
  );
}
