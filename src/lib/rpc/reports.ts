import "server-only";

import type {
  CostRow,
  ExceptionRow,
  PnlDayRow,
  PnlLotRow,
  PnlMonthRow,
  StockRow,
  TraceRow,
  YieldDayRow,
} from "@/features/reports/types";
import { createClient } from "@/lib/supabase/server";

/* Lane K's readers (cards ^ref-55 … ^ref-58, PLAN-reporting K18). This range writes nothing,
 * so there is no RPC here: every function is a select from a 2xx view (or 010 / 141), which is
 * the sanctioned read path (owner/config/page.tsx header). The views decide who sees what — an
 * L2 session gets zero rows from every one of these (R34); the (owner) layout is the mirror.
 *
 * A FAILED READ IS RETURNED, NEVER SWALLOWED: the screen shows the message instead of an empty
 * dashboard that reads as "nothing happened".
 */

export type ReportRange = {
  from: string;
  to: string;
  locationId?: string;
  lotId?: string;
};

export type Read<T> = { rows: T[]; error: string | null };

function read<T>(res: {
  data: unknown;
  error: { message: string } | null;
}): Read<T> {
  return {
    rows: (res.data ?? []) as T[],
    error: res.error ? res.error.message : null,
  };
}

/** The Owner's branches for the filter bar (141: every active BRANCH for L1). */
export async function readBranches(): Promise<
  Read<{ id: string; name_th: string }>
> {
  const supabase = await createClient();
  return read(await supabase.from("v_my_branches").select("id, name_th"));
}

/** 220 — round one's P&L per branch and day. */
export async function readPnlDays(r: ReportRange): Promise<Read<PnlDayRow>> {
  const supabase = await createClient();
  let q = supabase
    .from("v_pnl")
    .select("*")
    .gte("business_date", r.from)
    .lte("business_date", r.to);
  if (r.locationId) q = q.eq("location_id", r.locationId);
  return read(
    await q
      .order("business_date", { ascending: false })
      .order("location_name_th"),
  );
}

/** 221 — per branch and month, for the months the range touches. */
export async function readPnlMonths(
  r: ReportRange,
): Promise<Read<PnlMonthRow>> {
  const supabase = await createClient();
  let q = supabase
    .from("v_pnl_monthly")
    .select("*")
    .gte("pnl_month", r.from.slice(0, 7))
    .lte("pnl_month", r.to.slice(0, 7));
  if (r.locationId) q = q.eq("location_id", r.locationId);
  return read(
    await q.order("pnl_month", { ascending: false }).order("location_name_th"),
  );
}

/** 222 — per lot. A lot spans weeks, so the date range does not cut it. */
export async function readPnlLots(): Promise<Read<PnlLotRow>> {
  const supabase = await createClient();
  return read(
    await supabase
      .from("v_pnl_by_lot")
      .select("*")
      .order("lot_code", { ascending: false }),
  );
}

/** 213 — every nameable cost in the range, in-scope and memo alike. */
export async function readCostBreakdown(
  r: ReportRange,
): Promise<Read<CostRow>> {
  const supabase = await createClient();
  let q = supabase
    .from("v_cost_breakdown")
    .select(
      "cost_date, location_id, category, amount_thb, is_complete, missing_inputs, in_pnl_round_one, source_label",
    )
    .gte("cost_date", r.from)
    .lte("cost_date", r.to);
  if (r.locationId) q = q.eq("location_id", r.locationId);
  if (r.lotId) q = q.eq("lot_id", r.lotId);
  return read(await q);
}

/** 230 — Loss of the lots closed on each Bangkok date in the range. */
export async function readYieldDays(
  r: ReportRange,
): Promise<Read<YieldDayRow>> {
  const supabase = await createClient();
  return read(
    await supabase
      .from("v_yield_loss_daily")
      .select("*")
      .gte("close_date", r.from)
      .lte("close_date", r.to)
      .order("close_date"),
  );
}

/** 231 — every open exception. The screen bounds the dated kinds by the range.
 * ponytail: all rows in one read; exceptions are tens, not thousands. */
export async function readExceptions(): Promise<Read<ExceptionRow>> {
  const supabase = await createClient();
  return read(
    await supabase
      .from("v_owner_exceptions")
      .select("*")
      .order("occurred_on", { ascending: false }),
  );
}

/** 010 — smoked meat on hand now, frozen plus ready. */
export async function readStockOnHand(
  locationId?: string,
): Promise<Read<StockRow>> {
  const supabase = await createClient();
  let q = supabase
    .from("v_stock_balance")
    .select("balance_qty")
    .eq("item_type", "SMOKED_MEAT")
    .in("stock_state", ["FROZEN", "READY"]);
  if (locationId) q = q.eq("location_id", locationId);
  return read(await q);
}

/** 232 — sale → smoke date → lot → PO → supplier. */
export async function readTrace(r: ReportRange): Promise<Read<TraceRow>> {
  const supabase = await createClient();
  let q = supabase
    .from("v_sales_trace")
    .select("*")
    .gte("business_date", r.from)
    .lte("business_date", r.to);
  if (r.locationId) q = q.eq("location_id", r.locationId);
  if (r.lotId) q = q.eq("lot_id", r.lotId);
  return read(
    await q
      .order("business_date", { ascending: false })
      .order("location_name_th"),
  );
}
