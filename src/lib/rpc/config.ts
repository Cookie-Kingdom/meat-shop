import "server-only";

import { createClient } from "@/lib/supabase/server";
import { toResult as toResultWith, type RpcResult } from "./result";

export type { RpcResult } from "./result";

/* Typed wrappers over the four config setters (card ^ref-12, functions from ^ref-11).
 *
 * Every write in this system goes through a plpgsql function called by RPC, in one
 * transaction, with a client-generated uuid idempotency key (ADR-002, ADR-005). Never
 * `supabase.from(...)` for a write.
 *
 * THE KEY IS MINTED HERE, IN THE SERVER ACTION — never in a component. A key generated
 * during render is a new key on every re-render, which turns the retry the key exists to
 * make safe into a second row (R38, R4). One `newIdempotencyKey()` per submitted form.
 *
 * AN UNMAPPED ERROR IS SHOWN VERBATIM, NEVER SWALLOWED. A silent catch here is how a
 * refused write reads as a saved one — the Owner types a price, sees no error, and the
 * engine goes on using the old rate.
 */

export function newIdempotencyKey(): string {
  return crypto.randomUUID();
}

/** The named raises of the four setters, in Thai. The message names the rule, because the
 * Owner is the person who has to decide what to do about it. */
const MESSAGES: Record<string, string> = {
  CONFIG_DUPLICATE_DATE:
    "วันที่นี้มีค่าอื่นบันทึกไว้แล้ว ระบบไม่แก้ทับของเดิม เพราะรายงานที่ปิดไปแล้วต้องคงตัวเลขเดิมไว้ — ตั้งค่าใหม่โดยใช้วันที่ถัดไปแทน",
  CONFIG_ONE_VALUE:
    "กรอกค่าได้ครั้งละหนึ่งชนิดเท่านั้น (ตัวเลข ข้อความ หรือ JSON)",
  CONFIG_KEY_REQUIRED: "ยังไม่ได้เลือกรายการที่จะตั้งค่า",
  CONFIG_EFFECTIVE_FROM_REQUIRED: "ต้องระบุวันที่เริ่มใช้ค่านี้",
  FULL_STOCK_NOT_POSITIVE:
    "จำนวนสต๊อกเต็มต้องมากกว่า 0 — ถ้ายังไม่กำหนด ให้ไม่ต้องบันทึกแถวนี้ แทนการใส่ 0",
  PACKAGING_ITEM_REQUIRED: "ยังไม่ได้เลือกวัสดุ",
  PRODUCT_REQUIRED: "ยังไม่ได้เลือกสินค้า",
  PRICE_INVALID: "ราคาต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป",
  TIER_GAP: "ขั้นน้ำหนักมีช่วงที่ไม่มีขั้นไหนครอบคลุม — ต้องต่อกันทุกช่วง",
  TIER_OVERLAP: "ขั้นน้ำหนักซ้อนทับกัน — น้ำหนักหนึ่งค่าต้องตกในขั้นเดียว",
  TIER_NOT_ANCHORED:
    "ขั้นแรกต้องเริ่มที่ 0 กก. ไม่งั้นน้ำหนักน้อย ๆ จะไม่มีขั้นรองรับ",
  TIER_NOT_OPEN_ENDED:
    "ขั้นสุดท้ายต้องเปิดปลาย (ไม่ใส่น้ำหนักสูงสุด) ไม่งั้นล็อตหนักจะหลุดตาราง",
  TIER_BAND_INVERTED:
    "ขั้นน้ำหนักกลับหัวกลับหาง — น้ำหนักสูงสุดต้องมากกว่าน้ำหนักต่ำสุด",
  TIER_RATE_BASIS: "หน่วยค่ารมควันต้องเป็น PER_KG หรือ FLAT",
  TIER_RATE_INVALID: "ค่ารมควันต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป",
  TIER_MIN_REQUIRED: "ทุกขั้นต้องมีน้ำหนักต่ำสุด",
  TIER_MIN_NEGATIVE: "น้ำหนักต่ำสุดติดลบไม่ได้",
  TIER_SET_EMPTY: "ต้องมีอย่างน้อยหนึ่งขั้น",
  TIER_SET_INVALID: "รูปแบบขั้นค่ารมควันไม่ถูกต้อง",
  IDEMPOTENCY_KEY_REQUIRED: "คำสั่งบันทึกไม่สมบูรณ์ กรุณาลองใหม่",
  FORBIDDEN: "สิทธิ์ของบัญชีนี้ไม่สามารถแก้ค่าตั้งต้นได้",
  NO_ACTOR: "บัญชีนี้ถูกปิดใช้งานแล้ว",
};

/** The `CODE:` split lives in `./result` since ^ref-41; this binds it to the setters' messages.
 * Same behaviour as before the move. */
function toResult(error: { message: string } | null): RpcResult {
  return toResultWith(error, MESSAGES);
}

export async function setConfig(args: {
  idempotencyKey: string;
  key: string;
  effectiveFrom: string;
  valueNumeric?: number | null;
  valueText?: string | null;
  valueJson?: unknown;
  scopeLocationId?: string | null;
  note?: string | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_set_config", {
    p_idempotency_key: args.idempotencyKey,
    p_key: args.key,
    p_effective_from: args.effectiveFrom,
    p_value_numeric: args.valueNumeric ?? null,
    p_value_text: args.valueText ?? null,
    p_value_json: args.valueJson ?? null,
    p_scope_location_id: args.scopeLocationId ?? null,
    p_note: args.note ?? null,
  });
  return toResult(error);
}

export type TierBand = {
  min_weight_kg: number;
  max_weight_kg: number | null;
  rate_thb: number;
  rate_basis: "PER_KG" | "FLAT";
};

/** The whole band set at one date, never one band (D02). Validating a band at a time cannot
 * see a gap, and the function refuses a partial write anyway. */
export async function setSmokeFeeTier(args: {
  idempotencyKey: string;
  effectiveFrom: string;
  tiers: TierBand[];
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_set_smoke_fee_tier", {
    p_idempotency_key: args.idempotencyKey,
    p_effective_from: args.effectiveFrom,
    p_tiers: args.tiers,
  });
  return toResult(error);
}

export async function setProductPrice(args: {
  idempotencyKey: string;
  productId: string;
  effectiveFrom: string;
  priceThb: number;
  costThb?: number | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_set_product_price", {
    p_idempotency_key: args.idempotencyKey,
    p_product_id: args.productId,
    p_effective_from: args.effectiveFrom,
    p_price_thb: args.priceThb,
    p_cost_thb: args.costThb ?? null,
  });
  return toResult(error);
}

export async function setPackagingFullStock(args: {
  idempotencyKey: string;
  packagingItemId: string;
  effectiveFrom: string;
  fullStockQty: number;
  locationId?: string | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_set_packaging_full_stock", {
    p_idempotency_key: args.idempotencyKey,
    p_packaging_item_id: args.packagingItemId,
    p_effective_from: args.effectiveFrom,
    p_full_stock_qty: args.fullStockQty,
    p_location_id: args.locationId ?? null,
  });
  return toResult(error);
}
