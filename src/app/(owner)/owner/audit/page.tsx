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
import { one } from "@/lib/params";
import { createClient } from "@/lib/supabase/server";

/* OW 11 — the audit half (card ^ref-09). Skeleton S8: title, filter bar, table,
 * pagination. No bottom action bar; the audit trail has no actions at all.
 *
 * THE ROLE GATE IS NOT HERE. `v_audit_trail` carries `where fn_current_role() = 'L1_OWNER'`
 * and an L2 or L3 session reads zero rows from the database (ADR-004, R34). The `(owner)`
 * layout's `requireRole` 403s them first, but that is the mirror — delete it and this page
 * still shows nothing. That ordering is the card's acceptance line.
 *
 * `supabase.from(...)` is the sanctioned path here: this is a READ through a view under
 * RLS. The CLAUDE.md prohibition is on `.from()` for a write, which goes through an RPC.
 *
 * Filters and page live in `searchParams`, not client state — a URL that reproduces a
 * filtered view is worth more than an onChange handler, and this page ships no client
 * JavaScript at all as a result.
 *
 * ponytail: the UnlockPanel half of OW 11 is not here. It needs fn_request_unlock /
 * fn_decide_unlock (^ref-08), which is blocked on three unanswered Owner questions
 * (TICKET-004); building it now means guessing one of them. ^ref-08 adds the panel to
 * this same route.
 */

const PAGE_SIZE = 50;

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

  const { data, error } = await query;
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
    <div className="flex flex-col gap-4">
      <h1 className="text-h1 text-text-primary">ประวัติการแก้ไข</h1>

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
        <p className="rounded-lg border border-danger bg-danger-subtle p-4 text-body text-danger">
          อ่านประวัติการแก้ไขไม่สำเร็จ — {error.message}
        </p>
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
    </div>
  );
}
