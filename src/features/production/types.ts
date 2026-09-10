/* Row shapes of the four views the CM screens read. Written by hand: the repo has no
 * generated database types yet. Every column is one the view actually selects — no price,
 * cost or yield column exists in any of them, so none can be typed here (BR15). */

/** `lot_state`, in the enum's declared lifecycle order (…0001). */
export const LOT_STATES = [
  "PO_CREATED",
  "IN_TRANSIT",
  "CM_RECEIVED",
  "SMOKING",
  "LOT_CLOSED",
  "RETURN_SCHEDULED",
  "CENTRAL_STOCK",
  "ALLOCATED",
  "AT_BRANCH",
  "CONSUMED",
] as const;

export type LotState = (typeof LOT_STATES)[number];

/** A numeric(12,2) as PostgREST hands it over. */
type Kg = number | string;

/** The states a CM screen may still write in. The floor is lane H's widened receipt floor
 * (`IN_TRANSIT`); the ceiling is `fn_guard_lot_closed` (R8). The database decides — this
 * only chooses which screen to render. */
export const OPEN_STATES: LotState[] = ["IN_TRANSIT", "CM_RECEIVED", "SMOKING"];

export function isOpen(state: string): boolean {
  return (OPEN_STATES as string[]).includes(state);
}

/** At or past `LOT_CLOSED` — the LOCKED state on every CM screen. */
export function isClosed(state: string): boolean {
  const i = (LOT_STATES as readonly string[]).indexOf(state);
  return i >= LOT_STATES.indexOf("LOT_CLOSED");
}

/** `v_operator_lots` (260). */
export type OperatorLot = {
  lot_id: string;
  lot_code: string;
  state: LotState;
  lot_date: string;
  chef_house_location_id: string | null;
  chef_house_name: string | null;
  assigned_operator_id: string | null;
  foodiva_sent_weight_kg: Kg | null;
  receipt_date: string | null;
  received_weight_kg: Kg | null;
  post_drain_weight_kg: Kg | null;
  variance_reason: string | null;
  closed_at: string | null;
  closed_by_name: string | null;
};

/** `v_lot_pending_work` (100). Only lots with a receipt. */
export type PendingWork = {
  lot_id: string;
  lot_code: string;
  state: LotState;
  chef_house_location_id: string | null;
  assigned_operator_id: string | null;
  receipt_date: string;
  received_weight_kg: Kg;
  post_drain_weight_kg: Kg | null;
  input_consumed_kg: Kg;
  pending_weight_kg: Kg | null;
};

/** `v_lot_progress` (110). */
export type LotProgress = {
  lot_id: string;
  lot_code: string;
  state: LotState;
  days_logged: number;
  first_log_date: string | null;
  last_log_date: string | null;
  input_consumed_kg: Kg;
  smoked_weight_kg: Kg | null;
  brine_used_kg: Kg | null;
  packed_weight_kg: Kg;
  bag_count: number;
};

export type LogSource = {
  lot_id: string;
  lot_code: string;
  input_weight_kg: Kg;
};

/** What a CM server action hands back to its form. Structurally `RpcResult`, redeclared here
 * because a client component must not import a `server-only` module, even for a type. */
export type SaveResult =
  { ok: true } | { ok: false; code: string; message: string };

/** CM 04 writes through two RPCs, each with its own key (R4 for the log, R39 for the bags). */
export type SmokeLogKeys = { log: string; bags: string };

export type SmokeLogInput = {
  lotId: string;
  eventDate: string;
  keys: SmokeLogKeys;
  /** null when the day's log is unchanged — an evening "bags only" save must not rewrite the
   * morning's sources (the upsert replaces them, Finding 3). */
  log: {
    sources: { lotId: string; kg: string }[];
    smokedKg: string;
    brineKg: string;
  } | null;
  /** The new batch, as typed. Blank rows are dropped by the form. */
  bags: string[];
};

export type SmokeLogResult =
  | { ok: true; keys: SmokeLogKeys }
  | {
      ok: false;
      code: string;
      message: string;
      /** The log committed and the bags did not. The log key is rotated so an edit before the
       * retry is a correction, not a replay that silently drops it. */
      logSaved?: boolean;
      keys?: SmokeLogKeys;
    };

/** `v_smoke_log_day` (261). */
export type SmokeLogDay = {
  smoke_daily_log_id: string;
  lot_id: string;
  lot_code: string;
  event_date: string;
  input_weight_kg: Kg;
  smoked_weight_kg: Kg | null;
  brine_used_kg: Kg | null;
  post_freeze_weight_kg: Kg | null;
  sources: LogSource[];
  packed_weight_kg: Kg;
  bag_count: number;
};
