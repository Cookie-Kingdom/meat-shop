import { cva } from "class-variance-authority";

/* AuditLogTable — OW 11, the audit half (card ^ref-09).
 *
 * Contract: `design/DESIGN-CONTRACTS.md` → five columns, ผู้แก้ · เวลา · Field · ค่าเดิม ·
 * ค่าใหม่, and NEVER editable. There is no row action and no form here on purpose: the
 * audit trail is the record of what other screens did, and a screen that can edit it is
 * the one thing ^ref-06's append-only guards exist to make impossible.
 *
 * Cards below `md:`, table at and above. That is not a fallback — five columns do not fit
 * at 360px, and `LAYOUT-SKELETONS.md` S8 says the card mode is the real design here.
 *
 * ponytail: this is not the shared `ResponsiveTable` organism from COMPONENT-INVENTORY.md.
 * That organism is listed as shared across OW 03, OW 08, OW 10, OW 11 and BR 08, and four
 * of those five screens do not exist — its `columns`/`priority` props would be invented
 * from one caller. Extract it at OW 10 (^ref-12), the second S8 screen and the first real
 * evidence of what the props need to be.
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

function Value({ value }: { value: string | null }) {
  if (value === null) return <span className="text-text-muted">—</span>;
  if (value === "") return <span className="text-text-muted">(ว่าง)</span>;
  return <>{value}</>;
}

function fieldLabel(entry: AuditEntry) {
  return entry.field_name ?? WHOLE_ROW_LABEL[entry.action] ?? entry.action;
}

export function AuditLogTable({ entries }: { entries: AuditEntry[] }) {
  if (entries.length === 0) {
    return (
      <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
        ไม่พบรายการที่ตรงกับตัวกรอง
      </p>
    );
  }

  return (
    <>
      {/* Cards, below md:. Both values in full — the worst case is two long Thai strings
          (a Remark edit) and a card has the room a 360px table cell does not. */}
      <ul className="flex flex-col gap-3 md:hidden">
        {entries.map((entry) => (
          <li
            key={`${entry.audit_id}-${entry.field_name ?? ""}`}
            className="flex flex-col gap-2 rounded-lg border border-border bg-surface p-4"
          >
            <div className="flex items-start justify-between gap-2">
              <span className="text-label text-text-primary">
                {entry.actor_name ?? "ไม่ทราบผู้แก้"}
              </span>
              <ActionBadge action={entry.action} />
            </div>
            <span className="text-caption text-text-secondary">
              {BANGKOK.format(new Date(entry.changed_at))} · {entry.table_name}
            </span>
            <span className="text-label text-text-primary">
              {fieldLabel(entry)}
            </span>
            <dl className="flex flex-col gap-1 text-body-sm">
              <div className="flex gap-2">
                <dt className="shrink-0 text-text-secondary">ค่าเดิม</dt>
                <dd className="break-words text-text-primary">
                  <Value value={entry.old_value} />
                </dd>
              </div>
              <div className="flex gap-2">
                <dt className="shrink-0 text-text-secondary">ค่าใหม่</dt>
                <dd className="break-words text-text-primary">
                  <Value value={entry.new_value} />
                </dd>
              </div>
            </dl>
            {entry.reason ? (
              <p className="text-caption text-text-secondary">
                เหตุผล: {entry.reason}
              </p>
            ) : null}
          </li>
        ))}
      </ul>

      {/* Table, md: and up. Owns its own horizontal overflow (S8). */}
      <div className="hidden overflow-x-auto rounded-lg border border-border bg-surface md:block">
        <table className="w-full min-w-[52rem] text-body-sm">
          <thead className="border-b border-border text-label text-text-secondary">
            <tr>
              <th className="px-4 py-3 text-left font-medium">ผู้แก้</th>
              <th className="px-4 py-3 text-left font-medium">เวลา</th>
              <th className="px-4 py-3 text-left font-medium">Field</th>
              <th className="px-4 py-3 text-left font-medium">ค่าเดิม</th>
              <th className="px-4 py-3 text-left font-medium">ค่าใหม่</th>
            </tr>
          </thead>
          <tbody>
            {entries.map((entry) => (
              <tr
                key={`${entry.audit_id}-${entry.field_name ?? ""}`}
                className="border-b border-border last:border-b-0"
              >
                <td className="px-4 py-3 align-top text-text-primary">
                  <span className="block">
                    {entry.actor_name ?? "ไม่ทราบผู้แก้"}
                  </span>
                  <span className="block text-caption text-text-muted">
                    {entry.actor_role ?? "—"}
                  </span>
                </td>
                <td className="px-4 py-3 align-top whitespace-nowrap text-text-secondary tabular-nums">
                  {BANGKOK.format(new Date(entry.changed_at))}
                </td>
                <td className="px-4 py-3 align-top">
                  <span className="block text-text-primary">
                    {fieldLabel(entry)}
                  </span>
                  <span className="mt-1 flex items-center gap-2 text-caption text-text-muted">
                    <ActionBadge action={entry.action} />
                    {entry.table_name}
                  </span>
                </td>
                {/* `title` rather than a tap handler: the full value is one native tooltip
                    away and costs no client bundle. The card mode shows it in full. */}
                <td
                  className="max-w-[14rem] truncate px-4 py-3 align-top text-text-primary"
                  title={entry.old_value ?? undefined}
                >
                  <Value value={entry.old_value} />
                </td>
                <td
                  className="max-w-[14rem] truncate px-4 py-3 align-top text-text-primary"
                  title={entry.new_value ?? undefined}
                >
                  <Value value={entry.new_value} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
