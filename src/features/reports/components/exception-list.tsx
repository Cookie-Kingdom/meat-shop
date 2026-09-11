import Link from "next/link";

import { StatusBadge } from "@/features/cost/components/status-badge";
import { EXCEPTION_TH, missingTh } from "@/features/reports/labels";
import type { ExceptionRow } from "@/features/reports/types";
import { thaiDate } from "@/lib/format/date";
import { dp2, kg, pct } from "@/lib/format/number";

/* The rows behind OW 08's exceptions tile (Finding 14). Each line says what happened in the
 * numbers the view put in `detail`, and links to the screen where the Owner acts on it where one
 * exists. The screen formats; it computes nothing. */

type D = Record<string, unknown>;

const n = (v: unknown) =>
  typeof v === "number" || typeof v === "string" ? v : null;
const s = (v: unknown) => (typeof v === "string" ? v : "");

function summary(e: ExceptionRow): string {
  const d: D = e.detail ?? {};
  switch (e.exception_kind) {
    case "YIELD_ALERT":
      return `ล็อต ${s(d.lot_code)} · Loss ${pct(n(d.loss_pct))}`;
    case "DIFF_OVER_THRESHOLD":
      return (
        `Diff ${kg(n(d.diff_kg))} · เข้า ${kg(n(d.ready_in_kg))} ขาย ${kg(n(d.sold_kg))} ทิ้ง ${kg(n(d.wasted_kg))}` +
        (d.variance_pct === null
          ? " · ไม่มีฐานเทียบ ต้องระบุเหตุผล"
          : ` · ต่าง ${pct(n(d.variance_pct))}`)
      );
    case "MATERIAL_LOW":
      return `${s(d.name_th)} เหลือ ${dp2(n(d.remaining_qty))} ${s(d.unit)} (เตือนต่ำกว่า ${dp2(n(d.alert_threshold_qty))})`;
    case "COUNT_VARIANCE_OPEN":
      return `นับได้ ${dp2(n(d.counted_qty))} · ระบบ ${dp2(n(d.system_qty))} · ต่าง ${dp2(n(d.variance_qty))}`;
    case "RECEIPT_VARIANCE":
      return `ล็อต ${s(d.lot_code)} · ส่ง ${kg(n(d.dispatched_weight_kg))} รับ ${kg(n(d.received_weight_kg))} (${pct(n(d.variance_pct))}) · ${s(d.variance_reason)}`;
    case "RECEIPT_OUTSTANDING":
      return `ล็อต ${s(d.lot_code)} · ค้างรับ ${kg(n(d.outstanding_weight_kg))} · ${dp2(n(d.age_days)).replace(".00", "")} วัน`;
    case "LOT_COST_INCOMPLETE": {
      const missing = Array.isArray(d.missing_inputs)
        ? (d.missing_inputs as string[])
        : [];
      return `ล็อต ${s(d.lot_code)} · ${missing.map(missingTh).join(" · ")}`;
    }
  }
}

function hrefOf(e: ExceptionRow): string | null {
  switch (e.exception_kind) {
    case "YIELD_ALERT":
    case "LOT_COST_INCOMPLETE":
      return e.lot_id
        ? `/owner/lots/results?lot=${e.lot_id}`
        : "/owner/lots/results";
    case "RECEIPT_VARIANCE":
    case "RECEIPT_OUTSTANDING":
      return "/owner/transport";
    case "DIFF_OVER_THRESHOLD":
      return e.occurred_on && e.location_id
        ? `/owner/dashboard/trace?date=${e.occurred_on}&branch=${e.location_id}`
        : null;
    default:
      return null;
  }
}

export function ExceptionList({ rows }: { rows: ExceptionRow[] }) {
  if (rows.length === 0) {
    return (
      <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
        ไม่มีรายการที่ต้องจัดการในช่วงนี้
      </p>
    );
  }
  return (
    <ul className="flex flex-col gap-2">
      {rows.map((e) => {
        const href = hrefOf(e);
        return (
          <li
            key={`${e.exception_kind}:${e.ref_id}:${e.location_id ?? ""}`}
            className="flex flex-col gap-1 rounded-lg border border-border bg-surface p-4"
          >
            <div className="flex flex-wrap items-center gap-2">
              <StatusBadge tone="warning">
                {EXCEPTION_TH[e.exception_kind]}
              </StatusBadge>
              {e.occurred_on ? (
                <span className="text-caption text-text-secondary">
                  {thaiDate(e.occurred_on)}
                </span>
              ) : null}
            </div>
            <p className="text-body-sm break-words text-text-primary">
              {summary(e)}
            </p>
            {href ? (
              <Link
                href={href}
                className="text-label text-accent hover:underline"
              >
                ดูรายละเอียด →
              </Link>
            ) : null}
          </li>
        );
      })}
    </ul>
  );
}
