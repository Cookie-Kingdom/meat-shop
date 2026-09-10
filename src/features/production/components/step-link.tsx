import Link from "next/link";
import { Ban, ChevronRight, Circle, CircleCheck } from "lucide-react";

/* One step on the lot hub — ChecklistItem's shape (DESIGN-CONTRACTS): 56px, full width, a
 * chevron. Done is DERIVED FROM THE RECORDS by the page, never a local tick, and a blocked
 * step says why in its own text instead of rendering as a dead link (REVIEW 16). */

export function StepLink({
  href,
  label,
  detail,
  done,
  blocked,
}: {
  href: string;
  label: string;
  detail?: string;
  done?: boolean;
  /** Why this step cannot be opened yet, in Thai. */
  blocked?: string | null;
}) {
  if (blocked) {
    return (
      <div className="flex min-h-14 items-center gap-3 rounded-lg border border-border bg-surface-sunken px-4 py-2">
        <Ban aria-hidden className="size-5 shrink-0 text-text-muted" />
        <div className="flex min-w-0 flex-col">
          <p className="text-label text-text-secondary">{label}</p>
          <p className="text-caption text-text-muted">{blocked}</p>
        </div>
      </div>
    );
  }
  return (
    <Link
      href={href}
      className="flex min-h-14 items-center gap-3 rounded-lg border border-border bg-surface px-4 py-2 hover:bg-surface-sunken"
    >
      {done ? (
        <CircleCheck
          aria-label="ทำแล้ว"
          className="size-5 shrink-0 text-success"
        />
      ) : (
        <Circle
          aria-label="ยังไม่ได้ทำ"
          className="size-5 shrink-0 text-text-muted"
        />
      )}
      <div className="flex min-w-0 flex-1 flex-col">
        <p className="text-label text-text-primary">{label}</p>
        {detail ? (
          <p className="text-caption text-text-secondary">{detail}</p>
        ) : null}
      </div>
      <ChevronRight aria-hidden className="size-5 shrink-0 text-text-muted" />
    </Link>
  );
}
