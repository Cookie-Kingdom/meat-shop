import "server-only";

import { createClient } from "@/lib/supabase/server";
import type { RpcResult } from "@/lib/rpc/config";

/* Typed wrapper over fn_set_smoke_fee_override (card ^ref-32, screen ^ref-33).
 *
 * Every write goes through a plpgsql function called by RPC, in one transaction, with a
 * client-generated uuid idempotency key (ADR-002, ADR-005). The key is minted in the Server
 * Action, once per submit — never during render (R38, R4).
 *
 * AN UNMAPPED ERROR IS SHOWN VERBATIM, NEVER SWALLOWED. A silent catch is how a refused
 * override reads as a saved one, and the Owner goes on believing a discount was recorded.
 */

/** The function's named raises, in Thai. */
const MESSAGES: Record<string, string> = {
  SMOKE_FEE_OVERRIDE_INVALID:
    "ค่ารมควันที่เรียกเก็บจริงติดลบไม่ได้ — ถ้าโรงรมไม่คิดเงินรอบนี้ ให้กรอก 0",
  SMOKE_FEE_REASON_REQUIRED:
    "ต้องระบุเหตุผลที่ค่ารมควันต่างจากอัตราที่ตั้งไว้ เช่น ส่วนลดที่ตกลงกับโรงรม",
  LOT_NOT_FOUND: "ไม่พบล็อตนี้",
  LOT_IS_OPENING:
    "ล็อตยอดยกมาไม่มีค่ารมควัน — ต้นทุนของล็อตนี้บันทึกไว้ที่ยอดยกมาแล้ว",
  IDEMPOTENCY_KEY_REQUIRED: "คำสั่งบันทึกไม่สมบูรณ์ กรุณาลองใหม่",
  FORBIDDEN: "เฉพาะเจ้าของร้านเท่านั้นที่แก้ค่ารมควันได้",
  NO_ACTOR: "บัญชีนี้ถูกปิดใช้งานแล้ว",
};

/** Postgres reports our raises as `CODE: detail`. Split the code off so the screen shows the
 * Thai sentence for the ones we named and the raw message for the ones we did not. */
function toResult(error: { message: string } | null): RpcResult {
  if (!error) return { ok: true };
  const code = error.message.match(/^([A-Z_]+):/)?.[1] ?? "";
  return { ok: false, code, message: MESSAGES[code] ?? error.message };
}

/** Set what the chef house actually charged for one lot, or clear it with `amountThb: null`
 * to return the lot to the configured rate (R41). Clearing takes no reason. */
export async function setSmokeFeeOverride(args: {
  idempotencyKey: string;
  lotId: string;
  amountThb: number | null;
  reason: string | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_set_smoke_fee_override", {
    p_idempotency_key: args.idempotencyKey,
    p_lot_id: args.lotId,
    p_amount_thb: args.amountThb,
    p_reason: args.reason,
  });
  return toResult(error);
}
