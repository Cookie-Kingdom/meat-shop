/* Row shapes of the views OW 02 reads (card ^ref-24). One type per view, named after it.
 * Numeric columns arrive from PostgREST as JSON numbers and are only ever printed. */

export type Route = "FOODIVA_TO_CM" | "CM_TO_FOODIVA" | "CENTRAL_TO_BRANCH";
export type AllocMethod = "BY_LOT_WEIGHT" | "EQUAL_SPLIT" | "MANUAL";

/** v_transport_runs (252). */
export type TransportRunRow = {
  run_id: string;
  route: Route;
  event_date: string;
  vehicle_type: string | null;
  is_round_trip: boolean;
  alloc_method: AllocMethod;
  run_cost_thb: number;
  note: string | null;
  created_at: string;
  line_count: number;
  dispatched_weight_kg: number;
  received_line_count: number;
  allocated_thb: number;
  fare_reconciles_to_satang: boolean;
};

/** v_freight_allocation (070). */
export type FreightLineRow = {
  line_id: string;
  run_id: string;
  route: Route;
  event_date: string;
  vehicle_type: string | null;
  is_round_trip: boolean;
  alloc_method: AllocMethod;
  run_cost_thb: number;
  lot_code: string;
  lot_id: string;
  dispatched_weight_kg: number;
  freight_share_thb: number | null;
  run_allocated_thb: number;
  fare_reconciles_to_satang: boolean;
};

/** v_outstanding_receipts (090). */
export type OutstandingRow = {
  line_id: string;
  run_id: string;
  route: Route;
  dispatch_date: string;
  vehicle_type: string | null;
  lot_code: string;
  lot_id: string;
  smoke_date_group_id: string | null;
  from_location_id: string | null;
  to_location_id: string | null;
  dispatched_weight_kg: number;
  received_weight_kg: number | null;
  outstanding_weight_kg: number;
  dispatched_at: string;
  age_days: number;
};

/** v_transport_variance (080). */
export type VarianceRow = {
  line_id: string;
  run_id: string;
  route: Route;
  dispatch_date: string;
  lot_code: string;
  lot_id: string;
  from_location_id: string | null;
  to_location_id: string | null;
  dispatched_weight_kg: number;
  received_weight_kg: number | null;
  outstanding_weight_kg: number | null;
  variance_pct: number | null;
  variance_reason: string | null;
  variance_settlement: string | null;
  received_at: string | null;
};

/** A location's name and kind, from v_config_catalogue's LOCATION rows. */
export type Place = { name: string; kind: string };
