import "server-only";

import type { BranchDay } from "@/features/branch/context";

/* The two reads BR 07 and BR 09 share (card ^ref-46). Both views carry their role test in their
 * WHERE (R34); these add only the branch and the day. Nothing here sums or compares: every
 * figure is a column the view computed (PLAN-close-screens.md Findings 1, 3). */

type Db = BranchDay["supabase"];

/** A (lot, smoke-date group) still holding READY meat at the branch — the line a Diff or a
 * leftover is on (Finding 3). */
export type ReadyLot = {
  lot_id: string;
  smoke_date_group_id: string;
  lot_code: string;
  smoke_date: string;
  available_qty: number;
};

/** v_branch_diff's row for one branch day: the SAVED figures, never a live recompute (Finding 1). */
export type DiffRow = {
  ready_in_kg: number;
  sold_pack_qty: number;
  sold_kg: number;
  wasted_kg: number;
  diff_kg: number;
  variance_pct: number | null;
  verdict: "WITHIN" | "OVER_THRESHOLD" | "REASON_REQUIRED";
};

export async function readReadyLots(db: Db, locationId: string) {
  const { data, error } = await db
    .from("v_smoke_group_available")
    .select("lot_id, smoke_date_group_id, lot_code, smoke_date, available_qty")
    .eq("location_id", locationId)
    .eq("stock_state", "READY")
    .order("smoke_date")
    .order("lot_code");
  return { rows: (data ?? []) as ReadyLot[], error: error?.message ?? null };
}

/** null = the day has no READY meat movement, so it has no Diff to check (PLAN-sales B7). */
export async function readDiff(db: Db, locationId: string, date: string) {
  const { data, error } = await db
    .from("v_branch_diff")
    .select("ready_in_kg, sold_pack_qty, sold_kg, wasted_kg, diff_kg, variance_pct, verdict")
    .eq("location_id", locationId)
    .eq("business_date", date)
    .maybeSingle();
  return { row: (data ?? null) as DiffRow | null, error: error?.message ?? null };
}

/** The lots still holding READY, largest first: the lines to check first. Display order only. */
export function largestFirst(rows: ReadyLot[]): ReadyLot[] {
  return [...rows].sort((a, b) => Number(b.available_qty) - Number(a.available_qty));
}
