/* Row shapes of the OW 01 read views (card ^ref-20). One type per view, named after it, so
 * a column added to the SQL has exactly one place to be added here. Numeric columns arrive
 * from PostgREST as JSON numbers; they are only ever printed (src/lib/format/number.ts). */

export type LotState =
  | "PO_CREATED"
  | "IN_TRANSIT"
  | "CM_RECEIVED"
  | "SMOKING"
  | "LOT_CLOSED"
  | "RETURN_SCHEDULED"
  | "CENTRAL_STOCK"
  | "ALLOCATED"
  | "AT_BRANCH"
  | "CONSUMED";

/** v_po_register (253). */
export type PoRegisterRow = {
  po_id: string;
  po_number: string;
  supplier_id: string;
  supplier_name: string;
  order_date: string;
  ordered_weight_kg: number;
  dispatched_weight_kg: number;
  outstanding_weight_kg: number;
  round_count: number;
  unit_price_thb_per_kg: number | null;
  brine_pct_offered: number | null;
  brine_cost_thb: number | null;
  meat_total_thb: number | null;
  brine_offered_kg: number | null;
  note: string | null;
  created_at: string;
};

/** v_po_rounds (251). */
export type PoRoundRow = {
  delivery_id: string;
  po_id: string;
  po_number: string;
  supplier_name: string;
  seq: number;
  dispatch_date: string;
  foodiva_sent_weight_kg: number;
  lot_id: string;
  lot_code: string;
  lot_state: LotState;
  chef_house_location_id: string | null;
  chef_house_name: string | null;
  note: string | null;
};

/** v_supplier_options (250). */
export type SupplierOption = { id: string; name: string };

/** v_config_catalogue's LOCATION rows — `unit` carries the location kind. */
export type LocationOption = { id: string; name_th: string; unit: string };
