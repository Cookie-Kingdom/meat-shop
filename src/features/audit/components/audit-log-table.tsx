import { cva } from "class-variance-authority";

import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";

/* AuditLogTable — OW 11, the audit half (card ^ref-09).
 *
 * Contract: `design/DESIGN-CONTRACTS.md` → five columns, ผู้แก้ · เวลา · Field · ค่าเดิม ·
 * ค่าใหม่, and NEVER editable. There is no row action and no form here on purpose: the
 * audit trail is the record of what other screens did, and a screen that can edit it is
 * the one thing ^ref-06's append-only guards exist to make impossible.
 *
 * Rendered through the shared `ResponsiveTable`, extracted at OW 10 (^ref-12) as ^ref-09's
 * plan said it would be. This file went from an inline card list plus an inline table to a
 * column set; what it kept is everything that is about the audit trail specifically — the
 * badge, the three clocks, the null/empty distinction — and what it gave up is the second
 * copy of "cards below md:, table above".
 */

export type AuditEntry = {
  audit_id: string;
  changed_at: string;
  table_name: string;
  row_id: string | null;
  action: string;
  actor_id: string | null;
  actor_name: string | null;
  actor_role: string | null;
  event_date: string | null;
  field_name: string | null;
  old_value: string | null;
  new_value: string | null;
  reason: string | null;
};

/* ADR-010 — stored timestamptz, read in Asia/Bangkok. The business runs in one timezone
 * and the audit trail is the one screen where "which clock" is the question being asked,
 * so the zone is pinned here rather than left to the viewer's browser. */
const BANGKOK = new Intl.DateTimeFormat("th-TH", {
  timeZone: "Asia/Bangkok",
  dateStyle: "medium",
  timeStyle: "short",
});

const ACTION_LABEL: Record<string, string> = {
  INSERT: "สร้าง",
  UPDATE: "แก้ไข",
  DELETE: "ลบ",
};

/* A creation is one event, not one edit per column (see the view header), so field_name is
 * null for INSERT and DELETE and the Field cell says what happened instead. */
const WHOLE_ROW_LABEL: Record<string, string> = {
  INSERT: "สร้างรายการใหม่",
  DELETE: "ลบทั้งรายการ",
};

const actionBadge = cva(
  "inline-flex items-center rounded-sm px-1.5 py-0.5 text-caption font-medium",
  {
    variants: {
      action: {
        INSERT: "bg-success-subtle text-success",
        UPDATE: "bg-accent-subtle text-accent",
        /* DELETE is `danger` because a deletion in this system is an anomaly worth
         * spotting, not because the row is an error — see DESIGN.md on colour as a
         * business rule. */
        DELETE: "bg-danger-subtle text-danger",
        OTHER: "bg-surface-sunken text-text-secondary",
      },
    },
    defaultVariants: { action: "OTHER" },
  },
);

type ActionVariant = "INSERT" | "UPDATE" | "DELETE" | "OTHER";

function variantFor(action: string): ActionVariant {
  return action === "INSERT" || action === "UPDATE" || action === "DELETE"
    ? action
    : "OTHER";
}

function ActionBadge({ action }: { action: string }) {
  return (
    <span className={actionBadge({ action: variantFor(action) })}>
      {ACTION_LABEL[action] ?? action}
    </span>
  );
}

/* null and "" are different facts. A field cleared to the empty string is an edit somebody
 * made; a null is a column that was never there. */
function Value({ value }: { value: string | null }) {
  if (value === null) return <span className="text-text-muted">—</span>;
  if (value === "") return <span className="text-text-muted">(ว่าง)</span>;
  return <>{value}</>;
}

function fieldLabel(entry: AuditEntry) {
  return entry.field_name ?? WHOLE_ROW_LABEL[entry.action] ?? entry.action;
}

const COLUMNS: Column<AuditEntry>[] = [
  {
    id: "actor",
    header: "ผู้แก้",
    priority: 1,
    cell: (e) => (
      <>
        <span className="block">{e.actor_name ?? "ไม่ทราบผู้แก้"}</span>
        <span className="block text-caption text-text-muted">
          {e.actor_role ?? "—"}
        </span>
      </>
    ),
  },
  {
    id: "changed_at",
    header: "เวลา",
    numeric: true,
    className: "whitespace-nowrap text-text-secondary",
    cell: (e) => BANGKOK.format(new Date(e.changed_at)),
  },
  {
    id: "field",
    header: "Field",
    cell: (e) => (
      <>
        <span className="block text-text-primary">{fieldLabel(e)}</span>
        <span className="mt-1 flex items-center gap-2 text-caption text-text-muted">
          <ActionBadge action={e.action} />
          {e.table_name}
        </span>
      </>
    ),
  },
  /* `title` rather than a tap handler: the full value is one native tooltip away and costs
   * no client bundle. The card mode shows it in full — the worst case is two long Thai
   * strings (a Remark edit) and a card has the room a 360px table cell does not. */
  {
    id: "old",
    header: "ค่าเดิม",
    className: "max-w-[14rem] truncate",
    cell: (e) => (
      <span title={e.old_value ?? undefined}>
        <Value value={e.old_value} />
      </span>
    ),
  },
  {
    id: "new",
    header: "ค่าใหม่",
    className: "max-w-[14rem] truncate",
    cell: (e) => (
      <span title={e.new_value ?? undefined}>
        <Value value={e.new_value} />
      </span>
    ),
  },
  {
    id: "reason",
    header: "เหตุผล",
    cell: (e) =>
      e.reason ? e.reason : <span className="text-text-muted">—</span>,
  },
];

export function AuditLogTable({ entries }: { entries: AuditEntry[] }) {
  return (
    <ResponsiveTable
      columns={COLUMNS}
      rows={entries}
      /* changed_at alone is not unique — one UPDATE expands to a row per changed field, all
       * sharing it. audit_id plus field_name is what makes a row identifiable. */
      keyField={(e) => `${e.audit_id}-${e.field_name ?? ""}`}
      emptyState={
        <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
          ไม่พบรายการที่ตรงกับตัวกรอง
        </p>
      }
    />
  );
}
