import "server-only";

import { createClient } from "@/lib/supabase/server";

/* Typed wrappers over the four transport writers — fn_create_transport_run,
 * fn_dispatch_transport_line, fn_allocate_freight (^ref-22, ^ref-23) and
 * fn_confirm_transport_receipt (^ref-22, amended by ^ref-35). Screen ^ref-24, lane F.
 *
 * Every write is a plpgsql function called by RPC, in one transaction, with a
 * client-generated uuid idempotency key (ADR-002, ADR-005). Never `supabase.from(...)` for a
 * write.
 *
 * THE KEY IS AN ARGUMENT. OW 02 mints one key per form render and derives each step's key
 * from it (md5 of `<form key>:run`, `:line:<lot>`, `:alloc`), so a double tap or a retry
 * after a dropped connection replays every step instead of booking a second truck or a
 * second IN_TRANSIT row (Seam 2).
 *
 * AN UNMAPPED ERROR IS SHOWN VERBATIM, NEVER SWALLOWED. For the codes whose detail matters
 * — which config key is missing, which lot is short — the Thai sentence keeps the database's
 * detail after it.
 */

export type RpcResult<T> =
  { ok: true; data: T } | { ok: false; code: string; message: string };

const MESSAGES: Record<string, string> = {
  IDEMPOTENCY_KEY_REQUIRED:
    "คำสั่งบันทึกไม่สมบูรณ์ กรุณาเปิดหน้านี้ใหม่แล้วลองอีกครั้ง",
  FORBIDDEN:
    "บัญชีนี้ไม่มีสิทธิ์ทำรายการนี้ — ผู้ยืนยันรับของต้องเป็นผู้ดูแลปลายทาง",
  FORBIDDEN_LOCATION: "บัญชีนี้ไม่ได้ดูแลสถานที่ปลายทางของรายการนี้",
  NO_ACTOR: "บัญชีนี้ถูกปิดใช้งานแล้ว",
  CONFIG_NOT_SET:
    "ยังไม่ได้ตั้งค่าที่รายการนี้ต้องใช้ ณ วันที่นี้ — ตั้งได้ที่หน้าตั้งค่าระบบ ระบบไม่เดาค่าให้",
  CONFIG_WRONG_TYPE:
    "วิธีเฉลี่ยค่าขนส่งในการตั้งค่าบันทึกผิดชนิด — ต้องเป็นข้อความ BY_LOT_WEIGHT, EQUAL_SPLIT หรือ MANUAL",
  CONFIG_VALUE_INVALID:
    "วิธีเฉลี่ยค่าขนส่งในการตั้งค่าไม่ถูกต้อง — ต้องเป็น BY_LOT_WEIGHT, EQUAL_SPLIT หรือ MANUAL",
  RUN_ROUTE_REQUIRED: "ต้องระบุเส้นทางรถ",
  RUN_EVENT_DATE_REQUIRED: "ต้องระบุวันที่รถรับของ",
  RUN_FARE_INVALID: "ค่าเที่ยวรถต้องไม่ติดลบ",
  RUN_IDEMPOTENCY_CONFLICT:
    "คำสั่งนี้สร้างรอบรถไปแล้วด้วยข้อมูลชุดก่อนหน้า — ตรวจรายการรอบรถด้านล่างก่อนสร้างใหม่ ระบบไม่สร้างซ้ำ",
  BRANCH_LEG_NOT_FREE: "รถส่งสาขาไม่มีค่าขนส่ง",
  RETURN_LOTS_REQUIRED: "รถขากลับต้องระบุล็อตที่จะรับ",
  RETURN_NOT_SCHEDULED: "มีล็อตที่ยังไม่ได้นัดวันรับขากลับ",
  LOT_NOT_FOUND: "ไม่พบล็อตนี้",
  LOT_REQUIRED: "ทุกการขนส่งเนื้อต้องระบุล็อต",
  DISPATCH_WEIGHT_INVALID: "น้ำหนักที่ส่งต้องมากกว่า 0 กก.",
  LINE_IDEMPOTENCY_CONFLICT:
    "คำสั่งนี้ใส่ล็อตขึ้นรถไปแล้วด้วยข้อมูลชุดก่อนหน้า — ตรวจรอบรถก่อนทำซ้ำ ระบบไม่ส่งซ้ำ",
  RUN_NOT_FOUND: "ไม่พบรอบรถนี้",
  DESTINATION_REQUIRED: "ต้องระบุปลายทาง",
  LOCATION_NOT_FOUND: "ไม่พบสถานที่นี้ในระบบ",
  ORIGIN_LOCATION_INVALID:
    "รถขาไปจาก Foodiva ไม่มีต้นทางในระบบ — Foodiva เป็นผู้ขาย ไม่ใช่สถานที่ของเรา",
  ORIGIN_REQUIRED: "ต้องระบุต้นทาง",
  INSUFFICIENT_STOCK: "สต็อกต้นทางไม่พอสำหรับน้ำหนักนี้",
  RUN_FARE_NOT_SET: "รอบรถนี้ยังไม่มีค่าเที่ยว — 0 บาทใช้ได้เฉพาะรถส่งสาขา",
  MANUAL_ALLOC_NOT_AUTOMATIC:
    "วิธีเฉลี่ยค่าขนส่งของรอบนี้เป็น MANUAL — ระบบไม่แบ่งให้อัตโนมัติ และรอบนี้ยังไม่มีหน้าจอกรอกส่วนแบ่งเอง",
  RUN_HAS_NO_LINES: "รอบรถนี้ยังไม่มีล็อตบนรถ จึงแบ่งค่าขนส่งไม่ได้",
  FREIGHT_RECONCILE_FAILED:
    "ส่วนแบ่งค่าขนส่งรวมกันไม่เท่าค่าเที่ยว ระบบจึงไม่บันทึก",
  RECEIPT_EVENT_DATE_REQUIRED: "ต้องระบุวันที่รับของ",
  RECEIPT_WEIGHT_INVALID: "น้ำหนักที่รับต้องไม่ติดลบ",
  RECEIPT_BAG_COUNT_INVALID: "จำนวนถุงที่รับต้องมากกว่า 0",
  LINE_NOT_FOUND: "ไม่พบรายการขนส่งนี้",
  LINE_ALREADY_RECEIVED: "รายการนี้มีผู้ยืนยันรับไปแล้ว",
  PARTIAL_RECEIPT_NOT_ALLOWED: "การตั้งค่าไม่อนุญาตให้รับของไม่ครบ ณ วันที่นี้",
  VARIANCE_REASON_REQUIRED:
    "น้ำหนักที่รับต่างจากน้ำหนักที่ส่งเกินเกณฑ์ — ต้องกรอกเหตุผลก่อนบันทึก",
};

/** Codes whose database detail (a key name, the weights) is worth keeping after the Thai. */
const KEEP_DETAIL = new Set([
  "CONFIG_NOT_SET",
  "RETURN_NOT_SCHEDULED",
  "INSUFFICIENT_STOCK",
  "VARIANCE_REASON_REQUIRED",
]);

function toResult<T>(
  data: T | null,
  error: { message: string } | null,
): RpcResult<T> {
  if (error || data === null || data === undefined) {
    const raw =
      error?.message ?? "ระบบไม่ส่งผลลัพธ์กลับมา — ตรวจรายการก่อนทำซ้ำ";
    const code = raw.match(/^([A-Z_]+):/)?.[1] ?? "";
    const thai = MESSAGES[code];
    const detail = raw.slice(code.length + 1).trim();
    const message = !thai
      ? raw
      : KEEP_DETAIL.has(code) && detail
        ? `${thai} [${detail}]`
        : thai;
    return { ok: false, code, message };
  }
  return { ok: true, data };
}

export type TransportRoute =
  "FOODIVA_TO_CM" | "CM_TO_FOODIVA" | "CENTRAL_TO_BRANCH";

/** fn_create_transport_run → run id. alloc_method is snapshotted inside from config at the
 * event date (R29); it is not, and must not become, a parameter. */
export async function createTransportRun(args: {
  idempotencyKey: string;
  route: TransportRoute;
  eventDate: string;
  vehicleType: string | null;
  isRoundTrip: boolean;
  runCostThb: number;
  lotIds: string[] | null;
  note: string | null;
}): Promise<RpcResult<string>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_create_transport_run", {
    p_idempotency_key: args.idempotencyKey,
    p_route: args.route,
    p_event_date: args.eventDate,
    p_vehicle_type: args.vehicleType,
    p_is_round_trip: args.isRoundTrip,
    p_run_cost_thb: args.runCostThb,
    p_lot_ids: args.lotIds,
    p_note: args.note,
  });
  return toResult(data as string | null, error);
}

/** fn_dispatch_transport_line → line id. On FOODIVA_TO_CM the origin is null — Foodiva is
 * not one of our locations — and the lot moves to IN_TRANSIT. */
export async function dispatchTransportLine(args: {
  idempotencyKey: string;
  runId: string;
  lotId: string;
  smokeDateGroupId: string | null;
  fromLocationId: string | null;
  toLocationId: string;
  dispatchedWeightKg: number;
}): Promise<RpcResult<string>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_dispatch_transport_line", {
    p_idempotency_key: args.idempotencyKey,
    p_run_id: args.runId,
    p_lot_id: args.lotId,
    p_smoke_date_group_id: args.smokeDateGroupId,
    p_from_location_id: args.fromLocationId,
    p_to_location_id: args.toLocationId,
    p_dispatched_weight_kg: args.dispatchedWeightKg,
  });
  return toResult(data as string | null, error);
}

/** fn_allocate_freight → the fare it reconciled to. A recompute, safe to replay. */
export async function allocateFreight(args: {
  idempotencyKey: string;
  runId: string;
}): Promise<RpcResult<number>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_allocate_freight", {
    p_idempotency_key: args.idempotencyKey,
    p_run_id: args.runId,
  });
  return toResult(data as number | null, error);
}

/** fn_confirm_transport_receipt → line id. The role comes from the line's destination, not
 * from anything passed here. OW 02 calls it only for CENTRAL lines, the one kind the Owner
 * signs for. */
export async function confirmTransportReceipt(args: {
  idempotencyKey: string;
  lineId: string;
  eventDate: string;
  receivedWeightKg: number;
  varianceReason: string | null;
  varianceSettlement: string | null;
  receivedBagCount: number | null;
}): Promise<RpcResult<string>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_confirm_transport_receipt", {
    p_idempotency_key: args.idempotencyKey,
    p_line_id: args.lineId,
    p_event_date: args.eventDate,
    p_received_weight_kg: args.receivedWeightKg,
    p_variance_reason: args.varianceReason,
    p_variance_settlement: args.varianceSettlement,
    p_received_bag_count: args.receivedBagCount,
  });
  return toResult(data as string | null, error);
}
