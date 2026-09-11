import "server-only";

import type { BranchDay } from "@/features/branch/context";

/* The reads BR 01, BR 03, BR 08 and BR 09 share (card ^ref-52). Each view's WHERE is the role
 * test (R34); these add only the branch or the report. */

type Db = BranchDay["supabase"];

/** v_rice_day's row for one report (view 270). null fields are "not recorded", never 0. */
export type RiceDay = {
  daily_report_id: string;
  model: "EXTERNAL_COOKED" | "SELF_COOK" | null;
  rice_record_id: string | null;
  carried_in_cooked_kg: number | null;
  cooked_received_kg: number | null;
  raw_purchased_kg: number | null;
  cooked_today_kg: number | null;
  raw_remaining_kg: number | null;
  cooked_remaining_kg: number | null;
};

/** v_material_alerts' row: every active item at the branch, so the list is whatever
 * packaging_items holds, never a constant 7. is_low is the view's R10 verdict (Finding 4). */
export type MaterialRow = {
  packaging_item_id: string;
  packaging_code: string;
  name_th: string;
  unit: string;
  full_stock_qty: number | null;
  alert_threshold_qty: number | null;
  remaining_qty: number | null;
  counted_on: string | null;
  is_low: boolean | null;
};

export async function readRiceDay(db: Db, reportId: string) {
  const { data, error } = await db
    .from("v_rice_day")
    .select(
      "daily_report_id, model, rice_record_id, carried_in_cooked_kg, cooked_received_kg, raw_purchased_kg, cooked_today_kg, raw_remaining_kg, cooked_remaining_kg",
    )
    .eq("daily_report_id", reportId)
    .maybeSingle();
  return { row: (data ?? null) as RiceDay | null, error: error?.message ?? null };
}

export async function readMaterials(db: Db, locationId: string) {
  const { data, error } = await db
    .from("v_material_alerts")
    .select(
      "packaging_item_id, packaging_code, name_th, unit, full_stock_qty, alert_threshold_qty, remaining_qty, counted_on, is_low",
    )
    .eq("location_id", locationId)
    .order("packaging_code");
  return { rows: (data ?? []) as MaterialRow[], error: error?.message ?? null };
}

/** v_branch_expenses' row (view 271): the amounts the branch typed itself (v0.2:59, :65). */
export type ExpenseRow = {
  branch_expense_id: string;
  category: string;
  amount_thb: number;
  paid_by_person: string;
  detail: string | null;
};

export async function readExpenses(db: Db, reportId: string) {
  const { data, error } = await db
    .from("v_branch_expenses")
    .select("branch_expense_id, category, amount_thb, paid_by_person, detail")
    .eq("daily_report_id", reportId)
    .order("created_at");
  return { rows: (data ?? []) as ExpenseRow[], error: error?.message ?? null };
}

/** A stored figure as a form's defaultValue: "" for null, never "0". */
export function asField(value: number | null | undefined): string {
  return value === null || value === undefined ? "" : String(value);
}
