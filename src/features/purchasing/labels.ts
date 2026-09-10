import type { LotState } from "./types";

/* The lot lifecycle in Thai (F3's machine states, ADR-009). What OW 01 shows beside each
 * round's lot, so the Owner can see which rounds are still waiting for a truck. */
export const LOT_STATE_LABEL: Record<LotState, string> = {
  PO_CREATED: "รอส่งรถ",
  IN_TRANSIT: "กำลังขนส่งไปเชียงใหม่",
  CM_RECEIVED: "เชียงใหม่รับแล้ว",
  SMOKING: "กำลังรมควัน",
  LOT_CLOSED: "ปิดล็อตแล้ว",
  RETURN_SCHEDULED: "นัดรับขากลับแล้ว",
  CENTRAL_STOCK: "อยู่คลังกลาง",
  ALLOCATED: "จัดสรรแล้ว",
  AT_BRANCH: "อยู่สาขา",
  CONSUMED: "ใช้หมดแล้ว",
};
