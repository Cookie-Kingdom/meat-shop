"use client";

import type { ReactNode } from "react";
import { useFormStatus } from "react-dom";

import { actionButton } from "@/components/ui/controls";
import { cn } from "@/lib/utils";

/* The one submit on a branch entry screen. Disables itself while the action runs.
 *
 * THAT IS DECORATION, NOT THE GUARD (TDD-thaw.md Seam 6). The guard is the idempotency key the
 * server component rendered once for this page view: a double tap that gets past this button
 * posts the same key twice, and the second call is a replay. The only client JavaScript on the
 * branch screens, and nothing depends on it running. */

export function SubmitButton({
  children,
  pendingLabel = "กำลังบันทึก…",
}: {
  children: ReactNode;
  pendingLabel?: string;
}) {
  const { pending } = useFormStatus();
  return (
    <button
      type="submit"
      disabled={pending}
      className={cn(actionButton, "h-12 w-full disabled:opacity-60")}
    >
      {pending ? pendingLabel : children}
    </button>
  );
}
