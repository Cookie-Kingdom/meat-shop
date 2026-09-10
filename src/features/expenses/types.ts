import type { ExpenseKind } from "@/lib/rpc/expenses";

/* OW 09 (card ^ref-54) — the หมวด and the row shape.
 *
 * THE หมวด IS `kind` (PLAN-owner-expenses.md Finding 8). v0.2:110 gives OW 09 "หมวด จำนวนเงิน
 * รายละเอียด และวันที่" for a row that is "รายเดือนหรือมี Investment", and source/ names no
 * other category vocabulary. The labels and hints are the screen's only words for it. */

export const KINDS: readonly ExpenseKind[] = [
  "INVESTMENT",
  "MONTHLY_FIXED",
  "OTHER",
];

export function isKind(value: string): value is ExpenseKind {
  return (KINDS as readonly string[]).includes(value);
}

export const KIND_LABEL: Record<ExpenseKind, string> = {
  INVESTMENT: "เงินลงทุน",
  MONTHLY_FIXED: "ค่าใช้จ่ายประจำเดือน",
  OTHER: "ค่าใช้จ่ายอื่น",
};

/** ADR-020: no depreciation — an investment lands in full in the month it was bought. */
export const KIND_HINT: Record<ExpenseKind, string> = {
  INVESTMENT:
    "อุปกรณ์ เช่น ตู้แช่ ระบบไฟ หม้อหุงข้าว — ลงเต็มจำนวนในเดือนที่ซื้อ ไม่คิดค่าเสื่อม",
  MONTHLY_FIXED: "เช่น ค่าเช่า — ระบุว่าเป็นค่าใช้จ่ายของเดือนไหน",
  OTHER: "รายจ่ายของเจ้าของร้านที่ไม่ใช่สองหมวดข้างบน — นับเข้าเดือนของวันที่จ่าย",
};

/** One row of `v_owner_expenses` (view 191). */
export type ExpenseRow = {
  id: string;
  kind: ExpenseKind;
  event_date: string;
  expense_month: string | null;
  /** The month the P&L books it in — the view's one rule, never re-derived here. */
  pnl_month: string;
  location_id: string | null;
  location_name_th: string | null;
  amount_thb: number;
  detail: string;
  created_by: string;
  created_by_name: string | null;
  created_at: string;
  /** Summed in the database, not in TypeScript (repo CLAUDE.md). */
  month_total_thb: number;
};
