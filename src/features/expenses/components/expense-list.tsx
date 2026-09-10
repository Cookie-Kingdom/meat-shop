import type { ReactNode } from "react";

import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { thaiDate } from "@/lib/format/date";
import { thb } from "../format";
import { KIND_LABEL, type ExpenseRow } from "../types";

/* OW 09's list (card ^ref-54) on the shared ResponsiveTable — cards below md:, a table above.
 * The detail and the amount are the card headline, because they are what the Owner matches
 * against the bank statement. Money is right-aligned and tabular in both modes. */

const COLUMNS: Column<ExpenseRow>[] = [
  { id: "detail", header: "รายละเอียด", priority: 1, cell: (r) => r.detail },
  {
    id: "amount",
    header: "จำนวนเงิน (บาท)",
    priority: 1,
    numeric: true,
    cell: (r) => thb(r.amount_thb),
  },
  { id: "date", header: "วันที่จ่าย", cell: (r) => thaiDate(r.event_date) },
  { id: "kind", header: "หมวด", cell: (r) => KIND_LABEL[r.kind] },
  {
    id: "location",
    header: "สาขา",
    cell: (r) => r.location_name_th ?? "ส่วนกลาง",
  },
  {
    id: "by",
    header: "บันทึกโดย",
    cell: (r) => r.created_by_name ?? "—",
  },
];

export function ExpenseList({
  rows,
  emptyState,
}: {
  rows: ExpenseRow[];
  emptyState: ReactNode;
}) {
  return (
    <ResponsiveTable
      columns={COLUMNS}
      rows={rows}
      keyField={(r) => r.id}
      emptyState={emptyState}
    />
  );
}
