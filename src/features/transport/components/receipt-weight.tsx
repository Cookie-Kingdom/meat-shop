"use client";

import { useState } from "react";

import { control, Field } from "@/components/ui/controls";
import { WeightField } from "@/components/shared/decimal-field";
import {
  fromHundredths,
  toHundredths,
  variancePctHundredths,
} from "@/lib/format/number";
import { cn } from "@/lib/utils";

/* The receive sheet's live half: `WeightField` + `VarianceDisplay` + `ReasonField`
 * (DESIGN-CONTRACTS.md). OW 02, card ^ref-24, clause 2.
 *
 * THIS IS THE MIRROR, NOT THE RULE (ADR-004). "A variance past threshold cannot be dismissed
 * without a reason" is fn_confirm_transport_receipt raising VARIANCE_REASON_REQUIRED, and
 * transport_screen_test.sql TC-42b calls the RPC directly to prove it. This island exists so
 * the Owner sees the rule before submit rather than after.
 *
 * SAME FORMULA, SAME BOUNDARY AS THE DATABASE. |actual − expected| / expected × 100, rounded
 * to 2 in exact hundredths (ADR-019), and WITHIN when `<=` the threshold — fn_check_variance
 * line 73. TC-S15 pins the boundary: 32 against 40 is 20.00% and the database accepts it
 * without a reason, so the screen must too. The threshold comes from config at today. The
 * database resolves it at the receipt's own date, and that is the one that decides.
 *
 * WARN, NOT BLOCK. Central intake over 20% warns, requires a reason, and leaves submit
 * enabled (VarianceDisplay table, BR12/UAT-07). A receipt is a fact that already happened.
 *
 * THE REASON APPEARS ABOVE THE WEIGHT THAT TRIGGERED IT (ReasonField contract, S1 worst case),
 * so it never pushes the submit bar under the keyboard. If the weight is corrected back to a
 * match, the field disappears and its text is DISCARDED — never posted as a stale reason
 * attached to a receipt that no longer needs one.
 */

type Props = {
  /** Dispatched weight, "40.00". */
  dispatched: string;
  /** receipt_variance_threshold_pct at today, "20.00", or null when unset. */
  thresholdPct: string | null;
  /** receipt_variance_requires_reason at today; null when unset or unreadable. */
  requiresReason: boolean | null;
  defaults: { received: string; reason: string; settlement: string };
};

const ZERO = BigInt(0);

export function ReceiptWeight({
  dispatched,
  thresholdPct,
  requiresReason,
  defaults,
}: Props) {
  const [received, setReceived] = useState(defaults.received);
  const [reason, setReason] = useState(defaults.reason);
  const [settlement, setSettlement] = useState(defaults.settlement);

  const expected = toHundredths(dispatched) ?? ZERO;
  const threshold = thresholdPct === null ? null : toHundredths(thresholdPct);

  const measure = (raw: string) => {
    const actual = toHundredths(raw);
    const pct =
      actual === null ? null : variancePctHundredths(actual, expected);
    return { actual, pct, off: pct !== null && pct > ZERO };
  };

  const { actual, pct, off } = measure(received);
  const over = off && threshold !== null && pct! > threshold;
  // Unset or unreadable toggle: shown as required. If the threshold is unset too, the
  // database refuses with CONFIG_NOT_SET either way, and "optional" would be the wrong hint.
  const required = over && requiresReason !== false;

  function onReceived(value: string) {
    setReceived(value);
    if (!measure(value).off) {
      setReason("");
      setSettlement("");
    }
  }

  const diff = actual === null ? null : actual - expected;
  const verdict =
    pct === null
      ? "กรอกน้ำหนักที่รับเพื่อเทียบกับน้ำหนักที่ส่ง"
      : !off
        ? "ตรงกับน้ำหนักที่ส่ง"
        : threshold === null
          ? "ยังไม่ได้ตั้งเกณฑ์ส่วนต่างในการตั้งค่า — ระบบจะไม่รับบันทึกจนกว่าจะตั้ง"
          : over
            ? requiresReason === false
              ? `เกินเกณฑ์ ${fromHundredths(threshold)}% — การตั้งค่าไม่บังคับเหตุผล บันทึกได้ ระบบแจ้งเตือน`
              : `เกินเกณฑ์ ${fromHundredths(threshold)}% — บันทึกได้ แต่ต้องกรอกเหตุผล ระบบแจ้งเตือน`
            : `ไม่เกินเกณฑ์ ${fromHundredths(threshold)}%`;

  return (
    <>
      {off ? (
        <div className="flex flex-col gap-3">
          <label className="flex flex-col gap-1">
            <span className="text-label text-text-secondary">
              เหตุผลที่น้ำหนักไม่ตรง{required ? " (ต้องกรอก)" : " (ไม่บังคับ)"}
            </span>
            <span
              className={cn(
                "text-caption",
                over ? "text-danger" : "text-text-muted",
              )}
            >
              {verdict}
            </span>
            <textarea
              name="variance_reason"
              rows={3}
              required={required}
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              className={cn(control, "h-auto py-2")}
            />
          </label>
          <Field
            label="วิธีปิดส่วนต่าง (ถ้ามี)"
            hint="เช่น หักจากผู้ขนส่ง — ระบบเก็บตามที่กรอก"
          >
            <input
              type="text"
              name="variance_settlement"
              value={settlement}
              onChange={(e) => setSettlement(e.target.value)}
              className={control}
            />
          </Field>
        </div>
      ) : null}

      <WeightField
        label="น้ำหนักที่รับจริง"
        name="received_weight_kg"
        required
        value={received}
        onChange={(e) => onReceived(e.target.value)}
        error={
          received !== "" && actual === null
            ? "ตัวเลขทศนิยมไม่เกิน 2 ตำแหน่ง"
            : undefined
        }
        hint={`ส่งมา ${fromHundredths(expected)} กก. — ถ้าไม่มีของมาเลย กรอก 0`}
      />

      <div
        aria-live="polite"
        className={cn(
          "flex flex-col gap-0.5 rounded-md border p-3 text-body-sm tabular-nums",
          over
            ? "border-danger bg-danger-subtle"
            : off
              ? "border-warning bg-warning-subtle"
              : "border-border bg-surface-sunken",
        )}
      >
        <span className="text-text-primary">
          ส่ง {fromHundredths(expected)} กก. · รับ{" "}
          {actual === null ? "—" : `${fromHundredths(actual)} กก.`}
        </span>
        <span className="text-text-primary">
          ต่าง{" "}
          {diff === null
            ? "—"
            : `${diff > ZERO ? "+" : ""}${fromHundredths(diff)} กก.`}
        </span>
        <span className={over ? "text-danger" : "text-text-secondary"}>
          {pct === null ? "—" : `${fromHundredths(pct)}%`} · {verdict}
        </span>
      </div>
    </>
  );
}
