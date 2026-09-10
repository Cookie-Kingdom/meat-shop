import type { ReactNode } from "react";

import { actionButton } from "@/components/ui/controls";
import { cn } from "@/lib/utils";

/* The S1 `BottomActionBar` (design/LAYOUT-SKELETONS.md → S1). Shared by OW 01 and OW 02,
 * lane F's two S1 screens.
 *
 * Sticky at the bottom below `lg:`, so the one primary action stays above the keyboard and
 * under the thumb. It is inline at the end of the form from `lg:` up, where the whole form
 * fits and a sticky bar only covers content. Exactly one primary button, full width on a
 * phone and 48px tall (--h-action) — a gloved thumb does not aim.
 *
 * The negative margin assumes the bar sits directly in a `Sheet` (p-4), so the bar's
 * background meets the sheet's edges instead of floating in a gap.
 */

export function SubmitBar({
  label,
  note,
}: {
  label: string;
  /** One line above the button — what pressing it will do. */
  note?: ReactNode;
}) {
  return (
    <div className="sticky bottom-0 -mx-4 flex flex-col gap-2 border-t border-border bg-surface p-4 lg:static lg:mx-0 lg:border-0 lg:p-0">
      {note ? (
        <p className="text-caption text-text-secondary">{note}</p>
      ) : null}
      <button type="submit" className={cn(actionButton, "h-12 w-full lg:w-auto")}>
        {label}
      </button>
    </div>
  );
}
