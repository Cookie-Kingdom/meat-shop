import Link from "next/link";

import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { thaiDate } from "@/lib/format/date";
import { DASH, kg, missingInputTh, pct, thb } from "../format";
import {
  ALLOC_TH,
  ROUTE_TH,
  type FreightLineRow,
  type LotCostRow,
} from "../types";
import { StatusBadge } from "./status-badge";
import { SummaryRow } from "./summary-row";

/* The lot's cost, part by part (card ^ref-33, reading v_lot_cost from ^ref-32).
 *
 * NEVER FINAL BEFORE IT IS (R30, ADR-015). Until `is_complete`, the heading says the figure
 * is the cost as at now and lists what it is still waiting for; the total is labelled "so
 * far". A missing part shows a dash, never 0.00 (ADR-023).
 *
 * EVERY PART CARRIES ITS INPUTS (F13): the PO and unit price, the brine percentage and rate
 * with the date the rate took effect, the smoke-fee band or the override and its reason, and
 * each freight line with its fare and method. */

function date(iso: string | null): string {
  return iso ? thaiDate(iso) : DASH;
}

function smokeTrace(row: LotCostRow): string {
  if (row.smoke_fee_is_overridden) {
    return `เจ้าของร้านกำหนดเอง — ${row.smoke_fee_override_reason ?? ""} · ถ้าคิดตามอัตราจะเป็น ${thb(row.smoke_fee_computed_thb)}`;
  }
  if (row.smoke_fee_rate_basis === "FLAT") {
    return `เหมาจ่าย ${thb(row.smoke_fee_rate_thb)} · ชุดอัตราเริ่มใช้ ${date(row.smoke_fee_tier_effective_from)}`;
  }
  if (row.smoke_fee_rate_basis === "PER_KG") {
    return `${thb(row.smoke_fee_rate_thb)}/กก. × Foodiva ส่งออก ${kg(row.foodiva_sent_weight_kg)} · ชุดอัตราเริ่มใช้ ${date(row.smoke_fee_tier_effective_from)}`;
  }
  return "ยังไม่มีอัตราค่ารมควันที่ครอบคลุมน้ำหนักนี้";
}

const freightColumns: Column<FreightLineRow>[] = [
  {
    id: "route",
    header: "เที่ยวรถ",
    priority: 1,
    cell: (r) => `${ROUTE_TH[r.route] ?? r.route} · ${thaiDate(r.event_date)}`,
  },
  {
    id: "vehicle",
    header: "รถ",
    cell: (r) =>
      `${r.vehicle_type ?? DASH} · ${r.is_round_trip ? "ไป-กลับ" : "เที่ยวเดียว"}`,
  },
  {
    id: "fare",
    header: "ค่าเที่ยว",
    numeric: true,
    cell: (r) => thb(r.run_cost_thb),
  },
  {
    id: "weight",
    header: "น้ำหนักล็อตนี้",
    numeric: true,
    cell: (r) => kg(r.dispatched_weight_kg),
  },
  {
    id: "share",
    header: "ส่วนของล็อตนี้",
    numeric: true,
    cell: (r) =>
      r.freight_share_thb === null ? "ยังไม่ปันส่วน" : thb(r.freight_share_thb),
  },
  {
    id: "method",
    header: "วิธีปันส่วน",
    cell: (r) => ALLOC_TH[r.alloc_method] ?? r.alloc_method,
  },
];

export function CostBreakdown({
  row,
  freight,
  overrideHref,
}: {
  row: LotCostRow;
  freight: FreightLineRow[];
  /** Where the override sheet opens. Omitted on OW 03, where the lot is still running. */
  overrideHref?: string;
}) {
  return (
    <section className="flex flex-col gap-3 rounded-lg border border-border bg-surface p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-h2 text-text-primary">ต้นทุนล็อต</h2>
        {row.is_complete ? (
          <StatusBadge tone="success">ต้นทุนครบแล้ว</StatusBadge>
        ) : (
          <StatusBadge tone="warning">
            ต้นทุน ณ ตอนนี้ — ยังไม่ใช่ต้นทุนสุดท้าย
          </StatusBadge>
        )}
      </div>

      <p className="text-caption text-text-muted">
        คิดตามค่าตั้งต้นที่ใช้อยู่ ณ วันที่ {date(row.priced_at)}
        {row.closed_at ? " (วันปิดล็อต)" : " (วันนี้ — ล็อตยังไม่ปิด)"}{" "}
        ค่าที่ตั้งใหม่หลังจากนี้ไม่ย้อนแก้ต้นทุนล็อตที่ปิดแล้ว
      </p>

      {row.missing_inputs.length > 0 ? (
        <div className="rounded-lg border border-warning bg-warning-subtle p-3">
          <p className="text-label text-text-primary">ยังรอข้อมูล</p>
          <ul className="mt-1 list-disc pl-5 text-body-sm text-text-secondary">
            {row.missing_inputs.map((code) => (
              <li key={code}>{missingInputTh(code)}</li>
            ))}
          </ul>
        </div>
      ) : null}

      <div>
        <SummaryRow
          label="ค่าเนื้อ"
          value={thb(row.meat_cost_thb)}
          trace={`${thb(row.meat_unit_price_thb_per_kg)}/กก. × Foodiva ส่งออก ${kg(row.foodiva_sent_weight_kg)}${row.po_number ? ` · ใบสั่งซื้อ ${row.po_number}` : ""}`}
        />
        <SummaryRow
          label="ค่าน้ำดอง"
          value={thb(row.brine_cost_thb)}
          trace={`Foodiva ส่งออก ${kg(row.foodiva_sent_weight_kg)} × ${pct(row.brine_pct_of_meat)} × ${thb(row.brine_cost_thb_per_kg)}/กก. · อัตราเริ่มใช้ ${date(row.brine_rate_effective_from)}`}
        />
        <SummaryRow
          label={
            row.smoke_fee_is_overridden ? "ค่ารมควัน (กำหนดเอง)" : "ค่ารมควัน"
          }
          value={thb(row.smoke_fee_thb)}
          trace={
            <>
              {smokeTrace(row)}
              {overrideHref ? (
                <>
                  {" · "}
                  <Link
                    href={overrideHref}
                    className="text-accent hover:underline"
                  >
                    แก้ค่ารมควันของล็อตนี้
                  </Link>
                </>
              ) : null}
            </>
          }
        />
        <SummaryRow
          label="ค่าขนส่งขาไป"
          value={thb(row.freight_outbound_thb)}
          trace="ส่วนของล็อตนี้ในค่าเที่ยว Foodiva → เชียงใหม่"
        />
        <SummaryRow
          label="ค่าขนส่งขากลับ"
          value={thb(row.freight_return_thb)}
          trace="ส่วนของล็อตนี้ในค่าเที่ยว เชียงใหม่ → Foodiva"
        />
        <SummaryRow
          label={row.is_complete ? "ต้นทุนรวม" : "ต้นทุนรวมเท่าที่ทราบ"}
          value={thb(row.total_cost_thb)}
          emphasis
        />
      </div>

      <h3 className="text-h3 text-text-primary">ที่มาของค่าขนส่ง</h3>
      <ResponsiveTable
        columns={freightColumns}
        rows={freight}
        keyField={(r) => r.line_id}
        emptyState={
          <p className="rounded-lg border border-border bg-surface-sunken p-4 text-body-sm text-text-secondary">
            ยังไม่มีเที่ยวรถของล็อตนี้
          </p>
        }
      />
    </section>
  );
}
