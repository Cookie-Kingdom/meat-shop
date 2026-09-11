import Link from "next/link";
import type { ReactNode } from "react";

import { actionLink, control, Field } from "@/components/ui/controls";
import { thaiDate, thaiDateTime } from "@/lib/format/date";
import { kg } from "@/lib/format/weight";
import { cn } from "@/lib/utils";
import { submitReturnPickupDate } from "../actions";
import type { ReturnPendingRow } from "../types";
import { ActionBar, primaryAction } from "./action-bar";
import { ReturnStateBadge } from "./return-state-badge";

/* OW 05's full-screen detail (S3). It takes ONE INPUT: the day the truck collects the lot
 * (LAYOUT-SKELETONS.md, "Receive date is the only input — no cost entry", UAT-23). A cost
 * field here would reopen ADR-015, so there is none, and TC-39 checks the rendered page for one.
 *
 * Server-rendered, zero client JavaScript, like OW 10: the form posts to a Server Action and
 * the outcome comes back in the URL.
 *
 * Setting the date books no truck. Closing a lot creates no transport job, and neither does
 * this. The return run is created on OW 02, and fn_create_transport_run admits a lot there
 * only once it is RETURN_SCHEDULED (BR17, R26). Hence the link after saving.
 *
 * `min` is the close date in Asia/Bangkok (ADR-010). fn_set_return_pickup_date compares against
 * `closed_at::date`, in the session's zone. See PLAN-movement.md, Cross-lane gaps. */

const BANGKOK_DATE = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Bangkok",
  dateStyle: "short",
});

function Summary({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex min-h-12 items-center justify-between gap-3 px-4 py-2">
      <dt className="text-body-sm text-text-secondary">{label}</dt>
      <dd className="text-right text-body text-text-primary tabular-nums">
        {children}
      </dd>
    </div>
  );
}

export function ReturnDateForm({
  row,
  onTruck,
  idempotencyKey,
  today,
  saved,
  err,
}: {
  row: ReturnPendingRow;
  onTruck: boolean;
  idempotencyKey: string;
  today: string;
  saved: boolean;
  err: string;
}) {
  const scheduled = row.state === "RETURN_SCHEDULED";
  const closedOn = row.closed_at
    ? BANGKOK_DATE.format(new Date(row.closed_at))
    : undefined;

  return (
    <div className="mx-auto flex w-full max-w-[720px] flex-col gap-4">
      <Link href="/owner/returns" className={actionLink}>
        ← รายการรอนัดรับ
      </Link>

      <div className="flex items-start justify-between gap-3">
        <h1 className="text-h1 text-text-primary">Lot {row.lot_code}</h1>
        <ReturnStateBadge state={row.state} />
      </div>

      {saved ? (
        <p
          role="status"
          className="rounded-lg border border-success bg-success-subtle p-3 text-body-sm text-success"
        >
          บันทึกวันรับแล้ว — ขั้นต่อไปคือสร้างรอบรถขากลับที่{" "}
          <Link href="/owner/transport" className="font-medium underline">
            ขนส่ง
          </Link>
        </p>
      ) : null}
      {err ? (
        <p
          role="alert"
          className="rounded-lg border border-danger bg-danger-subtle p-3 text-body-sm text-danger"
        >
          {err}
        </p>
      ) : null}

      <dl className="flex flex-col divide-y divide-border rounded-lg border border-border bg-surface">
        <Summary label="ปิด Lot เมื่อ">
          {row.closed_at ? thaiDateTime(row.closed_at) : "—"}
        </Summary>
        <Summary label="ปิดมาแล้ว">
          {row.days_since_close === null ? "—" : `${row.days_since_close} วัน`}
        </Summary>
        <Summary label="น้ำหนักแพ็ครวม">{kg(row.packed_weight_kg)} กก.</Summary>
        <Summary label="กลุ่มวันรมควัน">{row.group_count} กลุ่ม</Summary>
        <Summary label="วันนัดรับ">
          {row.return_pickup_date
            ? thaiDate(row.return_pickup_date)
            : "ยังไม่ได้นัด"}
        </Summary>
      </dl>

      {onTruck ? (
        /* On the truck: the date is history, because the run was created against it (R29).
         * No form, so nothing is offered that the function would refuse. */
        <p className="rounded-lg border border-border bg-surface-sunken p-4 text-body text-text-secondary">
          Lot นี้ขึ้นรถขากลับแล้ว เปลี่ยนวันรับไม่ได้ — รับเข้าคลังได้ที่{" "}
          <Link href="/owner/central" className="text-accent underline">
            สต็อกกลาง
          </Link>
        </p>
      ) : (
        <form action={submitReturnPickupDate} className="flex flex-col gap-4">
          <input type="hidden" name="idempotency_key" value={idempotencyKey} />
          <input type="hidden" name="lot_id" value={row.lot_id} />

          <Field
            label="วันที่รถมารับของที่เชียงใหม่"
            hint="ช่องเดียวของหน้านี้ ไม่ต้องกรอกต้นทุน ระบบคิดจาก Config เอง"
          >
            <input
              type="date"
              name="return_pickup_date"
              required
              min={closedOn}
              defaultValue={row.return_pickup_date ?? today}
              className={cn(control, "h-12")}
            />
          </Field>

          {scheduled ? (
            <p className="text-caption text-text-muted">
              นัดวันรับไว้แล้ว — สร้างรอบรถขากลับได้ที่{" "}
              <Link href="/owner/transport" className="text-accent underline">
                ขนส่ง
              </Link>{" "}
              หรือเปลี่ยนวันได้จนกว่ารถจะออก
            </p>
          ) : null}

          <ActionBar>
            <button type="submit" className={primaryAction}>
              {scheduled ? "เปลี่ยนวันรับ" : "บันทึกวันรับ"}
            </button>
          </ActionBar>
        </form>
      )}
    </div>
  );
}
