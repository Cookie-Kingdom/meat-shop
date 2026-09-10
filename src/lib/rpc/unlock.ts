import "server-only";

import type { RpcResult } from "@/lib/rpc/config";
import { createClient } from "@/lib/supabase/server";

/* Typed wrappers over the unlock RPCs (card ^ref-08).
 *
 * Every write goes through a plpgsql function called by RPC, in one transaction, with a
 * client-generated uuid idempotency key (ADR-002, ADR-005). The key is minted by the caller
 * — a Server Action, once per submit — never during render (R4). `newIdempotencyKey` lives
 * in `lib/rpc/config.ts` and is imported from there, not copied.
 *
 * An unmapped error is shown verbatim, never swallowed: a refused decision that reads as a
 * saved one leaves a branch locked while the Owner believes it is open.
 */

export type UnlockTarget = "DAILY_REPORT" | "LOT";
export type UnlockDecision = "APPROVED" | "REJECTED";
export type UnlockStatus = "PENDING" | "APPROVED" | "REJECTED" | "EXPIRED";

/** What both RPCs answer. A replay answers the same body (R4). */
export type UnlockBody = {
  unlock_request_id: string;
  status: UnlockStatus;
  decided_by: string | null;
  expires_at: string | null;
  impact?: Record<string, number | null> | null;
};

export type UnlockResult =
  { ok: true; body: UnlockBody } | Extract<RpcResult, { ok: false }>;

/** The named raises of fn_request_unlock / fn_decide_unlock, in Thai. */
const MESSAGES: Record<string, string> = {
  IDEMPOTENCY_KEY_REQUIRED: "คำสั่งบันทึกไม่สมบูรณ์ กรุณาลองใหม่",
  NO_ACTOR: "บัญชีนี้ถูกปิดใช้งานแล้ว",
  FORBIDDEN: "สิทธิ์ของบัญชีนี้ทำรายการปลดล็อกนี้ไม่ได้",
  UNLOCK_TARGET_REQUIRED: "ยังไม่ได้เลือกวันหรือล็อตที่จะขอปลดล็อก",
  UNLOCK_REASON_REQUIRED: "ต้องระบุเหตุผลที่ขอแก้ข้อมูล",
  UNLOCK_TARGET_NOT_FOUND: "ไม่พบวันหรือล็อตที่ขอปลดล็อก",
  UNLOCK_IDEMPOTENCY_CONFLICT: "คำขอนี้ชนกับคำขออื่น กรุณาลองใหม่อีกครั้ง",
  TARGET_NOT_CLOSED:
    "รายการนี้ยังไม่ถูกปิด จึงแก้ไขได้ตามปกติโดยไม่ต้องขอปลดล็อก",
  OUT_OF_SCOPE:
    "ขอปลดล็อกได้เฉพาะวันของสาขาตัวเอง หรือล็อตที่ตัวเองรับผิดชอบเท่านั้น",
  UNLOCK_ALREADY_PENDING:
    "มีคำขอปลดล็อกรายการนี้รอเจ้าของกิจการอนุมัติอยู่แล้ว",
  UNLOCK_ALREADY_OPEN: "รายการนี้ปลดล็อกอยู่แล้ว แก้ไขได้จนกว่าจะหมดเวลา",
  UNLOCK_DECISION_INVALID: "เลือกได้เฉพาะ อนุมัติ หรือ ไม่อนุมัติ",
  DECISION_NOTE_REQUIRED: "ต้องระบุเหตุผลของการตัดสินใจทุกครั้ง",
  UNLOCK_REQUEST_NOT_FOUND: "ไม่พบคำขอปลดล็อกนี้",
  UNLOCK_ALREADY_DECIDED: "คำขอนี้ได้รับการตัดสินใจไปแล้ว",
  CONFIG_NOT_SET:
    "ยังไม่ได้ตั้งค่าการปลดล็อก (ชั่วโมงที่ใช้ได้ หรือจำนวนวันย้อนแก้) — ตั้งที่หน้า ตั้งค่าระบบ ก่อน",
  CONFIG_VALUE_INVALID:
    "ค่าตั้งต้นของการปลดล็อกไม่ถูกต้อง — ตรวจที่หน้า ตั้งค่าระบบ",
};

/** Postgres reports our raises as `CODE: detail`. */
function toResult(
  data: unknown,
  error: { message: string } | null,
): UnlockResult {
  if (error) {
    const code = error.message.match(/^([A-Z_]+):/)?.[1] ?? "";
    return { ok: false, code, message: MESSAGES[code] ?? error.message };
  }
  return { ok: true, body: data as UnlockBody };
}

/** Ask to reopen a closed day (L2, own branch) or a closed lot (L3, own lot). Inside R28's
 * window an L2 day request approves itself; everything else waits for the Owner. */
export async function requestUnlock(args: {
  idempotencyKey: string;
  targetType: UnlockTarget;
  targetId: string;
  reason: string;
}): Promise<UnlockResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_request_unlock", {
    p_idempotency_key: args.idempotencyKey,
    p_target_type: args.targetType,
    p_target_id: args.targetId,
    p_reason: args.reason,
  });
  return toResult(data, error);
}

/** The Owner's decision on a PENDING request (L1 only). The note is required either way. */
export async function decideUnlock(args: {
  idempotencyKey: string;
  unlockRequestId: string;
  decision: UnlockDecision;
  note: string;
}): Promise<UnlockResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_decide_unlock", {
    p_idempotency_key: args.idempotencyKey,
    p_unlock_request_id: args.unlockRequestId,
    p_decision: args.decision,
    p_decision_note: args.note,
  });
  return toResult(data, error);
}
