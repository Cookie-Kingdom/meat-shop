/* Row shapes of the three read views the OW 05–07 screens use (card ^ref-37). Every read
 * goes through a view under its own role test (R34); the base tables stay deny-all. */

/** `v_lot_return_pending` (views/120) — OW 05's queue. No cost, no yield (R20). */
export type ReturnPendingRow = {
  lot_id: string;
  lot_code: string;
  state: "LOT_CLOSED" | "RETURN_SCHEDULED";
  chef_house_location_id: string | null;
  closed_at: string | null;
  return_pickup_date: string | null;
  days_since_close: number | null;
  packed_weight_kg: number;
  group_count: number;
};

/** `v_outstanding_receipts` (views/090), filtered by OW 06 to the return leg. */
export type OutstandingReceiptRow = {
  line_id: string;
  run_id: string;
  route: "FOODIVA_TO_CM" | "CM_TO_FOODIVA" | "CENTRAL_TO_BRANCH";
  dispatch_date: string;
  vehicle_type: string | null;
  lot_code: string;
  lot_id: string;
  smoke_date_group_id: string | null;
  from_location_id: string | null;
  to_location_id: string;
  dispatched_weight_kg: number;
  received_weight_kg: number | null;
  outstanding_weight_kg: number;
  dispatched_at: string;
  age_days: number;
};

/** `v_central_available` (views/130) — OW 07's picker, FROZEN at central only (BR11). */
export type CentralAvailableRow = {
  smoke_date: string;
  smoke_date_group_id: string;
  lot_id: string;
  lot_code: string;
  location_id: string;
  available_qty: number;
};

/** A branch, from `v_config_catalogue` (L1 only — so is OW 07). */
export type Branch = { id: string; name_th: string; code: string };

/** One dated config value, resolved by the event date in the form (R12). */
export type DatedValue<T> = { effective_from: string; value: T };

/** What an OW 06 / OW 07 action returns to `useActionState`. */
export type ActionState =
  | { status: "idle" }
  | { status: "ok"; message: string }
  | { status: "error"; code: string; message: string };
