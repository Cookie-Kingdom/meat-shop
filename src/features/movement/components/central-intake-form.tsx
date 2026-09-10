"use client";

import Link from "next/link";
import { useActionState, useState } from "react";

import { control, Field } from "@/components/ui/controls";
import { thaiDate } from "@/lib/format/date";
import { kg, parseKg, toHundredths } from "@/lib/format/weight";
import { submitCentralIntake } from "../actions";
import type { ActionState, DatedValue, OutstandingReceiptRow } from "../types";
import { ActionBar, primaryAction } from "./action-bar";
import { ReasonField } from "./reason-field";
import { VarianceDisplay, varianceVerdict } from "./variance-display";
import { WeightField } from "./weight-field";

/* CentralStockIntakeForm (DESIGN-CONTRACTS.md) — OW 06, skeleton S1. It signs for one return
 * leg into central stock, through fn_confirm_central_intake (BR12, R27).
 *
 * WARN, NEVER BLOCK. Past the threshold a reason becomes required and SUBMIT STAYS ENABLED
 * (BR12, UAT-07). Treating "requires a reason" as "is blocked" is the specific defect the
 * contract names. The button is disabled only while a submit is in flight.
 *
 * THE REASON FIELD APPEARS ABOVE THE WEIGHT (S1 worst case), so it never pushes submit under
 * the keyboard. It is discarded, not hidden, when the weight comes back inside the band.
 *
 * THE THRESHOLD IS CONFIG, RESOLVED BY THE RECEIPT'S DATE (ADR-006, R12). The page passes
 * every dated row, and the form picks the one in force on the date the user enters. The one
 * fn_confirm_transport_receipt will use is resolved the same way. With no row, a notice shows
 * in place of a verdict. The form never falls back to 20. */

const idle: ActionState = { status: "idle" };

function resolveAt<T>(rows: DatedValue<T>[], date: string): T | null {
  let best: DatedValue<T> | null = null;
  for (const r of rows) {
    if (r.effective_from <= date && (!best || r.effective_from > best.effective_from)) {
      best = r;
    }
  }
  return best ? best.value : null;
}

export function CentralIntakeForm({
  line,
  idempotencyKey,
  today,
  thresholds,
  requiresReason,
}: {
  line: OutstandingReceiptRow;
  idempotencyKey: string;
  today: string;
  thresholds: DatedValue<number>[];
  requiresReason: DatedValue<boolean>[];
}) {
  const [state, formAction, pending] = useActionState(submitCentralIntake, idle);
  const [eventDate, setEventDate] = useState(today);
  const [weight, setWeight] = useState("");
  const [reason, setReason] = useState("");

  const expectedH = toHundredths(line.dispatched_weight_kg);

  /** Everything the mirror derives for one (weight, date) pair. It runs on each keystroke, and
   * the handlers use it to drop the reason as soon as it stops applying. */
  const derive = (w: string, date: string) => {
    const threshold = resolveAt(thresholds, date);
    const actual = parseKg(w);
    const verdict =
      actual === null
        ? null
        : varianceVerdict(
            expectedH,
            toHundredths(actual),
            threshold === null ? null : toHundredths(threshold),
          );
    // Over, or no threshold to say it is not: the reason is offered.
    const showReason = verdict !== null && verdict.over !== false;
    return { threshold, actual, verdict, showReason };
  };

  const { threshold, actual, verdict, showReason } = derive(weight, eventDate);
  // An unset toggle reads as required here; the function raises CONFIG_NOT_SET for it.
  const reasonRequired =
    verdict?.over === true && resolveAt(requiresReason, eventDate) !== false;

  const onWeight = (w: string) => {
    setWeight(w);
    if (!derive(w, eventDate).showReason) setReason("");
  };
  const onDate = (d: string) => {
    setEventDate(d);
    if (!derive(weight, d).showReason) setReason("");
  };

  return (
    <form action={formAction} className="flex flex-col gap-4">
      <input type="hidden" name="idempotency_key" value={idempotencyKey} />
      <input type="hidden" name="line_id" value={line.line_id} />

      <dl className="grid grid-cols-2 gap-3 rounded-lg border border-border bg-surface p-4 text-body-sm">
        <div>
          <dt className="text-text-secondary">ส่งออกจากเชียงใหม่</dt>
          <dd className="text-text-primary">{thaiDate(line.dispatch_date)}</dd>
        </div>
        <div className="text-right">
          <dt className="text-text-secondary">น้ำหนักส่งออก</dt>
          <dd className="text-num-md text-text-primary tabular-nums">
            {kg(line.dispatched_weight_kg)} กก.
          </dd>
        </div>
      </dl>

      <Field label="วันที่รับของเข้าคลัง">
        <input
          type="date"
          name="event_date"
          required
          value={eventDate}
          onChange={(e) => onDate(e.target.value)}
          className={control}
        />
      </Field>

      {threshold === null ? (
        <p className="rounded-lg border border-border bg-surface-sunken p-3 text-body-sm text-text-secondary">
          ยังไม่ได้ตั้งเกณฑ์ส่วนต่างตอนรับของสำหรับวันที่นี้ — ระบบจะรับบันทึกเมื่อเจ้าของตั้งค่าที่{" "}
          <Link href="/owner/config" className="text-accent underline">
            OW 10 · ตั้งค่าระบบ
          </Link>
        </p>
      ) : null}

      {showReason ? (
        <ReasonField
          id="variance-reason"
          name="variance_reason"
          label="เหตุผลที่น้ำหนักไม่ตรง"
          trigger={
            verdict?.over === true
              ? "น้ำหนักรับจริงต่างจากที่ส่งออกเกินเกณฑ์ — บอกเหตุผลไว้ แล้วบันทึกต่อได้ (BR12)"
              : "ยังไม่มีเกณฑ์ให้เทียบ — ใส่เหตุผลไว้ได้ถ้าน้ำหนักไม่ตรง"
          }
          value={reason}
          onChange={setReason}
          required={reasonRequired}
        />
      ) : null}

      <WeightField
        id="received-weight"
        name="received_weight_kg"
        label="น้ำหนักรับจริง"
        value={weight}
        onChange={onWeight}
        invalid={weight !== "" && actual === null}
        helper={
          weight !== "" && actual === null
            ? "ตัวเลข ทศนิยมไม่เกิน 2 ตำแหน่ง"
            : "ชั่งเท่าไรกรอกเท่านั้น 0.00 ก็บันทึกได้ถ้าไม่มีของมาถึง"
        }
      />

      {verdict !== null && actual !== null ? (
        <VarianceDisplay
          expectedKg={line.dispatched_weight_kg}
          actualKg={actual}
          verdict={verdict}
          thresholdPct={threshold}
          comparison="ส่งออกจากเชียงใหม่"
          onOverThreshold="warn"
        />
      ) : null}

      {state.status === "error" ? (
        <p
          role="alert"
          className="rounded-lg border border-danger bg-danger-subtle p-3 text-body-sm text-danger"
        >
          {state.message}
        </p>
      ) : null}

      <ActionBar>
        <button type="submit" disabled={pending} className={primaryAction}>
          {pending ? "กำลังบันทึก…" : "ยืนยันรับเข้าคลังกลาง"}
        </button>
      </ActionBar>
    </form>
  );
}
