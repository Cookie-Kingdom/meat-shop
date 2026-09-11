import { cva } from "class-variance-authority";

import type { MaterialRow } from "../queries";
import { WholeInput } from "./fields";

/* MaterialCountRow — one BR 08 line (DESIGN-CONTRACTS `MaterialCountRow`, S5; PLAN-material-
 * screens Findings 3–5).
 *
 * A BLIND COUNT. Before today's count is saved the row shows no remainder, only the full level
 * and the alert threshold as context. The state badge appears once today's count is saved, and
 * it is the view's is_low (R10's strict <, computed in SQL). The screen never compares a typed
 * number against a threshold, because that would be a second copy of R10.
 *
 * null is never "fine": no full level or no ratio reads ยังไม่ตั้งค่า (R9). The per-row
 * not-configured line is suppressed when the page shows one sheet-level notice instead (S5).
 * The name wraps and is never truncated (การ์ด/สติกเกอร์วิธีอุ่น at 360px, TC-16). */

const badge = cva("shrink-0 rounded-full px-2 py-0.5 text-caption", {
  variants: {
    tone: {
      low: "bg-danger-subtle text-danger",
      ok: "bg-success-subtle text-success",
      unknown: "bg-surface-sunken text-text-secondary",
    },
  },
});

const qty = (n: number | null) =>
  n === null ? "—" : Number(n).toLocaleString("th-TH", { maximumFractionDigits: 2 });

export function MaterialCountRow({
  row,
  name,
  defaultValue,
  readOnly,
  countedToday,
  showNotConfigured,
}: {
  row: MaterialRow;
  name: string;
  defaultValue: string;
  readOnly: boolean;
  countedToday: boolean;
  showNotConfigured: boolean;
}) {
  const tone = row.is_low === true ? "low" : row.is_low === false ? "ok" : "unknown";
  const state =
    row.is_low === true
      ? `ใกล้หมด · เหลือ ${qty(row.remaining_qty)}`
      : row.is_low === false
        ? `พอใช้ · เหลือ ${qty(row.remaining_qty)}`
        : "ยังไม่ตั้งค่า";

  return (
    <div className="flex flex-col gap-2 border-b border-border px-4 py-3 last:border-b-0">
      <div className="flex items-start justify-between gap-2">
        <span className="min-w-0 flex-1 break-words text-body text-text-primary">
          {row.name_th}
        </span>
        {countedToday ? <span className={badge({ tone })}>{state}</span> : null}
      </div>
      <WholeInput
        label={`ยอดนับ ${row.name_th}`}
        name={name}
        unit={row.unit}
        defaultValue={defaultValue}
        readOnly={readOnly}
      />
      {row.full_stock_qty === null ? (
        showNotConfigured ? (
          <span className="text-caption text-text-muted">
            ยังไม่ตั้งค่าสต็อกเต็ม — นับได้ แต่ระบบยังเตือนของใกล้หมดไม่ได้
          </span>
        ) : null
      ) : (
        <span className="text-caption text-text-muted">
          สต็อกเต็ม {qty(row.full_stock_qty)} {row.unit}
          {row.alert_threshold_qty === null
            ? " · ยังไม่ตั้งเกณฑ์เตือน"
            : ` · เตือนเมื่อต่ำกว่า ${qty(row.alert_threshold_qty)}`}
        </span>
      )}
    </div>
  );
}
