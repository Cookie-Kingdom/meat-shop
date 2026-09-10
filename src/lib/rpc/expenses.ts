import "server-only";

import { createClient } from "@/lib/supabase/server";

/* Typed wrapper over fn_record_owner_expense (card ^ref-54; the function is ^ref-53).
 *
 * Every write goes through a plpgsql function by RPC, in one transaction, with a
 * client-generated idempotency key (ADR-002, ADR-005). Never `supabase.from(...)` for a write.
 *
 * THE KEY IS MINTED WHEN THE FORM RENDERS, not in the Server Action — the opposite of OW 10's
 * `config.ts`, and on purpose. A config write's retry rides a natural key (its date, R38), so a
 * key per submit is enough there. An owner expense has none (R39: two identical gas refills
 * are two rows), so the only thing that makes a double tap, or a re-POST after a dropped
 * connection, land ONCE is the same key arriving twice. The form is server-rendered, so it
 * mints once per render; a fresh render — after a save or a refusal — is a new attempt and
 * rightly gets a new key. There is no client component whose re-render could mint another.
 *
 * AN UNMAPPED ERROR IS SHOWN VERBATIM, NEVER SWALLOWED. A silent catch is how a refused
 * expense reads as a recorded one.
 */

export type ExpenseKind = "INVESTMENT" | "MONTHLY_FIXED" | "OTHER";

/** The named raises of fn_record_owner_expense, in Thai. */
const MESSAGES: Record<string, string> = {
  EXPENSE_KIND_REQUIRED: "เลือกหมวดก่อน",
  EXPENSE_DATE_REQUIRED: "ต้องระบุวันที่จ่าย",
  EXPENSE_AMOUNT_INVALID: "จำนวนเงินต้องมากกว่า 0",
  EXPENSE_DETAIL_REQUIRED:
    "ต้องกรอกรายละเอียด — ใช้จับคู่รายการนี้กับรายการโอนในบัญชี",
  EXPENSE_MONTH_REQUIRED: "ค่าใช้จ่ายประจำเดือนต้องระบุว่าเป็นของเดือนไหน",
  EXPENSE_MONTH_NOT_ALLOWED:
    "หมวดนี้นับเข้าเดือนของวันที่จ่ายเสมอ ไม่ต้องระบุเดือน",
  EXPENSE_MONTH_INVALID: "เดือนไม่ถูกต้อง",
  EXPENSE_IDEMPOTENCY_CONFLICT:
    "คำสั่งบันทึกนี้ถูกใช้กับรายการอื่นไปแล้ว — กรอกใหม่อีกครั้ง",
  LOCATION_NOT_FOUND: "ไม่พบสาขาที่เลือก",
  IDEMPOTENCY_KEY_REQUIRED: "คำสั่งบันทึกไม่สมบูรณ์ กรุณาลองใหม่",
  FORBIDDEN: "เฉพาะเจ้าของร้านบันทึกค่าใช้จ่ายนี้ได้",
  NO_ACTOR: "บัญชีนี้ถูกปิดใช้งานแล้ว",
};

export type RpcResult =
  | { ok: true }
  | { ok: false; code: string; message: string };

/** Postgres reports our raises as `CODE: detail`. Split the code off for the Thai sentence. */
function toResult(error: { message: string } | null): RpcResult {
  if (!error) return { ok: true };
  const code = error.message.match(/^([A-Z_]+):/)?.[1] ?? "";
  return { ok: false, code, message: MESSAGES[code] ?? error.message };
}

export async function recordOwnerExpense(args: {
  idempotencyKey: string;
  kind: ExpenseKind;
  /** yyyy-mm-dd, the day it was paid. */
  eventDate: string;
  amountThb: number;
  detail: string;
  /** YYYY-MM — only for MONTHLY_FIXED, the month the cost covers. */
  expenseMonth?: string | null;
  /** null = central. */
  locationId?: string | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_record_owner_expense", {
    p_idempotency_key: args.idempotencyKey,
    p_kind: args.kind,
    p_event_date: args.eventDate,
    p_amount_thb: args.amountThb,
    p_detail: args.detail,
    p_expense_month: args.expenseMonth ?? null,
    p_location_id: args.locationId ?? null,
  });
  return toResult(error);
}
