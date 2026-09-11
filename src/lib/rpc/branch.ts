import "server-only";

import { thaiDate } from "@/lib/format/date";
import { createClient } from "@/lib/supabase/server";
import {
  toFailure,
  toResult,
  type Messages,
  type RpcFailure,
  type RpcResult,
} from "./result";

/* Typed wrappers over the three writes the first branch screens make (card ^ref-41):
 *   BR 01  fn_open_daily_report          (^ref-39)
 *   BR 02  fn_confirm_transport_receipt  (^ref-22, amended by ^ref-35 with the bag count)
 *   BR 05  fn_record_thaw                (^ref-40)
 *
 * Every write goes through a plpgsql function called by RPC, in one transaction, with a
 * client-generated uuid idempotency key (ADR-002, ADR-005). Never `supabase.from(...)` for a
 * write.
 *
 * THE KEY COMES IN AS AN ARGUMENT, minted once per page view by the server component that
 * rendered the form (PLAN-thaw.md T8). That departs from `config.ts`, which mints per submit:
 * a double tap on a thaw is two POSTs of the same HTML, and a per-submit key would turn it into
 * two thaws — 6.00 kg moved for a 3.00 kg intent. A server component renders once per request,
 * so the key is stable across a double tap and a browser re-POST, and fresh after the redirect.
 *
 * The verdicts stay in the database: whether a receipt needs a reason is
 * fn_confirm_transport_receipt's call (a session cannot read the threshold), and whether a
 * thaw skips FIFO is fn_record_thaw's. These wrappers only translate what they said.
 */

const ISO_DATE = /\d{4}-\d{2}-\d{2}/g;

/** The ISO dates a raise names, in Thai, in the order it named them. */
export function datesIn(raw: string): string[] {
  return (raw.match(ISO_DATE) ?? []).map(thaiDate);
}

/* Exported since ^ref-46: sales.ts and materials.ts start from these (the preamble, the day)
 * and override the few that read differently on their screens. */
export const MESSAGES: Messages = {
  IDEMPOTENCY_KEY_REQUIRED: "คำสั่งบันทึกไม่สมบูรณ์ — โหลดหน้านี้ใหม่แล้วลองอีกครั้ง",
  IDEMPOTENCY_KEY_REUSED:
    "คำสั่งนี้ถูกใช้กับรายการอื่นไปแล้ว — โหลดหน้านี้ใหม่แล้วลองอีกครั้ง",
  NO_ACTOR: "บัญชีนี้ถูกปิดใช้งานแล้ว",
  FORBIDDEN: "บัญชีนี้ไม่มีสิทธิ์บันทึกงานของสาขา",
  FORBIDDEN_LOCATION: "บัญชีนี้ไม่ได้ผูกกับสาขานี้",
  CONFIG_NOT_SET:
    "เจ้าของร้านยังไม่ได้ตั้งค่าที่รายการนี้ต้องใช้ — แจ้งเจ้าของร้านให้ตั้งค่าก่อน",

  // The day (BR 01, and every write that attaches to it).
  REPORT_NOT_FOUND: "ไม่พบรายงานของวันนี้ — กลับไปหน้างานวันนี้แล้วเปิดวันก่อน",
  REPORT_CLOSED: (raw) =>
    `วันที่ ${datesIn(raw)[0] ?? ""} ปิดไปแล้ว — ถ้าต้องแก้ ต้องขอปลดล็อกจากเจ้าของร้าน`,
  BACKDATE_NOT_ALLOWED: (raw) =>
    `วันที่ ${datesIn(raw)[0] ?? ""} ย้อนหลังเกินกำหนด — ถ้าต้องแก้ ต้องขอปลดล็อกจากเจ้าของร้าน`,
  REPORT_STILL_OPEN: (raw) =>
    `วันที่ ${datesIn(raw)[0] ?? ""} ยังไม่ได้ปิด — ปิดวันนั้นก่อนจึงจะเปิดวันใหม่ได้ (ระบบไม่ปิดให้เอง)`,
  REPORT_ALREADY_CLOSED: (raw) =>
    `วันที่ ${datesIn(raw)[0] ?? ""} ปิดไปแล้ว เปิดซ้ำไม่ได้ — ถ้าต้องแก้ ต้องขอปลดล็อกจากเจ้าของร้าน`,
  REPORT_DATE_REQUIRED: "ต้องเลือกวันที่",
  REPORT_DATE_FUTURE: "เปิดวันล่วงหน้าไม่ได้",
  LOCATION_KIND_INVALID: "สถานที่นี้ไม่ใช่สาขา",

  // The thaw (BR 05).
  THAW_WEIGHT_INVALID:
    "น้ำหนักที่ละลายต้องมากกว่า 0 และมีทศนิยมไม่เกิน 2 ตำแหน่ง",
  LOT_REQUIRED: "ล็อตนี้ไม่มีเนื้อแช่แข็งเหลือในวันรมควันที่เลือก — เลือกล็อตใหม่",
  SMOKE_GROUP_REQUIRED: "ต้องเลือกวันรมควันและล็อตก่อน",
  FIFO_REASON_REQUIRED: (raw) =>
    `ยังมีเนื้อแช่แข็งวันรมควัน ${datesIn(raw)[0] ?? ""} อยู่ — ถ้าจะละลายวันที่ใหม่กว่าก่อน ต้องระบุเหตุผล`,
  INSUFFICIENT_FROZEN_STOCK: (raw) => {
    const m = raw.match(
      /lot (\S+) smoked (\d{4}-\d{2}-\d{2}) has ([\d.]+) kg frozen at this branch, ([\d.]+) kg/,
    );
    return m
      ? `ล็อต ${m[1]} (รมควัน ${thaiDate(m[2])}) เหลือแช่แข็ง ${m[3]} กก. ไม่พอกับ ${m[4]} กก. ที่กรอก`
      : "เนื้อแช่แข็งในล็อตนี้ไม่พอกับน้ำหนักที่กรอก";
  },

  // The receipt (BR 02).
  VARIANCE_REASON_REQUIRED: (raw) =>
    raw.includes("bag")
      ? "จำนวนถุงไม่ตรงกับที่ส่งมา — ต้องระบุเหตุผล"
      : "น้ำหนักต่างจากที่ส่งมาเกินเกณฑ์ — ต้องระบุเหตุผล",
  PARTIAL_RECEIPT_NOT_ALLOWED:
    "สาขานี้ยังไม่อนุญาตให้รับไม่ครบตามที่ส่ง — แจ้งเจ้าของร้าน",
  LINE_ALREADY_RECEIVED: "รายการนี้มีคนรับเข้าไปแล้ว",
  LINE_NOT_FOUND: "ไม่พบรายการส่งของนี้",
  RECEIPT_WEIGHT_INVALID: "น้ำหนักที่รับต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป",
  RECEIPT_BAG_COUNT_INVALID:
    "จำนวนถุงต้องเป็นจำนวนเต็มตั้งแต่ 1 ขึ้นไป — ถ้าไม่ได้นับ ให้เว้นว่าง",
  RECEIPT_EVENT_DATE_REQUIRED: "ต้องระบุวันที่รับ",
};

export async function openDailyReport(args: {
  idempotencyKey: string;
  locationId: string;
  reportDate: string;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_open_daily_report", {
    p_idempotency_key: args.idempotencyKey,
    p_location_id: args.locationId,
    p_report_date: args.reportDate,
  });
  return toResult(error, MESSAGES);
}

/** The response of fn_record_thaw. Both balances are the moved tuple's — (branch, lot,
 * smoke-date group) — read after the write; never summed into one figure (BR19). */
export type ThawResult = {
  thaw_record_id: string;
  lot_id: string;
  smoke_date_group_id: string;
  thawed_weight_kg: number;
  frozen_remaining_kg: number;
  ready_available_kg: number;
  fifo_override: boolean;
};

export async function recordThaw(args: {
  idempotencyKey: string;
  dailyReportId: string;
  lotId: string;
  smokeDateGroupId: string;
  thawedWeightKg: number;
  fifoOverrideReason: string | null;
}): Promise<{ ok: true; data: ThawResult } | RpcFailure> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fn_record_thaw", {
    p_idempotency_key: args.idempotencyKey,
    p_daily_report_id: args.dailyReportId,
    p_lot_id: args.lotId,
    p_smoke_date_group_id: args.smokeDateGroupId,
    p_thawed_weight_kg: args.thawedWeightKg,
    p_fifo_override_reason: args.fifoOverrideReason,
  });
  if (error) return toFailure(error, MESSAGES);
  return { ok: true, data: data as ThawResult };
}

export async function confirmBranchReceipt(args: {
  idempotencyKey: string;
  lineId: string;
  eventDate: string;
  receivedWeightKg: number;
  receivedBagCount: number | null;
  varianceReason: string | null;
}): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_confirm_transport_receipt", {
    p_idempotency_key: args.idempotencyKey,
    p_line_id: args.lineId,
    p_event_date: args.eventDate,
    p_received_weight_kg: args.receivedWeightKg,
    p_variance_reason: args.varianceReason,
    p_received_bag_count: args.receivedBagCount,
  });
  return toResult(error, MESSAGES);
}
