import Link from "next/link";

import { thaiDate } from "@/lib/format/date";
import { kg } from "@/lib/format/weight";
import type { ReturnPendingRow } from "../types";
import { ReturnStateBadge } from "./return-state-badge";

/* OW 05's list — LotList (DESIGN-CONTRACTS.md), skeleton S3. Rows are 88px, with the reference
 * and the state on line 1 and the weight and the wait on line 2. A tap pushes the full-screen
 * detail (`?lot=`), with no split pane at phone width. The caller sorts oldest first, so the lot
 * most likely to be acted on is above the fold.
 *
 * `onTruck` names lots whose return leg is already dispatched: they stay RETURN_SCHEDULED
 * until central signs (fn_confirm_transport_receipt), and changing their date is refused
 * RETURN_ALREADY_DISPATCHED. The row says so instead of offering it. */

export function ReturnLotList({
  rows,
  onTruck,
}: {
  rows: ReturnPendingRow[];
  onTruck: Set<string>;
}) {
  return (
    <ul className="flex flex-col gap-2">
      {rows.map((r) => (
        <li key={r.lot_id}>
          <Link
            href={`/owner/returns?lot=${r.lot_id}`}
            className="flex min-h-[88px] flex-col justify-center gap-1 rounded-lg border border-border bg-surface px-4 py-3 hover:bg-surface-raised focus-visible:outline-2 focus-visible:outline-focus-ring"
          >
            <span className="flex items-center justify-between gap-2">
              <span className="text-label text-text-primary">Lot {r.lot_code}</span>
              <ReturnStateBadge state={r.state} />
            </span>
            <span className="flex flex-wrap items-center justify-between gap-x-3 text-body-sm text-text-secondary">
              <span className="tabular-nums">
                {kg(r.packed_weight_kg)} กก. · {r.group_count} กลุ่มวันรมควัน
              </span>
              <span className="tabular-nums">
                {onTruck.has(r.lot_id)
                  ? "อยู่บนรถขากลับ"
                  : r.return_pickup_date
                    ? `นัดรับ ${thaiDate(r.return_pickup_date)}`
                    : `ปิดมาแล้ว ${r.days_since_close ?? "—"} วัน`}
              </span>
            </span>
          </Link>
        </li>
      ))}
    </ul>
  );
}
