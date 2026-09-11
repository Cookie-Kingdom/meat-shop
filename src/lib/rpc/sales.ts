import "server-only";

import { createClient } from "@/lib/supabase/server";
import { MESSAGES as BRANCH_MESSAGES } from "./branch";
import {
  toFailure,
  toResult,
  type Messages,
  type RpcFailure,
  type RpcResult,
} from "./result";

/* Typed wrappers over BR 07 and BR 09's three writes (card ^ref-46, PLAN-sales.md T7–T8):
 *   fn_record_sales        (^ref-43)  one batch of lines per save
 *   fn_record_waste        (^ref-44)  one row per save
 *   fn_close_daily_report  (^ref-45)  the day's one irreversible action
 *
 * THE KEY IS AN ARGUMENT, minted once per page view by the server component (branch.ts's rule,
 * PLAN-thaw.md T8): a double tap is a replay of the first tap, never a second batch.
 *
 * THE GATES STAY IN THE DATABASE. fn_close_daily_report decides whether the day reconciles;
 * this file only turns each refusal into a Thai sentence that names the line at fault
 * (the card's acceptance). An unmapped code is shown verbatim, never swallowed (result.ts). */

/** The five seeded SKUs (…0018). Codes are identifiers, not business numbers: the price and the
 * pack weight are resolved in the function (BR23, R29). */
export const SKU = {
  box: "MEAT_BOX",
  addon: "MEAT_ADDON_SEALED",
  chilli: "CHILLI_TUBE",
  rice: "RICE_KG",
  water: "WATER_BOTTLE",
} as const;

const SKU_TH: Record<string, string> = {
  MEAT_BOX: "เนื้อกล่องปกติ",
  MEAT_ADDON_SEALED: "Add-on เนื้อซีลเพิ่ม",
  CHILLI_TUBE: "น้ำพริกหลอด",
  RICE_KG: "ข้าวเหนียว",
  WATER_BOTTLE: "น้ำเปล่า",
};

const lotTh = (code: string) => (code === "no lot" ? "ไม่ระบุล็อต" : `ล็อต ${code}`);

export const MESSAGES: Messages = {
  ...BRANCH_MESSAGES,

  CONFIG_NOT_SET: (raw) => {
    const price = raw.match(/no price for (\S+)/);
    if (price) {
      return `เจ้าของร้านยังไม่ได้ตั้งราคา ${SKU_TH[price[1]] ?? price[1]} — แจ้งเจ้าของร้านให้ตั้งราคาก่อน จึงบันทึกยอดขายได้`;
    }
    if (raw.includes("avg_pack_weight_kg")) {
      return "เจ้าของร้านยังไม่ได้ตั้งน้ำหนักเฉลี่ยต่อซอง — แจ้งเจ้าของร้านก่อน จึงบันทึกยอดขายเนื้อได้";
    }
    if (raw.includes("business_day_close_earliest")) {
      return "เจ้าของร้านยังไม่ได้ตั้งเวลาที่เริ่มปิดวันได้ — แจ้งเจ้าของร้านก่อน จึงปิดวันได้";
    }
    return "เจ้าของร้านยังไม่ได้ตั้งค่าที่รายการนี้ต้องใช้ — แจ้งเจ้าของร้านให้ตั้งค่าก่อน";
  },
  CONFIG_WRONG_TYPE:
    "ค่าเวลาเริ่มปิดวันที่เจ้าของร้านตั้งไว้ไม่ถูกต้อง — แจ้งเจ้าของร้านให้แก้ก่อน",

  // Sales (fn_record_sales).
  SALES_LINES_REQUIRED: "ยังไม่ได้กรอกยอดขาย — กรอกจำนวนอย่างน้อยหนึ่งช่อง",
  SALES_IDEMPOTENCY_CONFLICT:
    "คำสั่งบันทึกนี้ถูกใช้กับยอดขายชุดอื่นไปแล้ว — โหลดหน้านี้ใหม่แล้วกรอกอีกครั้ง",
  PRODUCT_UNKNOWN: "ไม่พบสินค้านี้ในระบบ — แจ้งเจ้าของร้าน",
  SALES_QTY_INVALID: "จำนวนที่ขายต้องมากกว่า 0 และมีทศนิยมไม่เกิน 2 ตำแหน่ง",
  QTY_NOT_WHOLE_UNITS: "กล่อง ถุง หลอด และขวด ต้องกรอกเป็นจำนวนเต็ม",
  PACK_WEIGHT_INVALID:
    "น้ำหนักเฉลี่ยต่อซองที่เจ้าของร้านตั้งไว้ไม่ถูกต้อง — แจ้งเจ้าของร้านให้แก้ก่อน",
  LOT_REQUIRED: "เนื้อที่ขายหรือทิ้งต้องระบุล็อต — เลือกจากรายการเนื้อพร้อมขาย",
  SMOKE_GROUP_REQUIRED: "ต้องเลือกล็อตและวันรมควันของเนื้อก่อน",
  INSUFFICIENT_READY_STOCK: (raw) => {
    const meat = raw.match(
      /lot (\S+) smoked (\d{4}-\d{2}-\d{2}) has ([\d.-]+) kg ready at this branch; line (\d+) \(.*= ([\d.]+) kg\) is ([\d.]+) kg short/,
    );
    if (meat) {
      return `ล็อต ${meat[1]} เหลือเนื้อพร้อมขาย ${meat[3]} กก. แต่ยอดขายรายการที่ ${meat[4]} ใช้ ${meat[5]} กก. ขาดอยู่ ${meat[6]} กก. — ละลายเพิ่มก่อน หรือตรวจจำนวนที่กรอก`;
    }
    const other = raw.match(/: (\S+) has ([\d.-]+) (\S+) ready/);
    return other
      ? `${SKU_TH[other[1]] ?? other[1]} เหลือ ${other[2]} ไม่พอกับยอดที่กรอก — ตรวจจำนวนอีกครั้ง`
      : "ของพร้อมขายไม่พอกับยอดที่กรอก — ตรวจจำนวนอีกครั้ง";
  },

  // Waste (fn_record_waste).
  WASTE_IDEMPOTENCY_CONFLICT:
    "คำสั่งบันทึกนี้ถูกใช้กับ Waste รายการอื่นไปแล้ว — โหลดหน้านี้ใหม่แล้วกรอกอีกครั้ง",
  WASTE_ITEM_TYPE_INVALID: "บันทึก Waste ได้เฉพาะเนื้อรมควันและน้ำพริก",
  WASTE_STATE_INVALID: "บันทึก Waste ได้เฉพาะเนื้อพร้อมขายหรือเนื้อแช่แข็งในสาขา",
  WASTE_QTY_INVALID: "น้ำหนักที่ทิ้งต้องมากกว่า 0 และมีทศนิยมไม่เกิน 2 ตำแหน่ง",
  WASTE_REASON_REQUIRED: "ต้องระบุเหตุผลที่ทิ้ง",
  PRODUCT_AMBIGUOUS: "ระบบหาสินค้าน้ำพริกที่ใช้ตัดสต็อกไม่ได้ — แจ้งเจ้าของร้าน",
  INSUFFICIENT_STOCK:
    "น้ำหนักที่ทิ้งมากกว่าเนื้อพร้อมขายที่เหลือในล็อตนี้ — ตรวจน้ำหนักอีกครั้ง",

  // The close (fn_close_daily_report), one sentence per gate, each naming its line (TC-59).
  CLOSE_TOO_EARLY: (raw) => {
    const m = raw.match(/from (\d{2}:\d{2}) Bangkok time, and it is (\d{2}:\d{2})/);
    return m
      ? `ยังปิดวันไม่ได้ — ปิดได้ตั้งแต่ ${m[1]} น. (ตอนนี้ ${m[2]} น.)`
      : "ยังไม่ถึงเวลาที่ปิดวันได้";
  },
  DIFF_OVER_THRESHOLD: (raw) => {
    const m = raw.match(
      /([\d.-]+) kg of the ([\d.-]+) kg of meat made ready on \S+ is unaccounted for — ([\d.]+) percent/,
    );
    const figures = m
      ? `เนื้อ ${m[1]} กก. จาก ${m[2]} กก. ที่ละลายพร้อมขายวันนี้ ยังไม่มียอดขายหรือ Waste รองรับ (ต่าง ${m[3]}% เกินเกณฑ์)`
      : "Diff ของวันนี้เกินเกณฑ์";
    return `${figures} — ปิดวันไม่ได้จนกว่ายอดขายและ Waste จะตรงกัน ตรวจว่ามียอดขายที่ยังไม่ได้บันทึกหรือไม่ ถ้าตัวเลขถูกแล้วแต่ยังเกิน ให้โทรหาเจ้าของร้าน`;
  },
  DIFF_REASON_REQUIRED:
    "วันนี้ไม่มีเนื้อละลายเข้า แต่มียอดขายหรือ Waste ออก — ต้องเขียนหมายเหตุก่อนปิดวัน",
  READY_STOCK_NOT_ZERO: (raw) => {
    const total = raw.match(/: ([\d.-]+) kg of thawed meat/)?.[1];
    const list = raw.match(/at this branch \((.*)\) —/)?.[1] ?? "";
    const lots = list
      .split(", ")
      .map((part) => part.match(/^(.+) ([\d.-]+) kg$/))
      .filter((m): m is RegExpMatchArray => m !== null)
      .map((m) => `${lotTh(m[1])} ${m[2]} กก.`)
      .join(", ");
    return `ยังมีเนื้อพร้อมขายเหลือ${total ? ` ${total} กก.` : ""}${lots ? ` (${lots})` : ""} — ชั่งแล้วบันทึกเป็น Waste ทีละล็อตก่อนปิดวัน`;
  },
  MATERIAL_COUNT_INCOMPLETE: (raw) => {
    const codes = raw.match(/\(([^)]*)\) —/)?.[1] ?? "";
    return `ยังไม่ได้นับวัสดุ${codes ? `: ${codes}` : ""} — นับวัสดุให้ครบทุกรายการก่อนปิดวัน`;
  },
  RICE_RECORD_MISSING:
    "ยังไม่ได้บันทึกข้าวเหนียวสุกคงเหลือตอนเย็นของวันนี้ — ต้องบันทึกก่อนปิดวัน พรุ่งนี้จะยกยอดจากตัวเลขนี้",
};

/** One line of a sale. Meat names its lot AND smoke-date group (R21, D05); nothing else does. */
export type SalesLine = {
  product_code: string;
  qty: number;
  lot_id?: string;
  smoke_date_group_id?: string;
};

export async function recordSales(args: {
  idempotencyKey: string;
  dailyReportId: string;
  lines: SalesLine[];
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_record_sales", {
    p_idempotency_key: args.idempotencyKey,
    p_daily_report_id: args.dailyReportId,
    p_lines: args.lines,
  });
  return toResult(error, MESSAGES);
}

/** p_stock_state has no default in the function, and none here either (PLAN-sales.md). */
export async function recordWaste(args: {
  idempotencyKey: string;
  dailyReportId: string;
  itemType: "SMOKED_MEAT" | "CHILLI_PASTE";
  stockState: "READY" | "FROZEN";
  qty: number;
  reason: string;
  lotId: string | null;
  smokeDateGroupId: string | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_record_waste", {
    p_idempotency_key: args.idempotencyKey,
    p_daily_report_id: args.dailyReportId,
    p_item_type: args.itemType,
    p_stock_state: args.stockState,
    p_qty: args.qty,
    p_reason: args.reason,
    p_lot_id: args.lotId,
    p_smoke_date_group_id: args.smokeDateGroupId,
  });
  return toResult(error, MESSAGES);
}

export type CloseResult = {
  daily_report_id: string;
  status: "CLOSED";
  closed_at: string;
  /** null = not computed (a retry, or an UNLOCKED past day), which is not "nothing low". */
  material_alerts:
    | {
        packaging_item_code: string;
        remaining_qty: number | null;
        full_stock_qty: number | null;
        is_low: boolean | null;
      }[]
    | null;
};

export async function closeDailyReport(args: {
  idempotencyKey: string;
  dailyReportId: string;
  remark: string | null;
}): Promise<{ ok: true; data: CloseResult } | RpcFailure> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_close_daily_report", {
    p_idempotency_key: args.idempotencyKey,
    p_daily_report_id: args.dailyReportId,
    p_remark: args.remark,
  });
  if (!error) return { ok: true, data: data as CloseResult };

  const failure = toFailure(error, MESSAGES);
  if (failure.code !== "MATERIAL_COUNT_INCOMPLETE") return failure;

  /* The raise names packaging CODES; the operator reads Thai names. v_material_alerts carries
   * both and is L2-readable, so the names come from there. A failed read keeps the codes. */
  const codes = error.message.match(/\(([^)]*)\) —/)?.[1]?.split(", ") ?? [];
  const { data: rows } = await supabase
    .from("v_material_alerts")
    .select("packaging_code, name_th")
    .in("packaging_code", codes);
  const names = codes.map(
    (c) => rows?.find((r) => r.packaging_code === c)?.name_th ?? c,
  );
  return {
    ...failure,
    message: `ยังไม่ได้นับวัสดุ ${names.length} รายการ: ${names.join(", ")} — นับให้ครบทุกรายการก่อนปิดวัน`,
  };
}
