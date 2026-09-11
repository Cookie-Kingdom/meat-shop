import "server-only";

import { createClient } from "@/lib/supabase/server";
import { MESSAGES as BRANCH_MESSAGES } from "./branch";
import { toResult, type Messages, type RpcResult } from "./result";

/* Typed wrappers over the three branch writes BR 03, BR 07 and BR 08 make (card ^ref-52,
 * PLAN-material-screens.md T3; contracts in PLAN-materials.md):
 *   fn_record_rice            (^ref-48)  morning and evening halves of one row
 *   fn_record_physical_count  (^ref-49)  one batch per BR 08 save
 *   fn_record_branch_expense  (^ref-51)  one row per save
 *
 * All three are L2 only (fn_require_branch, lane D Finding 3); the (branch) layout mirrors that.
 * THE KEY IS AN ARGUMENT, minted once per page view by the server component (branch.ts's rule).
 * Every named raise has a Thai sentence; an unmapped one is shown verbatim (result.ts). */

/** BR 07's expense picker. The CODE is sent, never the label (PLAN Finding 8): lane K's cost
 * report splits packaging spend on exactly 'PACKAGING'. The column is free text, so this list
 * is a convention, not a constraint. */
export const EXPENSE_CATEGORIES = [
  { code: "PACKAGING", label: "วัสดุแพ็คเกจจิ้ง" },
  { code: "RICE", label: "ข้าวเหนียว" },
  { code: "CHILLI_PASTE", label: "น้ำพริก" },
  { code: "OTHER", label: "ค่าใช้จ่ายอื่น" },
] as const;

export const EXPENSE_LABEL: Record<string, string> = Object.fromEntries(
  EXPENSE_CATEGORIES.map((c) => [c.code, c.label]),
);

const MESSAGES: Messages = {
  ...BRANCH_MESSAGES,

  // Rice (fn_record_rice).
  RICE_MODEL_NOT_SET:
    "เจ้าของร้านยังไม่ได้ตั้งรูปแบบข้าวเหนียวของสาขานี้ — แจ้งเจ้าของร้านก่อน",
  RICE_WEIGHT_INVALID: "น้ำหนักข้าวต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป",
  RICE_FIELD_NOT_FOR_MODEL:
    "ช่องข้าวที่ส่งมาไม่ใช่ของรูปแบบข้าวของสาขานี้ — โหลดหน้านี้ใหม่",
  RICE_VALUES_REQUIRED: "ยังไม่ได้กรอกน้ำหนักข้าว — กรอกอย่างน้อยหนึ่งช่อง",

  // The count (fn_record_physical_count).
  COUNTS_REQUIRED: "ยังไม่ได้กรอกยอดนับ — กรอกอย่างน้อยหนึ่งรายการ",
  COUNT_ITEM_INVALID: "รายการนับไม่ถูกต้อง — โหลดหน้านี้ใหม่แล้วนับอีกครั้ง",
  COUNT_QTY_INVALID: "ยอดนับต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป",
  QTY_NOT_WHOLE_UNITS: "วัสดุและน้ำพริกนับเป็นจำนวนเต็ม",
  PACKAGING_ITEM_REQUIRED: "รายการนับวัสดุไม่ระบุวัสดุ — โหลดหน้านี้ใหม่",
  PACKAGING_ITEM_NOT_FOUND: "วัสดุนี้ถูกเลิกใช้แล้ว — โหลดหน้านี้ใหม่แล้วนับอีกครั้ง",
  SMOKE_GROUP_REQUIRED: "การนับเนื้อต้องระบุล็อตและวันรมควัน",
  SMOKE_GROUP_NOT_FOUND: "ไม่พบวันรมควันที่นับ — โหลดหน้านี้ใหม่",
  COUNT_ITEM_DUPLICATED: "มีรายการนับซ้ำในชุดเดียวกัน — โหลดหน้านี้ใหม่",

  // The expense (fn_record_branch_expense).
  EXPENSE_CATEGORY_REQUIRED: "เลือกประเภทค่าใช้จ่ายก่อน",
  EXPENSE_AMOUNT_INVALID: "จำนวนเงินต้องมากกว่า 0",
  PAID_BY_REQUIRED: "ต้องระบุชื่อผู้สำรองจ่าย — ค่าใช้จ่ายที่ไม่มีผู้จ่ายเบิกคืนไม่ได้",
};

/** Each visit sends only its own fields; an absent one keeps what is on the row, and a value
 * can be corrected but not cleared (fn_record_rice's merge). */
export type RiceFigures = {
  cooked_received_kg?: number;
  raw_purchased_kg?: number;
  cooked_today_kg?: number;
  raw_remaining_kg?: number;
  cooked_remaining_kg?: number;
};

export async function recordRice(args: {
  idempotencyKey: string;
  dailyReportId: string;
  figures: RiceFigures;
}): Promise<RpcResult> {
  const f = args.figures;
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_record_rice", {
    p_idempotency_key: args.idempotencyKey,
    p_daily_report_id: args.dailyReportId,
    p_cooked_received_kg: f.cooked_received_kg ?? null,
    p_raw_purchased_kg: f.raw_purchased_kg ?? null,
    p_cooked_today_kg: f.cooked_today_kg ?? null,
    p_raw_remaining_kg: f.raw_remaining_kg ?? null,
    p_cooked_remaining_kg: f.cooked_remaining_kg ?? null,
  });
  return toResult(error, MESSAGES);
}

/** One element per counted item. Only typed rows are sent: not counted is not zero. */
export type CountLine =
  | { item_type: "PACKAGING"; packaging_item_id: string; counted_qty: number }
  | { item_type: "CHILLI_PASTE"; counted_qty: number };

export async function recordPhysicalCount(args: {
  idempotencyKey: string;
  dailyReportId: string;
  counts: CountLine[];
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_record_physical_count", {
    p_idempotency_key: args.idempotencyKey,
    p_daily_report_id: args.dailyReportId,
    p_counts: args.counts,
  });
  return toResult(error, MESSAGES);
}

export async function recordBranchExpense(args: {
  idempotencyKey: string;
  dailyReportId: string;
  category: string;
  /** Two decimals at most, checked by the action (toHundredths); passed, never computed. */
  amountThb: number;
  paidByPerson: string;
  detail: string | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_record_branch_expense", {
    p_idempotency_key: args.idempotencyKey,
    p_daily_report_id: args.dailyReportId,
    p_category: args.category,
    p_amount_thb: args.amountThb,
    p_paid_by_person: args.paidByPerson,
    p_detail: args.detail,
  });
  return toResult(error, MESSAGES);
}
