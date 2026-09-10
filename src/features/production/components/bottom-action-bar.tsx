import type { ReactNode } from "react";

/* BottomActionBar (DESIGN-CONTRACTS): sticky to the bottom of the viewport on a phone so the
 * primary action stays reachable above the keyboard, inline at lg: where the whole form fits.
 * The negative margin matches RoleShell's p-4 so the bar spans the screen edge to edge. */

export function BottomActionBar({ children }: { children: ReactNode }) {
  return (
    <div
      /* The safe-area inset has no token: it is the device's, not ours (REVIEW 1). */
      className="sticky bottom-0 z-10 -mx-4 flex flex-col gap-2 border-t border-border bg-surface px-4 pt-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))] md:-mx-6 md:px-6 lg:static lg:mx-0 lg:border-t-0 lg:bg-transparent lg:px-0 lg:pb-0"
    >
      {children}
    </div>
  );
}

/** The one write action on a screen: 48px, full width on a phone (REVIEW 7). */
export const writeButton =
  "inline-flex h-12 w-full items-center justify-center gap-2 rounded-md bg-accent px-4 text-label text-accent-fg hover:bg-accent-hover disabled:opacity-60 lg:w-auto";

/** The irreversible one (CM 05's close): same size, danger tone. */
export const dangerButton =
  "inline-flex h-12 w-full items-center justify-center gap-2 rounded-md bg-danger px-4 text-label text-danger-fg hover:opacity-90 disabled:opacity-60 lg:w-auto";
