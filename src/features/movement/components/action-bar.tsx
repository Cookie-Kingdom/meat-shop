import type { ReactNode } from "react";

import { actionButton } from "@/components/ui/controls";
import { cn } from "@/lib/utils";

/* BottomActionBar for the OW 05–07 forms (DESIGN-CONTRACTS.md). Sticky at the bottom on a
 * phone, so the one primary action stays above the keyboard. It becomes an ordinary inline
 * block at `lg:`, where the whole form fits. The negative margins undo RoleShell's
 * `p-4 md:p-6`, so the bar spans the screen.
 *
 * Kept in the feature, not promoted to shared/: three lanes are building phone forms today,
 * and three `shared/bottom-action-bar.tsx` files would conflict like three features
 * (PARALLEL-LANES.md). Promote when the app-shell card lands. */

export function ActionBar({ children }: { children: ReactNode }) {
  return (
    <div className="sticky bottom-0 z-10 -mx-4 border-t border-border bg-surface px-4 pt-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] md:-mx-6 md:px-6 lg:static lg:mx-0 lg:border-0 lg:bg-transparent lg:p-0">
      {children}
    </div>
  );
}

/** The primary button at `lg` height (48px), full width on a phone. */
export const primaryAction = cn(
  actionButton,
  "h-12 w-full disabled:cursor-not-allowed disabled:opacity-50 lg:w-auto",
);
