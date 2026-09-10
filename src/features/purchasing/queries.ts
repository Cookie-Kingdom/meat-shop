import "server-only";

import type { createClient } from "@/lib/supabase/server";
import type {
  LocationOption,
  PoRegisterRow,
  PoRoundRow,
  SupplierOption,
} from "./types";

/* OW 01's reads (card ^ref-20). Every one goes through a view under its own role test
 * (R34): v_po_register, v_po_rounds, v_supplier_options and v_config_catalogue are all L1
 * only in their WHERE. `supabase.from(...)` is the sanctioned path for a READ through a view;
 * the CLAUDE.md prohibition is on `.from()` for a write.
 *
 * An error is returned, not thrown and not swallowed: the page says the read failed instead
 * of rendering an empty list that looks like "no POs yet".
 *
 * ponytail: the register is capped at the newest 100 POs with no pagination. At a few POs a
 * week that is two years of history. Ceiling: the first Owner who scrolls past 100. The fix
 * is `.range()` plus the same page links OW 10 uses.
 */

type Db = Awaited<ReturnType<typeof createClient>>;
type Read<T> = { rows: T[]; error: string | null };

function read<T>(res: {
  data: unknown;
  error: { message: string } | null;
}): Read<T> {
  return {
    rows: (res.data ?? []) as T[],
    error: res.error?.message ?? null,
  };
}

export async function listPoRegister(db: Db): Promise<Read<PoRegisterRow>> {
  return read(
    await db
      .from("v_po_register")
      .select("*")
      .order("created_at", { ascending: false })
      .limit(100),
  );
}

export async function listRounds(
  db: Db,
  poId: string,
): Promise<Read<PoRoundRow>> {
  return read(
    await db.from("v_po_rounds").select("*").eq("po_id", poId).order("seq"),
  );
}

export async function listSuppliers(db: Db): Promise<Read<SupplierOption>> {
  return read(
    await db.from("v_supplier_options").select("id, name").order("name"),
  );
}

/** The chef houses a round may be booked to. fn_add_po_delivery refuses any other kind
 * (LOCATION_KIND_INVALID, BR11), so no other kind is offered. */
export async function listChefHouses(db: Db): Promise<Read<LocationOption>> {
  return read(
    await db
      .from("v_config_catalogue")
      .select("id, name_th, unit")
      .eq("kind", "LOCATION")
      .eq("unit", "CHEF_HOUSE")
      .order("name_th"),
  );
}
