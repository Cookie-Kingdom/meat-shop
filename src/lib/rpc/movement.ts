import "server-only";

import { createClient } from "@/lib/supabase/server";

/* Typed wrappers over the three F8 write functions the OW 05–07 screens call (card ^ref-37,
 * functions from ^ref-34, ^ref-35, ^ref-36). One wrapper per RPC, nothing else.
 *
 *   OW 05 → fn_set_return_pickup_date   (BR17 — the only input is the date)
 *   OW 06 → fn_confirm_central_intake   (BR12 — a route assertion in front of the receipt)
 *   OW 07 → fn_allocate_to_branch       (BR11, BR07 — central stock only, FIFO by smoke date)
 *
 * Every write goes through a plpgsql function in one transaction with a client-generated key
 * (ADR-002, ADR-005). THE KEY ARRIVES AS AN ARGUMENT, and it is minted when the Server
 * Component renders the form, not when the action runs (PLAN-movement.md Finding 13). A key
 * minted per action call turns a resubmit after a lost response into a second allocation. A
 * key rendered into the form turns it into a replay: fn_allocate_to_branch returns the same
 * line id (TC-36), and fn_confirm_transport_receipt returns the same receipt.
 *
 * Weights travel as the validated decimal STRING the Owner typed, never a JS number:
 * numeric(12,2) is the DB's arithmetic, and PostgREST casts the string itself.
 *
 * AN UNMAPPED ERROR IS SHOWN VERBATIM, NEVER SWALLOWED. The role, the stock and the FIFO rule
 * are all decided in the database (ADR-004). This file only translates the refusal.
 */

/** The key for ONE form instance, called by the Server Component that renders the form
 * (Finding 13). The form is stable across client re-renders and a double submit. A successful
 * submit revalidates the page, which renders the next key. */
export function newFormKey(): string {
  return crypto.randomUUID();
}

export type RpcResult =
  { ok: true; id: string } | { ok: false; code: string; message: string };

const MIXED_UP =
  "รายการนี้บันทึกไปแล้วด้วยข้อมูลอื่น — โหลดหน้าใหม่แล้วตรวจยอดก่อนทำรายการอีกครั้ง";
const CONFIG_BROKEN =
  "ค่าตั้งต้นที่รายการนี้ใช้มีรูปแบบไม่ถูกต้อง — ตรวจที่หน้า OW 10 ตั้งค่าระบบ";
const BRANCH_FROM_CENTRAL_ONLY = "ของจะเข้าสาขาได้ต้องออกจากคลังกลางเท่านั้น";

/** The named raises of the three functions and of everything they call, in Thai. */
const MESSAGES: Record<string, string> = {
  // shared
  IDEMPOTENCY_KEY_REQUIRED:
    "คำสั่งบันทึกไม่สมบูรณ์ — โหลดหน้าใหม่แล้วลองอีกครั้ง",
  NO_ACTOR: "บัญชีนี้ถูกปิดใช้งานแล้ว",
  FORBIDDEN: "บัญชีนี้ไม่มีสิทธิ์ทำรายการนี้",
  CONFIG_NOT_SET:
    "เจ้าของยังไม่ได้ตั้งค่าที่รายการนี้ต้องใช้ — ตั้งได้ที่หน้า OW 10 ตั้งค่าระบบ",
  CONFIG_EVENT_DATE_REQUIRED: "ต้องระบุวันที่ของรายการ",
  CONFIG_WRONG_TYPE: CONFIG_BROKEN,
  CONFIG_VALUE_INVALID: CONFIG_BROKEN,
  LOT_NOT_FOUND: "ไม่พบ Lot นี้ในระบบ",
  LOCATION_NOT_FOUND: "ไม่พบสถานที่นี้ในระบบ",
  INSUFFICIENT_STOCK: "สต็อกไม่พอ — ระบบไม่ยอมให้ยอดติดลบ",

  // OW 05 — fn_set_return_pickup_date
  LOT_NOT_CLOSED:
    "Lot นี้ยังไม่ปิด — นัดวันรับขากลับได้หลังเชียงใหม่ปิด Lot แล้วเท่านั้น",
  RETURN_PICKUP_DATE_REQUIRED: "ต้องระบุวันรับของขากลับ",
  RETURN_PICKUP_DATE_INVALID: "วันรับของต้องไม่ก่อนวันที่ปิด Lot",
  RETURN_ALREADY_DISPATCHED:
    "Lot นี้ขึ้นรถขากลับแล้ว เปลี่ยนวันรับไม่ได้ เพราะรอบรถสร้างตามวันเดิม",

  // OW 06 — fn_confirm_central_intake → fn_confirm_transport_receipt
  LINE_NOT_FOUND: "ไม่พบรายการขนส่งนี้",
  NOT_A_CENTRAL_INTAKE:
    "รายการนี้ไม่ใช่ของขากลับจากเชียงใหม่เข้าคลังกลาง จึงรับที่หน้านี้ไม่ได้",
  RECEIPT_EVENT_DATE_REQUIRED: "ต้องระบุวันที่รับของ",
  RECEIPT_WEIGHT_INVALID: "น้ำหนักรับจริงต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป",
  RECEIPT_BAG_COUNT_INVALID: "จำนวนถุงต้องมากกว่า 0",
  LINE_ALREADY_RECEIVED:
    "รายการนี้รับเข้าคลังไปแล้ว — ยอดที่ยังค้างดูได้ในรายการรับไม่ครบ",
  PARTIAL_RECEIPT_NOT_ALLOWED:
    "ระบบตั้งไว้ไม่ให้รับของไม่ครบ — น้ำหนักรับจริงน้อยกว่าที่ส่งออกจากเชียงใหม่",
  VARIANCE_REASON_REQUIRED: "ส่วนต่างเกินเกณฑ์ — กรอกเหตุผลแล้วบันทึกต่อได้",

  // OW 07 — fn_allocate_to_branch → fn_create_transport_run, fn_dispatch_transport_line
  LINE_IDEMPOTENCY_CONFLICT: MIXED_UP,
  RUN_IDEMPOTENCY_CONFLICT: MIXED_UP,
  BAG_COUNT_REQUIRED: "ต้องระบุจำนวนถุงที่ส่ง อย่างน้อย 1 ถุง",
  DISPATCH_WEIGHT_INVALID: "น้ำหนักที่ส่งต้องมากกว่า 0",
  SMOKE_GROUP_REQUIRED: "ต้องเลือกกลุ่มวันรมควันและ Lot ที่จะส่ง",
  NOT_A_BRANCH: "ปลายทางที่เลือกไม่ใช่สาขา",
  NOT_IN_CENTRAL_STOCK:
    "กลุ่มนี้ไม่มีของแช่แข็งในคลังกลางแล้ว — ส่งสาขาได้เฉพาะของที่รับเข้าคลังกลางแล้ว",
  INSUFFICIENT_CENTRAL_STOCK: "น้ำหนักที่ขอมากกว่ายอดในคลังกลางของ Lot นี้",
  FIFO_OVERRIDE_REASON_REQUIRED:
    "คลังกลางยังมีวันรมควันที่เก่ากว่า — ต้องกรอกเหตุผลที่ข้าม FIFO",
  RUN_FARE_INVALID: "รอบรถส่งสาขาต้องไม่มีค่าขนส่ง",
  BRANCH_LEG_NOT_FREE: "รอบรถส่งสาขาต้องไม่มีค่าขนส่ง",
  BRANCH_LEG_ROUTE_INVALID: BRANCH_FROM_CENTRAL_ONLY,
  BRANCH_LEG_ORIGIN_INVALID: BRANCH_FROM_CENTRAL_ONLY,
};

/** Postgres reports our raises as `CODE: detail`. The code picks the Thai sentence; a raise we
 * did not name comes back as the raw message. */
function toResult(data: unknown, error: { message: string } | null): RpcResult {
  if (!error) return { ok: true, id: String(data) };
  const code = error.message.match(/^([A-Z_]+):/)?.[1] ?? "";
  return { ok: false, code, message: MESSAGES[code] ?? error.message };
}

/** OW 05. L1 or a can_receive_central delegate (fn_require_central_receiver). Writes no ledger
 * row. A pickup date is a commitment, and the truck is created on OW 02 (BR17). */
export async function setReturnPickupDate(args: {
  idempotencyKey: string | null;
  lotId: string;
  returnPickupDate: string | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_set_return_pickup_date", {
    p_idempotency_key: args.idempotencyKey,
    p_lot_id: args.lotId,
    p_return_pickup_date: args.returnPickupDate,
  });
  return toResult(data, error);
}

/** OW 06. The return leg signed for into central. Variance is ALERT, never BLOCK (BR12): past
 * the threshold the function demands a reason and then records the receipt. No bag count and
 * no settlement — a return leg carries no bags, and settlement has no config vocabulary yet
 * (PLAN-movement.md Finding 14). */
export async function confirmCentralIntake(args: {
  idempotencyKey: string | null;
  lineId: string;
  eventDate: string | null;
  receivedWeightKg: string;
  varianceReason: string | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_confirm_central_intake", {
    p_idempotency_key: args.idempotencyKey,
    p_line_id: args.lineId,
    p_event_date: args.eventDate,
    p_received_weight_kg: args.receivedWeightKg,
    p_variance_reason: args.varianceReason,
  });
  return toResult(data, error);
}

/** OW 07. One smoke-date group to one branch, by weight AND bag count (v0.2:108). The origin
 * is not an argument: the function takes it from v_central_available, which is what makes
 * "nothing reaches a branch without passing through central" a property of the call, not of
 * this screen (BR11). */
export async function allocateToBranch(args: {
  idempotencyKey: string | null;
  branchLocationId: string;
  eventDate: string | null;
  smokeDateGroupId: string;
  dispatchedWeightKg: string;
  bagCount: number;
  fifoOverrideReason: string | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_allocate_to_branch", {
    p_idempotency_key: args.idempotencyKey,
    p_branch_location_id: args.branchLocationId,
    p_event_date: args.eventDate,
    p_smoke_date_group_id: args.smokeDateGroupId,
    p_dispatched_weight_kg: args.dispatchedWeightKg,
    p_bag_count: args.bagCount,
    p_fifo_override_reason: args.fifoOverrideReason,
  });
  return toResult(data, error);
}
