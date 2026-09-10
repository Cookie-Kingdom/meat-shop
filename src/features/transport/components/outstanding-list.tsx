import Link from "next/link";

import { actionLink } from "@/components/ui/controls";
import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { thaiDate } from "@/lib/format/date";
import { kg } from "@/lib/format/number";
import { ROUTE_LABEL } from "../labels";
import type { OutstandingRow, Place } from "../types";

/* ค้างรับ — v_outstanding_receipts on OW 02 (^ref-24 acceptance, clause 1).
 *
 * Both kinds of outstanding that view carries: a line nobody has signed for, and a partial
 * receipt that left a balance on the truck (D06). The second is the one that matters, and
 * it gets its own wording, because a line that has been signed for cannot be signed for
 * again (LINE_ALREADY_RECEIVED). What is left is settled by F8, not re-received here.
 *
 * The action column names WHO signs, from the destination kind — the same rule
 * fn_confirm_transport_receipt applies. The Owner gets a button only where the database
 * would accept them (CENTRAL).
 */

export function OutstandingList({
  rows,
  places,
  receiveHref,
}: {
  rows: OutstandingRow[];
  places: Map<string, Place>;
  receiveHref: (lineId: string) => string;
}) {
  const placeOf = (r: OutstandingRow) =>
    r.to_location_id ? places.get(r.to_location_id) : undefined;

  const action = (r: OutstandingRow) => {
    const kind = placeOf(r)?.kind;
    if (r.received_weight_kg !== null) {
      return (
        <span className="text-caption text-text-secondary">
          รับบางส่วนแล้ว ส่วนที่ขาดค้างบนรถ (D06)
        </span>
      );
    }
    if (kind === "CENTRAL") {
      return (
        <Link href={receiveHref(r.line_id)} className={actionLink}>
          รับเข้าคลังกลาง →
        </Link>
      );
    }
    if (kind === "CHEF_HOUSE") {
      return (
        <span className="text-caption text-text-secondary">
          รอเชียงใหม่ยืนยันรับ (CM 02)
        </span>
      );
    }
    if (kind === "BRANCH") {
      return (
        <span className="text-caption text-text-secondary">
          รอสาขายืนยันรับ (BR 02)
        </span>
      );
    }
    return "—";
  };

  const columns: Column<OutstandingRow>[] = [
    {
      id: "lot",
      header: "ล็อต",
      priority: 1,
      cell: (r) => <span className="tabular-nums">{r.lot_code}</span>,
    },
    {
      id: "left",
      header: "ค้าง",
      priority: 1,
      numeric: true,
      cell: (r) => kg(r.outstanding_weight_kg),
    },
    { id: "route", header: "เส้นทาง", cell: (r) => ROUTE_LABEL[r.route] },
    { id: "to", header: "ปลายทาง", cell: (r) => placeOf(r)?.name ?? "—" },
    { id: "date", header: "วันที่ส่ง", cell: (r) => thaiDate(r.dispatch_date) },
    {
      id: "sent",
      header: "ส่ง",
      numeric: true,
      cell: (r) => kg(r.dispatched_weight_kg),
    },
    {
      id: "received",
      header: "รับแล้ว",
      numeric: true,
      cell: (r) => kg(r.received_weight_kg),
    },
    {
      id: "age",
      header: "ค้างมา",
      numeric: true,
      cell: (r) => `${r.age_days} วัน`,
    },
    { id: "action", header: "", cell: action },
  ];

  return (
    <ResponsiveTable
      columns={columns}
      rows={rows}
      keyField={(r) => r.line_id}
      emptyState={
        <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
          ไม่มีรายการค้างรับ — ทุกเที่ยวที่ส่งแล้วได้รับการยืนยันครบ
        </p>
      }
    />
  );
}
