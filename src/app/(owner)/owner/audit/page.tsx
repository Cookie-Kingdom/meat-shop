import Link from "next/link";

import {
  actionButton,
  actionLink,
  control,
  Field,
} from "@/components/ui/controls";
import {
  AuditLogTable,
  type AuditEntry,
} from "@/features/audit/components/audit-log-table";
import {
  UnlockPanel,
  type UnlockRequestRow,
} from "@/features/unlock/components/unlock-panel";
import { one } from "@/lib/params";
import { createClient } from "@/lib/supabase/server";
import { ReadError } from "@/components/shared/read-error";

/* OW 11 — Unlock and Audit Log. The audit half is card ^ref-09, the unlock half is ^ref-08.
 * Skeleton S8: title, the unlock panel, then filter bar, table, pagination.
 *
 * THE ROLE GATE IS NOT HERE. `v_audit_trail` carries `where fn_current_role() = 'L1_OWNER'`
 * and an L2 or L3 session reads zero rows from the database (ADR-004, R34). The `(owner)`
 * layout's `requireRole` 403s them first, but that is the mirror — delete it and this page
 * still shows nothing. That ordering is the card's acceptance line.
 *
 * THE UNLOCK HALF reads `v_unlock_requests`, whose WHERE is the same kind of gate (R34). It
 * shows L1 everything, and its `impact` column is null for any other role. It writes through
 * `fn_decide_unlock` via `features/unlock/actions.ts`. Which request is open lives in
 * `?unlock=`, and the outcome comes back as `?unlock_saved` or `?unlock_err`.
 *
 * `supabase.from(...)` is the sanctioned path here: this is a READ through a view under
 * RLS. The CLAUDE.md prohibition is on `.from()` for a write, which goes through an RPC.
 *
 * Filters and page live in `searchParams`, not client state — a URL that reproduces a
 * filtered view is worth more than an onChange handler, and this page ships no client
 * JavaScript at all as a result.
 */

const PAGE_SIZE = 50;

/** How many decided requests the panel lists. The full history is the audit table below,
 * where every unlock_requests write appears as its own row. */
const RECENT_DECISIONS = 10;

const ACTIONS = [
  { value: "INSERT", label: "สร้าง" },
  { value: "UPDATE", label: "แก้ไข" },
  { value: "DELETE", label: "ลบ" },
];

const ROLES = [
  { value: "L1_OWNER", label: "เจ้าของกิจการ" },
  { value: "L2_BRANCH_ADMIN", label: "แอดมินสาขา" },
  { value: "L3_CM_OPERATOR", label: "ผู้ปฏิบัติงานเชียงใหม่" },
];

export default async function AuditPage(props: PageProps<"/owner/audit">) {
  const params = await props.searchParams;
  const action = one(params.action);
  const role = one(params.role);
  const table = one(params.table).trim();
  const page = Math.max(1, Number.parseInt(one(params.page), 10) || 1);
  const unlockOpen = one(params.unlock);
  const unlockSaved = one(params.unlock_saved) === "1";
  const unlockErr = one(params.unlock_err);

  const supabase = await createClient();

  const from = (page - 1) * PAGE_SIZE;
  let query = supabase
    .from("v_audit_trail")
    .select("*")
    // changed_at alone is not unique — one UPDATE expands to a row per changed field, all
    // sharing it — and a non-deterministic sort silently duplicates and skips rows across
    // pages. audit_id then field_name makes the order total.
    .order("changed_at", { ascending: false })
    .order("audit_id", { ascending: false })
    .order("field_name", { ascending: true, nullsFirst: true })
    // PAGE_SIZE + 1, so "is there a next page" costs one extra row instead of a COUNT over
    // a log that grows without bound (BR22).
    .range(from, from + PAGE_SIZE);

  if (action) query = query.eq("action", action);
  if (role) query = query.eq("actor_role", role);
  if (table) query = query.eq("table_name", table);

  const [audit, pendingRes, recentRes] = await Promise.all([
    query,
    // Oldest first: the request that has waited longest is the one a branch is stuck on.
    supabase
      .from("v_unlock_requests")
      .select("*")
      .eq("status", "PENDING")
      .order("requested_at", { ascending: true }),
    supabase
      .from("v_unlock_requests")
      .select("*")
      .neq("status", "PENDING")
      .order("decided_at", { ascending: false, nullsFirst: false })
      .limit(RECENT_DECISIONS),
  ]);

  const { data, error } = audit;
  const rows = (data ?? []) as AuditEntry[];
  const hasNext = rows.length > PAGE_SIZE;
  const entries = rows.slice(0, PAGE_SIZE);

  const pageHref = (target: number) => {
    const next = new URLSearchParams();
    if (action) next.set("action", action);
    if (role) next.set("role", role);
    if (table) next.set("table", table);
    if (target > 1) next.set("page", String(target));
    const qs = next.toString();
    return qs ? `/owner/audit?${qs}` : "/owner/audit";
  };

  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-h1 text-text-primary">ปลดล็อกและประวัติการแก้ไข</h1>

      <UnlockPanel
        pending={(pendingRes.data ?? []) as UnlockRequestRow[]}
        recent={(recentRes.data ?? []) as UnlockRequestRow[]}
        openId={unlockOpen}
        saved={unlockSaved}
        err={unlockErr}
        readError={
          pendingRes.error?.message ?? recentRes.error?.message ?? null
        }
      />

      <section className="flex flex-col gap-4">
        <h2 className="text-h2 text-text-primary">ประวัติการแก้ไข</h2>

        {/* A plain GET form. Submitting rewrites the URL, which is the state. */}
        <form
          method="get"
          className="flex flex-wrap items-end gap-3 rounded-lg border border-border bg-surface p-4"
        >
          <Field label="การกระทำ">
            <select name="action" defaultValue={action} className={control}>
              <option value="">ทั้งหมด</option>
              {ACTIONS.map((a) => (
                <option key={a.value} value={a.value}>
                  {a.label}
                </option>
              ))}
            </select>
          </Field>

          <Field label="สิทธิ์ผู้แก้">
            <select name="role" defaultValue={role} className={control}>
              <option value="">ทั้งหมด</option>
              {ROLES.map((r) => (
                <option key={r.value} value={r.value}>
                  {r.label}
                </option>
              ))}
            </select>
          </Field>

          {/* ponytail: a text input, not a select. The table list is 35 rows and growing, and
              the only cheap source for it is `select distinct table_name` over this view —
              which cannot skip the per-field expansion, so it costs a full scan per page
              load. Make it a select when something else already needs that list. */}
          <Field label="ตาราง">
            <input
              type="text"
              name="table"
              defaultValue={table}
              placeholder="เช่น purchase_orders"
              className={control}
            />
          </Field>

          <button type="submit" className={actionButton}>
            กรอง
          </button>
        </form>

        {error ? (
          <ReadError title="อ่านประวัติการแก้ไขไม่สำเร็จ" raw={error.message} />
        ) : (
          <AuditLogTable entries={entries} />
        )}

        <nav className="flex items-center justify-between gap-4">
          {page > 1 ? (
            <Link href={pageHref(page - 1)} className={actionLink}>
              ← ก่อนหน้า
            </Link>
          ) : (
            <span />
          )}
          <span className="text-caption text-text-secondary tabular-nums">
            หน้า {page}
          </span>
          {hasNext ? (
            <Link href={pageHref(page + 1)} className={actionLink}>
              ถัดไป →
            </Link>
          ) : (
            <span />
          )}
        </nav>
      </section>
    </div>
  );
}
