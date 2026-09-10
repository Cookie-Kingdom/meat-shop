import Link from "next/link";
import { cva } from "class-variance-authority";

import { actionButton, control, Field } from "@/components/ui/controls";
import { Sheet } from "@/features/config/components/sheet";
import { thaiDate, thaiDateTime } from "@/lib/format/date";
import type { UnlockStatus } from "@/lib/rpc/unlock";
import { cn } from "@/lib/utils";
import { submitUnlockDecision } from "../actions";

/* UnlockPanel — OW 11, the unlock half (card ^ref-08). It sits on the same route as
 * ^ref-09's audit table.
 *
 * WHAT THE OWNER SEES, IN ORDER: the requests waiting for them; one opened through
 * `?unlock=<id>` with its impact (D07: "shown before the decision"), a required note, and
 * approve/reject; then the recent decisions, each naming who decided (UAT-12), or saying R28's
 * window decided it.
 *
 * Every row comes from `v_unlock_requests`, whose WHERE does the role test (R34). `impact`
 * is null for anyone but L1 there. The `(owner)` layout's requireRole is the mirror.
 *
 * SERVER-RENDERED, ZERO CLIENT JAVASCRIPT. Which request is open lives in the URL, and the
 * two buttons are one form with `name="decision"`. React sends the submitter's value with
 * the form data.
 */

export type UnlockImpact = {
  affected_daily_reports: number;
  affected_ledger_rows: number;
  sales_lines: number;
  sales_thb: number;
  meat_moved_kg: number;
  profit_thb: number | null;
};

export type UnlockRequestRow = {
  unlock_request_id: string;
  target_type: "DAILY_REPORT" | "LOT";
  target_id: string;
  location_id: string | null;
  location_name: string | null;
  report_date: string | null;
  lot_code: string | null;
  reason: string;
  status: UnlockStatus;
  requested_by: string;
  requested_by_name: string | null;
  requested_at: string;
  decided_by: string | null;
  decided_by_name: string | null;
  decided_at: string | null;
  decision_note: string | null;
  auto_approved: boolean;
  expires_at: string | null;
  impact: UnlockImpact | null;
};

const PANEL = "/owner/audit";

const STATUS_LABEL: Record<UnlockStatus, string> = {
  PENDING: "รออนุมัติ",
  APPROVED: "อนุมัติแล้ว",
  REJECTED: "ไม่อนุมัติ",
  EXPIRED: "หมดเวลาแล้ว",
};

const statusBadge = cva(
  "inline-flex h-7 shrink-0 items-center rounded-full px-3 text-caption",
  {
    variants: {
      status: {
        PENDING: "border border-accent text-accent",
        APPROVED: "bg-accent text-accent-fg",
        REJECTED: "bg-danger-subtle text-danger",
        EXPIRED: "bg-surface-sunken text-text-muted",
      },
    },
  },
);

const rejectButton =
  "inline-flex h-11 items-center justify-center rounded-md border border-danger bg-surface px-4 text-label text-danger hover:bg-danger-subtle";

/* ponytail: a local 2-decimal formatter. `lib/format/` has dates only so far, and the kg/THB
 * formatter belongs to whichever card needs it on a second screen. */
function two(n: number): string {
  return n.toLocaleString("th-TH", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

function targetLabel(row: UnlockRequestRow): string {
  const where = row.location_name ? ` · ${row.location_name}` : "";
  return row.target_type === "DAILY_REPORT"
    ? `วันที่ ${row.report_date ? thaiDate(row.report_date) : "—"}${where}`
    : `ล็อต ${row.lot_code ?? "—"}${where}`;
}

function ImpactList({ impact }: { impact: UnlockImpact | null }) {
  if (!impact) {
    return (
      <p className="text-caption text-text-muted">ยังคำนวณผลกระทบไม่ได้</p>
    );
  }
  const items: [string, string][] = [
    ["รายงานประจำวันที่เกี่ยวข้อง", `${impact.affected_daily_reports} วัน`],
    ["ยอดขาย", `${impact.sales_lines} รายการ · ${two(impact.sales_thb)} บาท`],
    [
      "สต็อก",
      `${impact.affected_ledger_rows} รายการเคลื่อนไหว · เนื้อ ${two(impact.meat_moved_kg)} กก.`,
    ],
    [
      "กำไร",
      impact.profit_thb === null
        ? "ยังไม่คำนวณ — รอรายงานกำไรขาดทุน"
        : `${two(impact.profit_thb)} บาท`,
    ],
  ];
  return (
    <dl className="grid gap-2 sm:grid-cols-2">
      {items.map(([label, value]) => (
        <div
          key={label}
          className="rounded-md border border-border bg-surface-sunken p-3"
        >
          <dt className="text-caption text-text-muted">{label}</dt>
          <dd className="text-body text-text-primary tabular-nums">{value}</dd>
        </div>
      ))}
    </dl>
  );
}

function DecisionSheet({ row }: { row: UnlockRequestRow }) {
  return (
    <Sheet
      title={`พิจารณาปลดล็อก · ${targetLabel(row)}`}
      subtitle={`ขอโดย ${row.requested_by_name ?? "—"} · ${thaiDateTime(row.requested_at)}`}
      closeHref={`${PANEL}#unlock`}
    >
      <p className="text-body text-text-primary">{row.reason}</p>
      <ImpactList impact={row.impact} />
      <form action={submitUnlockDecision} className="flex flex-col gap-3">
        <input
          type="hidden"
          name="unlock_request_id"
          value={row.unlock_request_id}
        />
        <Field
          label="เหตุผลของการตัดสินใจ"
          hint="อนุมัติแล้วแก้ได้ตามจำนวนชั่วโมงที่ตั้งไว้ในหน้า ตั้งค่าระบบ แล้วล็อกกลับเอง"
        >
          <textarea
            name="decision_note"
            required
            rows={3}
            className={cn(control, "h-auto py-2")}
          />
        </Field>
        <div className="flex flex-wrap gap-3">
          <button
            type="submit"
            name="decision"
            value="APPROVED"
            className={actionButton}
          >
            อนุมัติปลดล็อก
          </button>
          <button
            type="submit"
            name="decision"
            value="REJECTED"
            className={rejectButton}
          >
            ไม่อนุมัติ
          </button>
        </div>
      </form>
    </Sheet>
  );
}

export function UnlockPanel({
  pending,
  recent,
  openId,
  saved,
  err,
  readError,
}: {
  pending: UnlockRequestRow[];
  recent: UnlockRequestRow[];
  /** `?unlock=<id>` — the request whose sheet is open. */
  openId: string;
  saved: boolean;
  /** `?unlock_err=` — already a Thai sentence. */
  err: string;
  readError: string | null;
}) {
  const open = openId
    ? pending.find((r) => r.unlock_request_id === openId)
    : undefined;

  return (
    <section id="unlock" className="flex flex-col gap-3">
      <h2 className="text-h2 text-text-primary">คำขอปลดล็อก</h2>

      {saved ? (
        <p className="rounded-lg border border-accent bg-surface p-4 text-body text-text-primary">
          บันทึกการตัดสินใจแล้ว
        </p>
      ) : null}
      {err ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-4 text-body text-danger">
          {err}
        </p>
      ) : null}

      {readError ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-4 text-body text-danger">
          อ่านคำขอปลดล็อกไม่สำเร็จ — {readError}
        </p>
      ) : pending.length === 0 ? (
        <p className="text-body text-text-secondary">ไม่มีคำขอรออนุมัติ</p>
      ) : (
        <ul className="flex flex-col gap-2">
          {pending.map((r) => (
            <li
              key={r.unlock_request_id}
              className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border bg-surface p-4"
            >
              <div className="flex min-w-0 flex-col gap-1">
                <span className="text-label text-text-primary">
                  {targetLabel(r)}
                </span>
                <span className="text-caption text-text-secondary">
                  {r.requested_by_name ?? "—"} · {thaiDateTime(r.requested_at)}
                </span>
                <span className="text-body text-text-secondary">
                  {r.reason}
                </span>
              </div>
              <Link
                href={`${PANEL}?unlock=${r.unlock_request_id}#unlock`}
                className={actionButton}
              >
                พิจารณา
              </Link>
            </li>
          ))}
        </ul>
      )}

      {open ? <DecisionSheet row={open} /> : null}
      {openId && !open && !readError ? (
        <p className="text-caption text-text-muted">
          คำขอนี้ไม่ได้รออนุมัติแล้ว — อาจได้รับการตัดสินใจไปแล้ว
        </p>
      ) : null}

      {recent.length > 0 ? (
        <div className="flex flex-col gap-2">
          <h3 className="text-label text-text-secondary">ตัดสินใจล่าสุด</h3>
          <ul className="flex flex-col gap-2">
            {recent.map((r) => (
              <li
                key={r.unlock_request_id}
                className="flex flex-col gap-1 rounded-lg border border-border bg-surface p-3"
              >
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="text-label text-text-primary">
                    {targetLabel(r)}
                  </span>
                  <span className={statusBadge({ status: r.status })}>
                    {STATUS_LABEL[r.status]}
                  </span>
                </div>
                <span className="text-caption text-text-secondary">
                  {r.auto_approved
                    ? "อนุมัติอัตโนมัติ (อยู่ในกรอบวันย้อนแก้)"
                    : `ผู้ตัดสินใจ: ${r.decided_by_name ?? "—"}`}
                  {r.decided_at ? ` · ${thaiDateTime(r.decided_at)}` : ""}
                  {r.status === "APPROVED" && r.expires_at
                    ? ` · แก้ได้ถึง ${thaiDateTime(r.expires_at)}`
                    : ""}
                </span>
                {r.decision_note ? (
                  <span className="text-body text-text-secondary">
                    {r.decision_note}
                  </span>
                ) : null}
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </section>
  );
}
