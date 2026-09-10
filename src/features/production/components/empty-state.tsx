import type { ReactNode } from "react";
import { Inbox } from "lucide-react";

/* EmptyState (DESIGN-CONTRACTS): why it is empty, whose job it is, and the one action that
 * resolves it. Distinct from a failed read (AlertBanner, danger) and from unset config — an
 * empty list is not an error (REVIEW 11, 15). */

export function EmptyState({
  title,
  body,
  action,
}: {
  title: string;
  body?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="flex flex-col items-center gap-2 rounded-lg border border-border bg-surface px-4 py-7 text-center">
      <Inbox aria-hidden className="size-8 text-text-muted" />
      <p className="text-h3 text-text-primary">{title}</p>
      {body ? <p className="text-body-sm text-text-secondary">{body}</p> : null}
      {action}
    </div>
  );
}
