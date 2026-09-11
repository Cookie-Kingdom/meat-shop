/* Row shapes of lane K's report views (supabase/views/2xx_*). Only the columns a screen reads.
 * A numeric column arrives from PostgREST as a number or a string, and null means unknown —
 * never zero (ADR-023). */

export type Num = number | string | null;

export type ExceptionKind =
  | "YIELD_ALERT"
  | "DIFF_OVER_THRESHOLD"
  | "MATERIAL_LOW"
  | "COUNT_VARIANCE_OPEN"
  | "RECEIPT_VARIANCE"
  | "RECEIPT_OUTSTANDING"
  | "LOT_COST_INCOMPLETE";

export type CostCategory =
  | "MEAT"
  | "BRINE"
  | "SMOKE_FEE"
  | "TRANSPORT"
  | "OPENING_STOCK"
  | "CHILLI_PASTE"
  | "PRODUCT_COST"
  | "PACKAGING"
  | "BRANCH_EXPENSE"
  | "INVESTMENT"
  | "MONTHLY_FIXED"
  | "OWNER_OTHER";

/** 231_v_owner_exceptions */
export type ExceptionRow = {
  exception_kind: ExceptionKind;
  occurred_on: string | null;
  location_id: string | null;
  lot_id: string | null;
  ref_table: string;
  ref_id: string;
  detail: Record<string, unknown>;
};

/** The P&L money columns shared by 220 and 221. */
type PnlMoney = {
  revenue_thb: Num;
  meat_cost_thb: Num;
  brine_cost_thb: Num;
  smoke_fee_thb: Num;
  freight_thb: Num;
  opening_stock_cost_thb: Num;
  chilli_paste_cost_thb: Num;
  product_cost_thb: Num;
  packaging_thb: Num;
  branch_expense_thb: Num;
  total_cost_thb: Num;
  profit_round_one_thb: Num;
  is_complete: boolean;
  missing_inputs: string[];
};

/** 220_v_pnl */
export type PnlDayRow = PnlMoney & {
  business_date: string;
  location_id: string;
  location_name_th: string;
  daily_report_id: string | null;
  report_status: "OPEN" | "CLOSED" | "UNLOCKED" | null;
};

/** 221_v_pnl_monthly */
export type PnlMonthRow = PnlMoney & {
  pnl_month: string;
  location_id: string;
  location_name_th: string;
  days_reported: number;
  days_closed: number;
};

/** 222_v_pnl_by_lot */
export type PnlLotRow = {
  lot_id: string;
  lot_code: string;
  is_opening: boolean;
  output_kg: Num;
  sold_kg: Num;
  wasted_kg: Num;
  remaining_kg: Num;
  meat_revenue_thb: Num;
  attributed_cost_thb: Num;
  lot_total_cost_thb: Num;
  unattributed_cost_thb: Num;
  profit_round_one_thb: Num;
  is_complete: boolean;
  missing_inputs: string[];
};

/** 213_v_cost_breakdown */
export type CostRow = {
  cost_date: string;
  location_id: string | null;
  category: CostCategory;
  amount_thb: Num;
  is_complete: boolean;
  missing_inputs: string[];
  in_pnl_round_one: boolean;
  source_label: string | null;
};

/** 230_v_yield_loss_daily */
export type YieldDayRow = {
  close_date: string;
  lots_closed: number;
  foodiva_sent_weight_kg: Num;
  loss_weight_kg: Num;
  loss_pct: Num;
  yield_alert_lot_count: number;
};

/** 232_v_sales_trace */
export type TraceRow = {
  sales_line_id: string;
  business_date: string;
  location_name_th: string;
  product_name_th: string;
  sold_qty: Num;
  pack_weight_kg: Num;
  smoke_date: string | null;
  lot_id: string;
  lot_code: string;
  is_opening: boolean;
  po_number: string | null;
  supplier_name: string | null;
};

/** 010_v_stock_balance, the two columns the stock tile sums. */
export type StockRow = { balance_qty: Num };
