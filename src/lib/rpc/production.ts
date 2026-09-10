import "server-only";

import type { RpcResult } from "@/lib/rpc/config";
import { createClient } from "@/lib/supabase/server";

export { newIdempotencyKey, type RpcResult } from "@/lib/rpc/config";

/* Typed wrappers over the four chef-house write functions CM 02–05 call (card ^ref-30,
 * functions from ^ref-26 … ^ref-29).
 *
 * Every write goes through a plpgsql function called by RPC, in one transaction, with a
 * client-generated uuid idempotency key (ADR-002, ADR-005). Never `supabase.from(...)` for a
 * write. The actor is never a parameter: `fn_require_operator` reads it off the JWT, so a
 * caller cannot sign as somebody else.
 *
 * THE KEY IS MINTED WHEN THE FORM OPENS, not here and not on submit (REVIEW item 10,
 * SmokeLogForm contract). The page renders it, the form holds it across failed attempts, and
 * a success hands back a fresh one. That is what makes a dropped-connection retry R4's replay
 * — the log returns its id, the bags return their count — instead of a second batch.
 *
 * AN UNMAPPED ERROR IS SHOWN VERBATIM, NEVER SWALLOWED. A silent catch is how a refused write
 * reads as a saved one.
 */

/** Every named raise the four functions (and the R8 trigger behind them) can send, in Thai.
 * The sentence says what to do next, because the operator is standing at the scale. */
const MESSAGES: Record<string, string> = {
  IDEMPOTENCY_KEY_REQUIRED:
    "คำสั่งบันทึกไม่สมบูรณ์ กรุณาโหลดหน้าใหม่แล้วลองอีกครั้ง",
  NO_ACTOR: "บัญชีนี้ถูกปิดใช้งานแล้ว — ติดต่อ Owner",
  FORBIDDEN: "บัญชีนี้ไม่มีสิทธิ์บันทึกงานโรงรม",
  FORBIDDEN_LOCATION: "บัญชีนี้ไม่ได้ประจำโรงรมของ Lot นี้ — ติดต่อ Owner",
  NOT_ASSIGNED_OPERATOR: "Lot นี้ไม่ได้มอบหมายให้คุณ — ติดต่อ Owner",
  LOT_NOT_FOUND: "ไม่พบ Lot นี้",
  LOT_STATE_INVALID:
    "สถานะของ Lot นี้ยังบันทึกขั้นตอนนี้ไม่ได้ — ตรวจว่ารถออกจาก Foodiva และบันทึกรับเนื้อแล้ว",
  LOT_CLOSED: "Lot นี้ปิดแล้ว แก้ไขไม่ได้ — ต้องขอ Owner ปลดล็อกก่อน",
  CONFIG_NOT_SET:
    "Owner ยังไม่ได้ตั้งค่าที่ขั้นตอนนี้ต้องใช้ — แจ้ง Owner ให้ตั้งค่าก่อน แล้วค่อยบันทึกใหม่",

  // CM 02 / CM 03 — fn_record_lot_receipt
  RECEIPT_EVENT_DATE_REQUIRED: "ต้องระบุวันที่รับเนื้อ",
  RECEIPT_WEIGHT_INVALID: "น้ำหนักรับต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป",
  POST_DRAIN_WEIGHT_INVALID: "น้ำหนักก่อนสโมคต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป",
  POST_DRAIN_EXCEEDS_RECEIVED:
    "น้ำหนักก่อนสโมคเกินน้ำหนักที่รับเข้ามา — ชั่งใหม่ หรือแก้น้ำหนักรับก่อน",
  VARIANCE_REASON_REQUIRED:
    "น้ำหนักรับต่างจากที่ Foodiva ส่งเกินเกณฑ์ที่ Owner ตั้งไว้ — ใส่เหตุผลแล้วกดบันทึกอีกครั้ง",

  // CM 04 top half — fn_upsert_smoke_daily_log
  LOG_EVENT_DATE_REQUIRED: "ต้องระบุวันที่รมควัน",
  INPUT_SOURCES_REQUIRED:
    "ต้องระบุอย่างน้อยหนึ่ง Lot ที่นำเนื้อไปรมควัน พร้อมน้ำหนักที่นำไป",
  SOURCE_LOT_REQUIRED: "มีแถวที่ยังไม่ได้เลือก Lot ต้นทาง",
  SOURCE_WEIGHT_INVALID: "น้ำหนักที่นำไปรมควันต้องมากกว่า 0",
  SOURCE_LOT_DUPLICATED: "เลือก Lot เดียวกันซ้ำสองแถว — รวมให้เป็นแถวเดียว",
  SOURCE_LOT_NOT_HERE: "Lot ต้นทางที่เลือกไม่ได้อยู่ที่โรงรมนี้",
  SMOKED_WEIGHT_INVALID: "น้ำหนักหลังผลิตต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป",
  BRINE_WEIGHT_INVALID: "น้ำดองที่ใช้ต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป",
  POST_FREEZE_WEIGHT_INVALID:
    "น้ำหนักหลังแช่แข็งต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป",

  // CM 04 bottom half — fn_record_lot_bags
  SMOKE_DATE_REQUIRED: "ต้องระบุวันที่รมควันของถุง",
  PACK_WEIGHTS_REQUIRED: "ยังไม่มีน้ำหนักแพ็คให้บันทึก",
  PACK_WEIGHT_INVALID: "น้ำหนักแพ็คต้องมากกว่า 0 และมีทศนิยมไม่เกิน 2 ตำแหน่ง",
  SMOKE_LOG_MISSING:
    "ยังไม่มีบันทึกรมควันของวันนี้ — ใส่ Lot ที่นำไปรมควันพร้อมน้ำหนักก่อนบันทึกถุง",
  LOT_BAGS_IDEMPOTENCY_CONFLICT:
    "ชุดถุงนี้ถูกส่งไปแล้วด้วยข้อมูลที่ต่างกัน — โหลดหน้าใหม่แล้วตรวจยอดที่บันทึกแล้วก่อน",

  // CM 05 — fn_close_lot
  LOT_NOT_READY:
    "ยังปิด Lot ไม่ได้ — ต้องมีบันทึกรับเนื้อ และบันทึกรมควันอย่างน้อยหนึ่งวัน",
  INPUT_WEIGHT_MISSING:
    "มีวันที่บันทึกรมควันแต่ไม่มี Lot ต้นทาง — แก้บันทึกวันนั้นก่อนปิด Lot",
  SOURCE_SUM_MISMATCH:
    "ยอดน้ำหนักที่นำไปรมควันไม่ตรงกับผลรวม Lot ต้นทาง — แจ้ง Owner ก่อนปิด Lot",
  LOT_ALREADY_CLOSED: "Lot นี้ปิดไปแล้ว",
};

/** Postgres reports our raises as `CODE: detail`. The two array validators name the element
 * that failed ("bag 2", "source 3"); that number is worth more to the operator than the
 * sentence, so it is carried into the Thai. */
function toResult(error: { message: string } | null): RpcResult {
  if (!error) return { ok: true };
  const code = error.message.match(/^([A-Z_]+):/)?.[1] ?? "";
  const known = MESSAGES[code];
  if (!known) {
    return {
      ok: false,
      code,
      message: `บันทึกไม่สำเร็จ — ${error.message}`,
    };
  }
  const bag =
    code === "PACK_WEIGHT_INVALID" && error.message.match(/bag (\d+)/);
  const src =
    code === "SOURCE_WEIGHT_INVALID" && error.message.match(/source (\d+)/);
  const where = bag
    ? `ถุงที่ ${bag[1]}: `
    : src
      ? `แถว Lot ที่ ${src[1]}: `
      : "";
  return { ok: false, code, message: where + known };
}

/** CM 02 and CM 03 — one row, two visits (R38: `lot_id` is unique and carries the retry).
 * A null post-drain or reason falls back to what is on the row. */
export async function recordLotReceipt(args: {
  idempotencyKey: string;
  lotId: string;
  eventDate: string;
  receivedWeightKg: number;
  postDrainWeightKg?: number | null;
  varianceReason?: string | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_record_lot_receipt", {
    p_idempotency_key: args.idempotencyKey,
    p_lot_id: args.lotId,
    p_event_date: args.eventDate,
    p_received_weight_kg: args.receivedWeightKg,
    p_post_drain_weight_kg: args.postDrainWeightKg ?? null,
    p_variance_reason: args.varianceReason ?? null,
  });
  return toResult(error);
}

export type SourceInput = { lot_id: string; input_weight_kg: number };

/** CM 04's top half. The sources are REPLACED on every call (Finding 3), so the caller sends
 * the whole day's list, never a delta. There is no input weight parameter — it is the R6a
 * roll-up of the sources — and no bag figures, which belong to the smoke-date group. */
export async function upsertSmokeDailyLog(args: {
  idempotencyKey: string;
  lotId: string;
  eventDate: string;
  sources: SourceInput[];
  smokedWeightKg?: number | null;
  brineUsedKg?: number | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_upsert_smoke_daily_log", {
    p_idempotency_key: args.idempotencyKey,
    p_lot_id: args.lotId,
    p_event_date: args.eventDate,
    p_sources: args.sources,
    p_smoked_weight_kg: args.smokedWeightKg ?? null,
    p_brine_used_kg: args.brineUsedKg ?? null,
    p_post_freeze_weight_kg: null,
  });
  return toResult(error);
}

/** CM 04's bottom half: the whole batch in one call, never one call per bag — sixty round
 * trips on a Chiang Mai connection is sixty chances to half-write a batch, which is what the
 * batch key exists to make survivable (R39, Finding 2). A new key on the same smoke date
 * APPENDS; the same key replays. */
export async function recordLotBags(args: {
  idempotencyKey: string;
  lotId: string;
  smokeDate: string;
  packWeightsKg: number[];
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_record_lot_bags", {
    p_idempotency_key: args.idempotencyKey,
    p_lot_id: args.lotId,
    p_smoke_date: args.smokeDate,
    p_pack_weights_kg: args.packWeightsKg,
  });
  return toResult(error);
}

/** CM 05. The response body carries no price and no yield (UAT-15, TC-57), and this wrapper
 * returns none of it anyway: the screen re-reads the locked lot through the views. */
export async function closeLot(args: {
  idempotencyKey: string;
  lotId: string;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_close_lot", {
    p_idempotency_key: args.idempotencyKey,
    p_lot_id: args.lotId,
  });
  return toResult(error);
}
