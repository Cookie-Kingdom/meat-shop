import type { CostCategory, ExceptionKind } from "@/features/reports/types";

/* Thai for the codes the report views emit (ADR-009: literals, no i18n layer). The codes live
 * in SQL; this file is the only place they become words. */

export const EXCEPTION_TH: Record<ExceptionKind, string> = {
  YIELD_ALERT: "Loss เกินเกณฑ์",
  DIFF_OVER_THRESHOLD: "ยอดขายไม่ตรงกับเนื้อที่พร้อมขาย (Diff) เกินเกณฑ์",
  MATERIAL_LOW: "วัสดุบรรจุภัณฑ์ใกล้หมด",
  COUNT_VARIANCE_OPEN: "นับสต็อกไม่ตรงระบบ รอเจ้าของตรวจ",
  RECEIPT_VARIANCE: "รับของไม่ตรงน้ำหนักที่ส่ง",
  RECEIPT_OUTSTANDING: "ส่งแล้ว ยังรับของไม่ครบ",
  LOT_COST_INCOMPLETE: "ล็อตกลับถึงคลังกลางแล้ว แต่ต้นทุนยังไม่ครบ",
};

export const CATEGORY_TH: Record<CostCategory, string> = {
  MEAT: "ค่าเนื้อ",
  BRINE: "ค่าน้ำเกลือ",
  SMOKE_FEE: "ค่ารมควัน",
  TRANSPORT: "ค่าขนส่ง",
  OPENING_STOCK: "สต็อกตั้งต้น",
  CHILLI_PASTE: "น้ำพริก",
  PRODUCT_COST: "ต้นทุนสินค้าอื่น (ข้าว น้ำ)",
  PACKAGING: "บรรจุภัณฑ์",
  BRANCH_EXPENSE: "ค่าใช้จ่ายสาขา",
  INVESTMENT: "เงินลงทุน",
  MONTHLY_FIXED: "ค่าใช้จ่ายประจำเดือน",
  OWNER_OTHER: "ค่าใช้จ่ายอื่นของเจ้าของ",
};

/** Round one's declared exclusions (D04), in the order the note reads them. */
export const SCOPE_NOTE_TH =
  "รายได้ LINE MAN เท่านั้น ไม่มีส่วนลดหรือคืนสินค้า · ยังไม่รวมภาษี ค่าใช้จ่ายส่วนกลาง และค่าแรง (D04)";

export const LABOUR_SCOPE_TH = "ค่าแรง — ระยะที่ 2";

export const OWNER_MEMO_SCOPE_TH = "ไม่รวมในกำไรรอบแรก";

const MISSING_TH: Record<string, string> = {
  REPORT_OPEN: "วันนั้นยังไม่ปิดยอด",
  NO_DAILY_REPORT: "มีการตัดสต็อกในวันที่ไม่มีรายงานประจำวัน",
  STOCK_REMAINING: "ยังมีเนื้อของล็อตนี้เหลือในสต็อก",
  OUTPUT_WEIGHT: "ล็อตยังไม่ปิด จึงยังไม่รู้น้ำหนักหลังรมควัน",
  OPENING_COST: "ยังไม่ได้ตั้งต้นทุนต่อกิโลของสต็อกตั้งต้น",
  LOT_OPEN: "ล็อตยังไม่ปิด",
  MEAT_PRICE: "PO ยังไม่มีราคาเนื้อ",
  BRINE_PCT: "ยังไม่ได้ตั้งสัดส่วนน้ำเกลือ",
  BRINE_RATE: "ยังไม่ได้ตั้งราคาน้ำเกลือ",
  SMOKE_FEE_RATE: "ยังไม่ได้ตั้งอัตราค่ารมควัน",
  OUTBOUND_FREIGHT: "ค่าขนส่งขาไปยังไม่ได้ปันส่วน",
  RETURN_FREIGHT: "ค่าขนส่งขากลับยังไม่ได้ปันส่วน",
  RETURN_RECEIPT: "ขากลับยังไม่ได้รับของ",
  CHEF_HOUSE_STOCK: "ยังมีเนื้อค้างที่โรงรม",
};

/** One missing-input code as a sentence. `PRODUCT_COST:<SKU>` and `CONFIG:<key>` carry the
 * thing to go and set; an unknown code is shown as it is rather than hidden. */
export function missingTh(code: string): string {
  if (code.startsWith("PRODUCT_COST:")) {
    return `ยังไม่ได้ตั้งต้นทุนของ ${code.slice("PRODUCT_COST:".length)}`;
  }
  if (code.startsWith("CONFIG:")) {
    return `ยังไม่ได้ตั้งค่า ${code.slice("CONFIG:".length)}`;
  }
  return MISSING_TH[code] ?? code;
}
