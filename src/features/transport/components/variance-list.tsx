import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { thaiDateTime } from "@/lib/format/date";
import { kg, pct } from "@/lib/format/number";
import { cn } from "@/lib/utils";
import { ROUTE_LABEL } from "../labels";
import type { VarianceRow } from "../types";

/* ส่วนต่างตอนรับ — v_transport_variance on OW 02 (^ref-24 acceptance, clause 1; UAT-11,
 * BR12). The Owner's cross-check result: sent against received, with the reason the
 * receiver gave.
 *
 * THE PERCENTAGE IS THE VIEW'S, WHICH IS fn_check_variance'S (ADR-019), never
 * transport_lines.variance_pct — the two disagree at the third decimal (Seam 4).
 *
 * The view has no verdict column on purpose: a verdict needs a dated threshold that no
 * session may resolve through the view. The colour here compares against the threshold in
 * force TODAY, and the caption says so. The verdict that decided whether a reason was
 * demanded was taken at write time, and variance_reason is the record of it.
 */

export function VarianceList({
  rows,
  thresholdPct,
}: {
  rows: VarianceRow[];
  thresholdPct: number | null;
}) {
  const tone = (r: VarianceRow) => {
    const v = r.variance_pct === null ? null : Number(r.variance_pct);
    if (v === null || v === 0) return "text-text-secondary";
    if (thresholdPct !== null && v > thresholdPct) return "text-danger";
    return "text-warning";
  };

  const columns: Column<VarianceRow>[] = [
    {
      id: "lot",
      header: "ล็อต",
      priority: 1,
      cell: (r) => <span className="tabular-nums">{r.lot_code}</span>,
    },
    {
      id: "pct",
      header: "ส่วนต่าง",
      priority: 1,
      numeric: true,
      cell: (r) => <span className={cn(tone(r))}>{pct(r.variance_pct)}</span>,
    },
    { id: "route", header: "เส้นทาง", cell: (r) => ROUTE_LABEL[r.route] },
    {
      id: "sent",
      header: "ส่ง",
      numeric: true,
      cell: (r) => kg(r.dispatched_weight_kg),
    },
    {
      id: "received",
      header: "รับ",
      numeric: true,
      cell: (r) => kg(r.received_weight_kg),
    },
    { id: "reason", header: "เหตุผล", cell: (r) => r.variance_reason ?? "—" },
    {
      id: "settlement",
      header: "วิธีปิดส่วนต่าง",
      cell: (r) => r.variance_settlement ?? "—",
    },
    {
      id: "at",
      header: "รับเมื่อ",
      cell: (r) => (r.received_at ? thaiDateTime(r.received_at) : "—"),
    },
  ];

  return (
    <>
      <p className="text-caption text-text-muted">
        ส่วนต่าง = |รับ − ส่ง| ÷ ส่ง × 100 (ADR-019) ·{" "}
        {thresholdPct !== null
          ? `สีแดงเมื่อเกินเกณฑ์ที่ใช้อยู่วันนี้ ${pct(thresholdPct)}`
          : "ยังไม่ได้ตั้งเกณฑ์ส่วนต่างในการตั้งค่า"}
      </p>
      <ResponsiveTable
        columns={columns}
        rows={rows}
        keyField={(r) => r.line_id}
        emptyState={
          <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
            ยังไม่มีรายการที่ยืนยันรับ
          </p>
        }
      />
    </>
  );
}
