import Link from "next/link";

import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { thaiDate } from "@/lib/format/date";
import { kg, thb } from "@/lib/format/number";
import { METHOD_LABEL, ROUTE_LABEL, tripLabel } from "../labels";
import type { TransportRunRow } from "../types";

/* รอบรถล่าสุด — v_transport_runs (252). A run with no lots yet is listed with 0 lots,
 * which is the reason that view exists. A run whose shares do not reconcile to its fare says
 * so in the row, so it can be opened and re-split. */

export function RunsList({
  rows,
  hrefFor,
}: {
  rows: TransportRunRow[];
  hrefFor: (runId: string) => string;
}) {
  const columns: Column<TransportRunRow>[] = [
    {
      id: "run",
      header: "รอบรถ",
      priority: 1,
      cell: (r) => (
        <Link
          href={hrefFor(r.run_id)}
          className="inline-flex min-h-11 items-center text-accent hover:underline"
        >
          {thaiDate(r.event_date)} · {ROUTE_LABEL[r.route]}
        </Link>
      ),
    },
    {
      id: "fare",
      header: "ค่าเที่ยว",
      priority: 1,
      numeric: true,
      cell: (r) => thb(r.run_cost_thb),
    },
    { id: "vehicle", header: "ประเภทรถ", cell: (r) => r.vehicle_type ?? "—" },
    { id: "trip", header: "รูปแบบ", cell: (r) => tripLabel(r.is_round_trip) },
    { id: "method", header: "วิธีแบ่ง", cell: (r) => METHOD_LABEL[r.alloc_method] },
    { id: "lots", header: "ล็อต", numeric: true, cell: (r) => r.line_count },
    {
      id: "weight",
      header: "น้ำหนัก",
      numeric: true,
      cell: (r) => kg(r.dispatched_weight_kg),
    },
    {
      id: "allocated",
      header: "แบ่งแล้ว",
      numeric: true,
      cell: (r) =>
        r.fare_reconciles_to_satang ? (
          thb(r.allocated_thb)
        ) : (
          <span className="text-warning">{thb(r.allocated_thb)} · ยังไม่ครบ</span>
        ),
    },
  ];

  return (
    <ResponsiveTable
      columns={columns}
      rows={rows}
      keyField={(r) => r.run_id}
      emptyState={
        <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
          ยังไม่มีรอบรถ — กด “ส่งรถขาไป” เพื่อเริ่ม
        </p>
      }
    />
  );
}
