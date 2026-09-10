import type { Num } from "./format";

/* Row shapes of the views OW 03 and OW 04 read (card ^ref-33). One file, because the list,
 * the detail and the components all read the same rows. Column names are the views' own —
 * see supabase/views/100, 110, 070, 170, 171, 172. */

/** The states before close: OW 03's list. After close a lot belongs to OW 04 (R17). */
export const OPEN_STATES = [
  "PO_CREATED",
  "IN_TRANSIT",
  "CM_RECEIVED",
  "SMOKING",
];

export const LOT_STATE_TH: Record<string, string> = {
  PO_CREATED: "สร้างใบสั่งซื้อแล้ว",
  IN_TRANSIT: "กำลังขนส่งไปเชียงใหม่",
  CM_RECEIVED: "เชียงใหม่รับแล้ว",
  SMOKING: "กำลังรมควัน",
  LOT_CLOSED: "ปิดล็อตแล้ว",
  RETURN_SCHEDULED: "นัดรับขากลับแล้ว",
  CENTRAL_STOCK: "อยู่คลังกลาง",
  ALLOCATED: "จัดสรรแล้ว",
  AT_BRANCH: "อยู่ที่สาขา",
  CONSUMED: "ใช้หมดแล้ว",
};

export const ROUTE_TH: Record<string, string> = {
  FOODIVA_TO_CM: "ขาไป Foodiva → เชียงใหม่",
  CM_TO_FOODIVA: "ขากลับ เชียงใหม่ → Foodiva",
  CENTRAL_TO_BRANCH: "คลังกลาง → สาขา",
};

export const ALLOC_TH: Record<string, string> = {
  BY_LOT_WEIGHT: "ตามน้ำหนักล็อต",
  EQUAL_SPLIT: "หารเท่ากัน",
  MANUAL: "กำหนดเอง",
};

/** v_lot_progress (110). No percentage of any kind — R17. */
export type LotProgressRow = {
  lot_id: string;
  lot_code: string;
  state: string;
  chef_house_location_id: string | null;
  assigned_operator_id: string | null;
  days_logged: number;
  first_log_date: string | null;
  last_log_date: string | null;
  input_consumed_kg: Num;
  smoked_weight_kg: Num;
  brine_used_kg: Num;
  packed_weight_kg: Num;
  bag_count: number;
};

/** v_lot_pending_work (100). One row per lot that has a receipt. */
export type PendingWorkRow = {
  lot_id: string;
  lot_code: string;
  state: string;
  receipt_date: string;
  received_weight_kg: Num;
  post_drain_weight_kg: Num;
  input_consumed_kg: Num;
  pending_weight_kg: Num;
};

/** v_lot_daily_yield (172). day_yield_pct is not Loss and not smoke_yield_pct. */
export type LotDailyYieldRow = {
  lot_id: string;
  lot_code: string;
  state: string;
  smoke_daily_log_id: string;
  event_date: string;
  input_weight_kg: Num;
  smoked_weight_kg: Num;
  brine_used_kg: Num;
  packed_weight_kg: Num;
  bag_count: number | null;
  day_yield_pct: Num;
};

/** v_lot_yield (170). Closed, non-opening lots. */
export type LotYieldRow = {
  lot_id: string;
  lot_code: string;
  state: string;
  closed_at: string | null;
  chef_house_location_id: string | null;
  po_id: string | null;
  po_number: string | null;
  foodiva_sent_weight_kg: Num;
  cm_received_weight_kg: Num;
  pre_smoke_weight_kg: Num;
  output_weight_kg: Num;
  loss_weight_kg: Num;
  loss_pct: Num;
  smoke_yield_pct: Num;
  yield_alert: boolean;
  alert_threshold_pct: Num;
};

/** v_lot_cost (171). Every part null when its input has not landed — never 0 (ADR-023). */
export type LotCostRow = {
  lot_id: string;
  lot_code: string;
  state: string;
  closed_at: string | null;
  priced_at: string;
  po_id: string | null;
  po_number: string | null;
  foodiva_sent_weight_kg: Num;
  meat_unit_price_thb_per_kg: Num;
  meat_cost_thb: Num;
  brine_pct_of_meat: Num;
  brine_cost_thb_per_kg: Num;
  brine_rate_effective_from: string | null;
  brine_cost_thb: Num;
  smoke_fee_tier_id: string | null;
  smoke_fee_tier_effective_from: string | null;
  smoke_fee_rate_thb: Num;
  smoke_fee_rate_basis: "PER_KG" | "FLAT" | null;
  smoke_fee_computed_thb: Num;
  smoke_fee_override_thb: Num;
  smoke_fee_override_reason: string | null;
  smoke_fee_thb: Num;
  smoke_fee_is_overridden: boolean;
  freight_outbound_thb: Num;
  freight_return_thb: Num;
  freight_share_thb: Num;
  chef_house_frozen_kg: Num;
  total_cost_thb: Num;
  is_complete: boolean;
  missing_inputs: string[];
};

/** v_freight_allocation (070) — one row per transport line, the trace behind each freight
 * figure (F13). */
export type FreightLineRow = {
  line_id: string;
  run_id: string;
  route: string;
  event_date: string;
  vehicle_type: string | null;
  is_round_trip: boolean;
  alloc_method: string;
  run_cost_thb: Num;
  lot_code: string;
  lot_id: string;
  dispatched_weight_kg: Num;
  freight_share_thb: Num;
  run_allocated_thb: Num;
  fare_reconciles_to_satang: boolean;
};
