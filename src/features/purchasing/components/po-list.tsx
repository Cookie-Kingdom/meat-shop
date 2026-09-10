import Link from "next/link";

import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { thaiDate } from "@/lib/format/date";
import { kg, thb } from "@/lib/format/number";
import type { PoRegisterRow } from "../types";

/* The OW 01 register — every PO, newest first, over v_po_register.
 *
 * Card mode below `md:` is the real design at 360px, not a fallback (ResponsiveTable's
 * header). Sent and outstanding both render in the card, so the worst case in the
 * PurchaseOrderForm contract — "both on screen at 360px without a horizontal table" — holds
 * for the list as well as for one PO's sheet.
 */

export function PoList({
  rows,
  hrefFor,
}: {
  rows: PoRegisterRow[];
  hrefFor: (poId: string) => string;
}) {
  const columns: Column<PoRegisterRow>[] = [
    {
      id: "po",
      header: "เลข PO",
      priority: 1,
      cell: (r) => (
        <Link
          href={hrefFor(r.po_id)}
          className="inline-flex min-h-11 items-center text-accent tabular-nums hover:underline"
        >
          {r.po_number}
        </Link>
      ),
    },
    { id: "supplier", header: "ผู้ขาย", cell: (r) => r.supplier_name },
    { id: "date", header: "วันที่สั่ง", cell: (r) => thaiDate(r.order_date) },
    {
      id: "ordered",
      header: "สั่ง",
      numeric: true,
      cell: (r) => kg(r.ordered_weight_kg),
    },
    {
      id: "sent",
      header: "ส่งแล้ว",
      numeric: true,
      cell: (r) => kg(r.dispatched_weight_kg),
    },
    {
      id: "outstanding",
      header: "ค้างส่ง",
      numeric: true,
      cell: (r) => kg(r.outstanding_weight_kg),
    },
    {
      id: "rounds",
      header: "รอบส่ง / ล็อต",
      numeric: true,
      cell: (r) => r.round_count,
    },
    {
      id: "price",
      header: "ราคา/กก.",
      numeric: true,
      cell: (r) => thb(r.unit_price_thb_per_kg),
    },
    {
      id: "total",
      header: "ยอดรวมค่าเนื้อ",
      numeric: true,
      cell: (r) => thb(r.meat_total_thb),
    },
  ];

  return (
    <ResponsiveTable
      columns={columns}
      rows={rows}
      keyField={(r) => r.po_id}
      emptyState={
        <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
          ยังไม่มี PO — กด “สร้าง PO ใหม่” เพื่อเริ่ม
        </p>
      }
    />
  );
}
