import { Lock } from "lucide-react";

import { thaiDateTime } from "@/lib/format/date";

/* LockIndicator, banner variant (DESIGN-CONTRACTS, LAYOUT-SKELETONS' LOCKED state): who
 * closed it and when, the lock icon, and the unlock path. For an L3 the path is a sentence and
 * no control — the unlock panel is the Owner's (^ref-08, OW 11).
 *
 * The `--hatch` diagonal is what makes a locked surface unmistakable in greyscale and in
 * both themes; the lock icon and the locked tokens carry the state for colour readers. */

export function LockIndicator({
  closedAt,
  closedBy,
}: {
  closedAt: string | null;
  closedBy: string | null;
}) {
  return (
    <div className="flex gap-3 rounded-lg border border-locked bg-locked-subtle bg-[image:var(--hatch)] p-4 text-body-sm text-text-primary">
      <Lock aria-hidden className="mt-0.5 size-5 shrink-0 text-locked" />
      <div className="flex flex-col gap-1">
        <p className="text-label text-text-primary">
          ปิด Lot แล้ว — แก้ไขไม่ได้
        </p>
        <p className="text-text-secondary">
          {closedBy ? `ปิดโดย ${closedBy}` : "ปิดแล้ว"}
          {closedAt ? (
            <>
              {" · "}
              <span className="font-mono tabular-nums">
                {thaiDateTime(closedAt)}
              </span>
            </>
          ) : null}
        </p>
        <p className="text-text-secondary">
          ต้องการแก้ไขตัวเลขของ Lot นี้ แจ้ง Owner เพื่อขอปลดล็อก
        </p>
      </div>
    </div>
  );
}
