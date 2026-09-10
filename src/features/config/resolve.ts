import "server-only";

import type { createClient } from "@/lib/supabase/server";

/* Read a dated config value as of an event date, for a screen to DISPLAY (lane F, OW 01 and
 * OW 02).
 *
 * WHY NOT fn_config_value. It is granted to nobody (rls_deny_all_test.sql sweep 1f) —
 * config_settings holds prices, and R20 keeps an L3 session out of them. An L1 screen reads
 * the same rows through v_config_history, which is L1 only in its WHERE (R34). This resolves
 * the way fn_config_value does (R12): the newest effective_from on or before the date. Global
 * rows only, because every key these screens read is global in API_DATA_MODEL.md's config
 * table.
 *
 * DISPLAY ONLY, NEVER A WRITE INPUT THE DATABASE WOULD NOT CHECK. Where a value feeds a write,
 * the function either resolves it itself (fn_create_transport_run snapshots
 * freight_alloc_method; fn_confirm_transport_receipt reads its own threshold), or the calling
 * action re-reads it here at submit time, server-side, never from a hidden input.
 *
 * NULL MEANS UNSET, AND NOTHING HERE DEFAULTS IT (ADR-023). The caller shows a
 * NotConfiguredNotice. A 10% or a 20% typed in TypeScript is the support ticket ADR-006
 * exists to prevent.
 */

type Db = Awaited<ReturnType<typeof createClient>>;

export type ConfigValue = {
  effective_from: string;
  value_numeric: number | null;
  value_text: string | null;
  value_json: unknown;
};

export async function configAt(
  supabase: Db,
  key: string,
  date: string,
): Promise<ConfigValue | null> {
  const { data } = await supabase
    .from("v_config_history")
    .select("effective_from, value_numeric, value_text, value_json")
    .eq("source", "CONFIG")
    .eq("item_key", key)
    .is("scope_location_id", null)
    .lte("effective_from", date)
    .order("effective_from", { ascending: false })
    .limit(1)
    .maybeSingle();
  return (data as ConfigValue | null) ?? null;
}

/** fn_config_boolean's reading, mirrored: text is cast the way Postgres casts to boolean,
 * json must be a real boolean. Anything else is null — unreadable is not false, because a
 * flag read as false is a rule silently switched off. */
export function configBoolean(v: ConfigValue | null): boolean | null {
  if (!v) return null;
  if (v.value_text !== null) {
    const t = v.value_text.trim().toLowerCase();
    if (["t", "true", "y", "yes", "on", "1"].includes(t)) return true;
    if (["f", "false", "n", "no", "off", "0"].includes(t)) return false;
    return null;
  }
  return typeof v.value_json === "boolean" ? v.value_json : null;
}
