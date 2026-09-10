import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { thaiDate } from "@/lib/format/date";
import { kg, pct } from "../format";
import type { LotDailyYieldRow } from "../types";

/* OW 03's yield trend — one row per smoke day, from v_lot_daily_yield (card ^ref-33).
 *
 * THE DAY'S FIGURE IS NOT LOSS (R17) AND NOT SMOKE YIELD (ADR-011). It is that day's packed
 * weight over that day's input — a progress figure while the lot runs. Loss is computed once,
 * at close, against the Foodiva dispatch, and lives on OW 04. The caption says so on the
 * screen, not only here. A day with no bags yet reads "not packed", not 0%. */

const columns: Column<LotDailyYieldRow>[] = [
  {
    id: "date",
    header: "วันที่รมควัน",
    priority: 1,
    cell: (r) => thaiDate(r.event_date),
  },
  {
    id: "yield",
    header: "Yield รายวัน",
    priority: 1,
    numeric: true,
    cell: (r) =>
      r.day_yield_pct === null ? "ยังไม่แพ็ค" : pct(r.day_yield_pct),
  },
  {
    id: "input",
    header: "นำเข้ารมควัน",
    numeric: true,
    cell: (r) => kg(r.input_weight_kg),
  },
  {
    id: "smoked",
    header: "ออกจากเตา",
    numeric: true,
    cell: (r) => kg(r.smoked_weight_kg),
  },
  {
    id: "brine",
    header: "น้ำดองที่ใช้",
    numeric: true,
    cell: (r) => kg(r.brine_used_kg),
  },
  {
    id: "packed",
    header: "แพ็คได้",
    numeric: true,
    cell: (r) =>
      r.packed_weight_kg === null
        ? "ยังไม่แพ็ค"
        : `${kg(r.packed_weight_kg)} · ${r.bag_count ?? 0} ถุง`,
  },
];

export function DailyYieldTable({ rows }: { rows: LotDailyYieldRow[] }) {
  return (
    <section className="flex flex-col gap-3">
      <h2 className="text-h2 text-text-primary">แนวโน้มรายวัน</h2>
      <p className="text-caption text-text-muted">
        Yield รายวัน = น้ำหนักแพ็คของวันนั้น ÷ น้ำหนักที่นำเข้ารมควันวันนั้น ×
        100 — ใช้ดูแนวโน้มระหว่างผลิตเท่านั้น ไม่ใช่ Loss ของล็อต (Loss
        หลักคำนวณครั้งเดียวตอนปิดล็อต เทียบน้ำหนัก Foodiva ส่งออก)
      </p>
      <ResponsiveTable
        columns={columns}
        rows={rows}
        keyField={(r) => r.smoke_daily_log_id}
        emptyState={
          <p className="rounded-lg border border-border bg-surface p-4 text-body-sm text-text-secondary">
            เชียงใหม่ยังไม่ได้บันทึก Daily Smoke Log ของล็อตนี้
          </p>
        }
      />
    </section>
  );
}
