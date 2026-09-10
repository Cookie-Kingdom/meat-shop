import "server-only";

import { cache } from "react";

import type { UserRole } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

/* Typed access to the first-run gate (card ^ref-61, ADR-023).
 *
 * `v_config_readiness` is the only read. It carries names, a severity, the feature each item
 * stops and one boolean — never a value — so every role reads the same rows and this module
 * is safe to call from any route group.
 *
 * ADVISORY. Nothing here refuses a write: every BLOCK item raises CONFIG_NOT_SET from the RPC
 * that consumes it (R35). What this module decides is what a screen SAYS — the Owner's banner
 * and setup list, the L2/L3 wait-for-Owner notice, and which entry points a screen greys out.
 * Delete it and nothing unconfigured can be written; the screens just stop explaining why.
 *
 * OTHER LANES: grey out an entry point when its feature is waiting —
 *   `waitingFeatures((await getReadiness()).rows, role).has("F10")`
 * The feature codes are the view's `feature` column (F1, F3, F5, F6, F7, F8, F10, F11, …).
 */

export type ReadinessSource =
  | "config_settings"
  | "smoke_fee_tiers"
  | "product_prices"
  | "packaging_full_stock"
  | "opening_balance_close";

/** One row of `v_config_readiness`. */
export type ReadinessRow = {
  item_key: string;
  source: ReadinessSource;
  label_th: string;
  severity: "BLOCK" | "WARN";
  feature: string;
  gates_th: string;
  affects_roles: UserRole[];
  is_set: boolean;
  sort_order: number;
};

export type Readiness = { rows: ReadinessRow[]; error: string | null };

type Client = Awaited<ReturnType<typeof createClient>>;

async function read(supabase: Client): Promise<Readiness> {
  const { data, error } = await supabase
    .from("v_config_readiness")
    .select("*")
    .order("sort_order");
  return {
    rows: (data ?? []) as ReadinessRow[],
    error: error ? error.message : null,
  };
}

/** Once per request: a template's banner and the page beneath it share one round trip. */
export const getReadiness = cache(
  async (): Promise<Readiness> => read(await createClient()),
);

/** For sign-in, which must ask through the client that just signed in: that client holds the
 * new session in memory, and a fresh one built from the request's cookies may not yet. */
export async function hasUnsetBlocking(supabase: Client): Promise<boolean> {
  const { rows } = await read(supabase);
  return unsetBlocking(rows).length > 0;
}

/** Every BLOCK item still unset — what the Owner's banner names. */
export function unsetBlocking(rows: ReadinessRow[]): ReadinessRow[] {
  return rows.filter((r) => r.severity === "BLOCK" && !r.is_set);
}

/** The unset BLOCK items that stop something this role does — what the L2/L3 notice names. */
export function waitingFor(
  rows: ReadinessRow[],
  role: UserRole,
): ReadinessRow[] {
  return unsetBlocking(rows).filter((r) => r.affects_roles.includes(role));
}

/** The features a screen for this role should grey out while the Owner has not set them. */
export function waitingFeatures(
  rows: ReadinessRow[],
  role: UserRole,
): Set<string> {
  return new Set(waitingFor(rows, role).map((r) => r.feature));
}

/* ── The one write: the Owner-run packaging seed ────────────────────────────────────────
 * `fn_seed_packaging_items` — the seven BR 08 materials, from /owner/setup, never from a
 * migration (PLAN-config-seed.md Finding 10). The idempotency key is minted in the Server
 * Action, once per submit (ADR-005, R38). An unmapped refusal is shown verbatim, never
 * swallowed. */

export type RpcResult =
  | { ok: true }
  | { ok: false; code: string; message: string };

const MESSAGES: Record<string, string> = {
  IDEMPOTENCY_KEY_REQUIRED: "คำสั่งบันทึกไม่สมบูรณ์ กรุณาลองใหม่",
  FORBIDDEN: "เฉพาะเจ้าของร้านเพิ่มรายการวัสดุได้",
  NO_ACTOR: "บัญชีนี้ถูกปิดใช้งานแล้ว",
};

function toResult(error: { message: string } | null): RpcResult {
  if (!error) return { ok: true };
  const code = error.message.match(/^([A-Z_]+):/)?.[1] ?? "";
  return { ok: false, code, message: MESSAGES[code] ?? error.message };
}

export async function seedPackagingItems(
  idempotencyKey: string,
): Promise<RpcResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fn_seed_packaging_items", {
    p_idempotency_key: idempotencyKey,
  });
  return toResult(error);
}
