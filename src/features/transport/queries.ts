import "server-only";

import type { PoRoundRow } from "@/features/purchasing/types";
import type { createClient } from "@/lib/supabase/server";
import type {
  FreightLineRow,
  OutstandingRow,
  Place,
  TransportRunRow,
  VarianceRow,
} from "./types";

/* OW 02's reads (card ^ref-24). Each goes through a view carrying its own role test (R34):
 * v_transport_runs, v_freight_allocation, v_po_rounds and v_config_catalogue are L1 only,
 * and v_outstanding_receipts / v_transport_variance give L1 every line. `.from()` on a view
 * is the sanctioned read path; writes go through src/lib/rpc/transport.ts only.
 *
 * ponytail: the run list is the newest 30 and the variance list the newest 50, with no
 * pagination. Outstanding receipts are uncapped, because a line that is still outstanding is
 * never history. Ceiling: the first Owner looking for an older run. Add `.range()` then.
 */

type Db = Awaited<ReturnType<typeof createClient>>;
type Read<T> = { rows: T[]; error: string | null };

function read<T>(res: {
  data: unknown;
  error: { message: string } | null;
}): Read<T> {
  return { rows: (res.data ?? []) as T[], error: res.error?.message ?? null };
}

export async function listRuns(db: Db): Promise<Read<TransportRunRow>> {
  return read(
    await db
      .from("v_transport_runs")
      .select("*")
      .order("event_date", { ascending: false })
      .order("created_at", { ascending: false })
      .limit(30),
  );
}

export async function getRun(
  db: Db,
  runId: string,
): Promise<TransportRunRow | null> {
  const { data } = await db
    .from("v_transport_runs")
    .select("*")
    .eq("run_id", runId)
    .maybeSingle();
  return (data as TransportRunRow | null) ?? null;
}

export async function runLines(
  db: Db,
  runId: string,
): Promise<Read<FreightLineRow>> {
  return read(
    await db
      .from("v_freight_allocation")
      .select("*")
      .eq("run_id", runId)
      .order("dispatched_weight_kg", { ascending: false }),
  );
}

export async function listOutstanding(db: Db): Promise<Read<OutstandingRow>> {
  return read(
    await db
      .from("v_outstanding_receipts")
      .select("*")
      .order("dispatched_at", { ascending: true }),
  );
}

/** Lines that have been signed for — the ones a variance can be read off. */
export async function listVariance(db: Db): Promise<Read<VarianceRow>> {
  return read(
    await db
      .from("v_transport_variance")
      .select("*")
      .not("received_at", "is", null)
      .order("received_at", { ascending: false })
      .limit(50),
  );
}

/** Every active location's name and kind, for naming a line's destination and deciding who
 * signs for it. */
export async function listPlaces(db: Db): Promise<Map<string, Place>> {
  const { data } = await db
    .from("v_config_catalogue")
    .select("id, name_th, unit")
    .eq("kind", "LOCATION");
  const rows = (data ?? []) as { id: string; name_th: string; unit: string }[];
  return new Map(rows.map((r) => [r.id, { name: r.name_th, kind: r.unit }]));
}

/** The rounds whose lot is waiting for a truck. fn_dispatch_transport_line does not check
 * lot state (Cross-lane gaps), so this list — and the action's re-check — is what keeps a
 * lot off two trucks. */
export async function listDispatchableLots(db: Db): Promise<Read<PoRoundRow>> {
  return read(
    await db
      .from("v_po_rounds")
      .select("*")
      .eq("lot_state", "PO_CREATED")
      .order("dispatch_date", { ascending: true })
      .order("lot_code", { ascending: true }),
  );
}

export async function roundsByLotIds(
  db: Db,
  lotIds: string[],
): Promise<Read<PoRoundRow>> {
  if (lotIds.length === 0) return { rows: [], error: null };
  return read(await db.from("v_po_rounds").select("*").in("lot_id", lotIds));
}
