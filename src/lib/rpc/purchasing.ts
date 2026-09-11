import "server-only";

import { createClient } from "@/lib/supabase/server";

/* Typed wrappers over the two purchasing writers — fn_create_po and fn_add_po_delivery
 * (functions ^ref-19, screen ^ref-20, lane F).
 *
 * Every write goes through a plpgsql function called by RPC, in one transaction, with a
 * client-generated uuid idempotency key (ADR-002, ADR-005). Never `supabase.from(...)` for a
 * write.
 *
 * THE KEY IS AN ARGUMENT, NOT MINTED HERE. OW 01 mints it when the Server Component renders
 * the form and posts it in a hidden input (PLAN-purchasing.md P5). A double tap then posts
 * the same key twice, and the function's retry check returns the first call's id instead of
 * booking a second round. A key minted per call here would make every tap a new write. And
 * a key minted in a client component is new on every re-render — the failure
 * src/lib/rpc/config.ts's header describes.
 *
 * AN UNMAPPED ERROR IS SHOWN VERBATIM, NEVER SWALLOWED — same rule as config.ts. A silent
 * catch is how a refused round reads as a booked one.
 */

export type RpcResult<T> =
  { ok: true; data: T } | { ok: false; code: string; message: string };

/** The named raises of both functions and of fn_require_owner, in Thai. Each names what the
 * Owner can do about it, because the Owner is the one who has to. */
const MESSAGES: Record<string, string> = {
  IDEMPOTENCY_KEY_REQUIRED:
    "คำสั่งบันทึกไม่สมบูรณ์ กรุณาเปิดหน้านี้ใหม่แล้วลองอีกครั้ง",
  FORBIDDEN: "บัญชีนี้ไม่มีสิทธิ์สั่งซื้อ — เฉพาะเจ้าของกิจการ",
  NO_ACTOR: "บัญชีนี้ถูกปิดใช้งานแล้ว",
  PO_EVENT_DATE_REQUIRED: "ต้องระบุวันที่สั่งซื้อ",
  PO_WEIGHT_INVALID: "น้ำหนักที่สั่งต้องมากกว่า 0 กก.",
  SUPPLIER_NOT_FOUND: "ไม่พบผู้ขายรายนี้ในระบบ",
  SUPPLIER_INACTIVE: "ผู้ขายรายนี้ถูกปิดใช้งานแล้ว — เลือกรายอื่น",
  PO_IDEMPOTENCY_CONFLICT:
    "คำสั่งนี้บันทึก PO ไปแล้วด้วยข้อมูลชุดก่อนหน้า — ตรวจรายการ PO ด้านล่างก่อนสร้างใหม่ ระบบไม่สร้างซ้ำ",
  DELIVERY_EVENT_DATE_REQUIRED: "ต้องระบุวันที่ส่งของรอบนี้",
  DELIVERY_WEIGHT_INVALID: "น้ำหนักรอบส่งต้องมากกว่า 0 กก.",
  LOCATION_NOT_FOUND: "ไม่พบปลายทางนี้ในระบบ",
  LOCATION_KIND_INVALID:
    "ปลายทางของรอบส่งต้องเป็นโรงรมควันเชียงใหม่ — ของจาก Foodiva ไม่ไปคลังกลางหรือสาขาโดยตรง",
  DELIVERY_IDEMPOTENCY_CONFLICT:
    "คำสั่งนี้บันทึกรอบส่งไปแล้วด้วยข้อมูลชุดก่อนหน้า — ตรวจรายการรอบส่งด้านบนก่อนบันทึกใหม่ ระบบไม่สร้างล็อตซ้ำ",
  PO_NOT_FOUND: "ไม่พบ PO นี้",
  PO_OVERDELIVERY:
    "น้ำหนักรอบนี้ทำให้ยอดส่งสะสมเกินน้ำหนักที่สั่ง — ส่งได้ไม่เกินยอดค้างส่งที่แสดงไว้ ถ้าผู้ขายส่งเกินจริง ให้เปิด PO ใบใหม่สำหรับส่วนที่เกิน",
};

/** Postgres reports our raises as `CODE: detail`. Split the code off so the screen shows the
 * Thai sentence for the ones named above, and the raw message for any it does not know. */
function toResult<T>(
  data: T | null,
  error: { message: string } | null,
): RpcResult<T> {
  if (error || data === null || data === undefined) {
    const raw =
      error?.message ?? "ระบบไม่ส่งผลลัพธ์กลับมา — ตรวจรายการก่อนบันทึกซ้ำ";
    const code = raw.match(/^([A-Z_]+):/)?.[1] ?? "";
    return { ok: false, code, message: MESSAGES[code] ?? raw };
  }
  return { ok: true, data };
}

/** fn_create_po → the new PO's id. po_number is generated inside the function (F4). */
export async function createPo(args: {
  idempotencyKey: string;
  supplierId: string;
  eventDate: string;
  orderedWeightKg: number;
  unitPriceThbPerKg: number | null;
  brinePctOffered: number | null;
  brineCostThb: number | null;
  note: string | null;
}): Promise<RpcResult<string>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_create_po", {
    p_idempotency_key: args.idempotencyKey,
    p_supplier_id: args.supplierId,
    p_event_date: args.eventDate,
    p_ordered_weight_kg: args.orderedWeightKg,
    p_unit_price_thb_per_kg: args.unitPriceThbPerKg,
    p_brine_pct_offered: args.brinePctOffered,
    p_brine_cost_thb: args.brineCostThb,
    p_note: args.note,
  });
  return toResult(data as string | null, error);
}

/** fn_add_po_delivery → the LOT id, not the round id. The round and its lot are one write
 * (D01), and the lot is what every later card joins to. */
export async function addPoDelivery(args: {
  idempotencyKey: string;
  poId: string;
  eventDate: string;
  foodivaSentWeightKg: number;
  chefHouseLocationId: string;
  note: string | null;
}): Promise<RpcResult<string>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_add_po_delivery", {
    p_idempotency_key: args.idempotencyKey,
    p_po_id: args.poId,
    p_event_date: args.eventDate,
    p_foodiva_sent_weight_kg: args.foodivaSentWeightKg,
    p_chef_house_location_id: args.chefHouseLocationId,
    p_note: args.note,
  });
  return toResult(data as string | null, error);
}
