import "server-only";

import { createClient } from "@/lib/supabase/server";

import type {
  LotProgress,
  OperatorLot,
  PendingWork,
  SmokeLogDay,
} from "./types";

/* The CM screens' reads. Every one goes through a view whose WHERE carries the role test
 * (R34): an L3 session gets its own assigned lots and nothing else, an L2 session gets zero
 * rows, and that is decided in the database — the (cm) layout's requireRole is the mirror
 * (ADR-004). `supabase.from(...)` is the sanctioned path for a READ through a view; every
 * write goes through src/lib/rpc/production.ts.
 *
 * An error is returned, never thrown and never swallowed: the page says the read failed
 * rather than rendering an empty list that reads as "no work today" (REVIEW 11, 15). */

export type Read<T> = { data: T; error: string | null };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** A route param is user input. A malformed one is a stale link, not a Postgres 22P02. */
export function isUuid(s: string): boolean {
  return UUID.test(s);
}

/** CM 01. A lot appears once OW 02 has put it on the truck (v0.2 line 103), so PO_CREATED
 * is left out; oldest first, so the lot most likely to be acted on is above the fold. */
export async function readMyLots(): Promise<Read<OperatorLot[]>> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("v_operator_lots")
    .select("*")
    .neq("state", "PO_CREATED")
    .order("lot_date", { ascending: true })
    .order("lot_code", { ascending: true });
  return { data: (data ?? []) as OperatorLot[], error: error?.message ?? null };
}

export type LotBundle = {
  lot: OperatorLot | null;
  pending: PendingWork | null;
  progress: LotProgress | null;
};

/** One lot as the hub, CM 02, CM 03 and CM 05 need it. `pending` is null until CM 02 has
 * written a receipt — v_lot_pending_work inner-joins it. */
export async function readLot(lotId: string): Promise<Read<LotBundle>> {
  const supabase = await createClient();
  const [lot, pending, progress] = await Promise.all([
    supabase
      .from("v_operator_lots")
      .select("*")
      .eq("lot_id", lotId)
      .maybeSingle(),
    supabase
      .from("v_lot_pending_work")
      .select("*")
      .eq("lot_id", lotId)
      .maybeSingle(),
    supabase
      .from("v_lot_progress")
      .select("*")
      .eq("lot_id", lotId)
      .maybeSingle(),
  ]);
  return {
    data: {
      lot: (lot.data as OperatorLot | null) ?? null,
      pending: (pending.data as PendingWork | null) ?? null,
      progress: (progress.data as LotProgress | null) ?? null,
    },
    error:
      lot.error?.message ??
      pending.error?.message ??
      progress.error?.message ??
      null,
  };
}

/** The lots CM 04 may draw raw meat from: the operator's own lots at the same chef house,
 * received and not yet closed (D05). The database checks the chef house again
 * (SOURCE_LOT_NOT_HERE) and the closed guard fires on the source row (R8). */
export async function readSourceLots(
  chefHouseId: string,
): Promise<Read<PendingWork[]>> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("v_lot_pending_work")
    .select("*")
    .eq("chef_house_location_id", chefHouseId)
    .in("state", ["CM_RECEIVED", "SMOKING"])
    .order("receipt_date", { ascending: true })
    .order("lot_code", { ascending: true });
  return { data: (data ?? []) as PendingWork[], error: error?.message ?? null };
}

/** One day's log, for CM 04 to pre-fill — the evening visit must re-send the morning's
 * sources, because the upsert replaces them (Finding 3). */
export async function readLogDay(
  lotId: string,
  date: string,
): Promise<Read<SmokeLogDay | null>> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("v_smoke_log_day")
    .select("*")
    .eq("lot_id", lotId)
    .eq("event_date", date)
    .maybeSingle();
  return {
    data: (data as SmokeLogDay | null) ?? null,
    error: error?.message ?? null,
  };
}

/** Every logged day of a lot, oldest first — CM 05's per-day summary. */
export async function readLogDays(lotId: string): Promise<Read<SmokeLogDay[]>> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("v_smoke_log_day")
    .select("*")
    .eq("lot_id", lotId)
    .order("event_date", { ascending: true });
  return { data: (data ?? []) as SmokeLogDay[], error: error?.message ?? null };
}
