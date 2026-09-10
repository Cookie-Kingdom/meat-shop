import type { AllocMethod, Route } from "./types";

/* OW 02's enums in Thai (ADR-009). */

export const ROUTE_LABEL: Record<Route, string> = {
  FOODIVA_TO_CM: "Foodiva → เชียงใหม่",
  CM_TO_FOODIVA: "เชียงใหม่ → คลังกลาง",
  CENTRAL_TO_BRANCH: "คลังกลาง → สาขา",
};

export const METHOD_LABEL: Record<AllocMethod, string> = {
  BY_LOT_WEIGHT: "แบ่งตามน้ำหนักล็อต",
  EQUAL_SPLIT: "แบ่งเท่ากันทุกล็อต",
  MANUAL: "กำหนดเอง (MANUAL)",
};

export function tripLabel(isRoundTrip: boolean): string {
  return isRoundTrip ? "ไป-กลับ" : "เที่ยวเดียว";
}
