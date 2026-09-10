"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition, type FormEvent } from "react";
import { cva } from "class-variance-authority";
import { LoaderCircle, TriangleAlert } from "lucide-react";

import { control } from "@/components/ui/controls";
import { cn } from "@/lib/utils";
import { saveReceipt } from "@/features/production/actions";
import { formatHundredths, parseKg } from "@/features/production/kg";

import { AlertBanner } from "./alert-banner";
import { BottomActionBar, writeButton } from "./bottom-action-bar";
import { WeightField } from "./weight-field";

/* CM 02 — รับเนื้อเชียงใหม่ (S1). The received weight against Foodiva's dispatch, with a
 * reason when they do not match (v0.2 line 79, BR12).
 *
 * THE VERDICT IS THE DATABASE'S. Whether a reason is REQUIRED depends on
 * receipt_variance_threshold_pct and receipt_variance_requires_reason, Owner config an L3
 * session cannot read (R20) — and a literal 20 here would be ADR-006's defect. So this screen
 * shows the pair and the kg difference, offers the ReasonField whenever the two differ, and
 * makes it required when fn_record_lot_receipt answers VARIANCE_REASON_REQUIRED. No
 * percentage is rendered: the percentage and its verdict belong to one function (ADR-019).
 *
 * ReasonField's worst case (DESIGN-CONTRACTS): correcting the weight to match hides the field
 * and DISCARDS its text, so a now-irrelevant reason is never submitted. It sits above the
 * weight it depends on, so appearing never pushes the submit under the keyboard. */

const TIME = new Intl.DateTimeFormat("th-TH", {
  timeZone: "Asia/Bangkok",
  timeStyle: "short",
});

/** VarianceDisplay's three tones here. There is no "within threshold" tone: the threshold is
 * the Owner's and this screen cannot read it, so a mismatch is a warning until the database
 * says a reason is required. */
const variance = cva(
  "flex flex-col gap-1 rounded-lg border border-l-4 p-3 text-body-sm",
  {
    variants: {
      tone: {
        match: "border-border bg-surface",
        mismatch: "border-warning bg-warning-subtle",
        required: "border-danger bg-danger-subtle",
      },
    },
    defaultVariants: { tone: "match" },
  },
);

export function ReceiptForm({
  lotId,
  idempotencyKey,
  today,
  foodivaH,
  postDrainH,
  initialReceived,
  initialReason,
  initialDate,
}: {
  lotId: string;
  idempotencyKey: string;
  today: string;
  /** Foodiva's dispatch weight in hundredths; null only for a lot with no round. */
  foodivaH: number | null;
  /** CM 03's weight when already stored — the received weight may not drop below it. */
  postDrainH: number | null;
  initialReceived: string;
  initialReason: string;
  initialDate: string;
}) {
  const router = useRouter();
  const [key] = useState(idempotencyKey);
  const [received, setReceived] = useState(initialReceived);
  const [reason, setReason] = useState(initialReason);
  const [date, setDate] = useState(initialDate);
  const [forced, setForced] = useState(false);
  const [failure, setFailure] = useState<{
    message: string;
    at: string;
  } | null>(null);
  const [pending, startTransition] = useTransition();

  const receivedH = received === "" ? null : parseKg(received);
  const diffH =
    receivedH !== null && foodivaH !== null ? receivedH - foodivaH : null;
  const mismatch = diffH !== null && diffH !== 0;
  const reasonRequired = forced && mismatch;
  const tone = reasonRequired ? "required" : mismatch ? "mismatch" : "match";

  function changeReceived(next: string) {
    setReceived(next);
    const h = next === "" ? null : parseKg(next);
    if (h !== null && foodivaH !== null && h === foodivaH) {
      setReason("");
      setForced(false);
    }
  }

  function submit(e: FormEvent) {
    e.preventDefault();
    const at = TIME.format(new Date());
    if (receivedH === null) {
      setFailure({
        message: "กรอกน้ำหนักรับเป็นตัวเลข ทศนิยมไม่เกิน 2 ตำแหน่ง",
        at,
      });
      return;
    }
    if (reasonRequired && reason.trim() === "") {
      setFailure({ message: "ใส่เหตุผลที่น้ำหนักไม่ตรงก่อนบันทึก", at });
      return;
    }
    startTransition(async () => {
      try {
        const result = await saveReceipt({
          lotId,
          idempotencyKey: key,
          eventDate: date,
          receivedKg: received,
          reason: mismatch ? reason : "",
        });
        if (result.ok) {
          router.push(`/cm/lots/${lotId}?saved=receive`);
          return;
        }
        if (result.code === "VARIANCE_REASON_REQUIRED") setForced(true);
        setFailure({ message: result.message, at });
      } catch {
        setFailure({ message: "เชื่อมต่อเซิร์ฟเวอร์ไม่ได้", at });
      }
    });
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      {failure ? (
        <AlertBanner tone="danger" title={`บันทึกไม่สำเร็จ เวลา ${failure.at}`}>
          {failure.message} — ค่าที่กรอกยังอยู่ในเครื่อง
          แก้แล้วกดบันทึกอีกครั้งได้เลย
        </AlertBanner>
      ) : null}

      <label className="flex flex-col gap-1">
        <span className="text-label text-text-secondary">วันที่รับเนื้อ</span>
        <input
          type="date"
          value={date}
          max={today}
          onChange={(e) => setDate(e.target.value)}
          className={cn(control, "font-mono")}
        />
      </label>

      {mismatch ? (
        <label className="flex flex-col gap-1">
          <span className="text-label text-text-secondary">
            เหตุผลที่น้ำหนักไม่ตรง{reasonRequired ? " (ต้องกรอก)" : " (ถ้ามี)"}
          </span>
          <textarea
            rows={3}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            aria-invalid={
              reasonRequired && reason.trim() === "" ? true : undefined
            }
            className={cn(
              "min-h-24 w-full rounded-md border bg-surface px-3 py-2 text-body text-text-primary focus-visible:outline-2 focus-visible:outline-focus-ring",
              reasonRequired ? "border-danger" : "border-border",
            )}
          />
          <span className="text-caption text-text-secondary">
            {reasonRequired
              ? "ต่างเกินเกณฑ์ที่ Owner ตั้งไว้ ระบบจึงต้องมีเหตุผล"
              : "น้ำหนักไม่ตรงกับที่ Foodiva ส่ง ถ้าต่างมากระบบจะให้ใส่เหตุผลตอนบันทึก"}
          </span>
        </label>
      ) : null}

      <WeightField
        id="received-weight"
        label="น้ำหนักรับจริง"
        value={received}
        onChange={changeReceived}
        helper={
          postDrainH !== null
            ? `บันทึกน้ำหนักก่อนสโมคไว้ ${formatHundredths(postDrainH)} กก. — น้ำหนักรับต้องไม่ต่ำกว่านี้`
            : "ชั่งแล้วกรอกเป็นกิโลกรัม ทศนิยม 2 ตำแหน่ง"
        }
        autoFocus={initialReceived === ""}
      />

      {/* VarianceDisplay, three lines at 360px: the pair, the difference, and whose rule it is. */}
      {foodivaH !== null ? (
        <div className={variance({ tone })}>
          <p className="text-text-secondary">
            เทียบน้ำหนักส่งออกจาก Foodiva{" "}
            <span className="font-mono text-text-primary tabular-nums">
              {formatHundredths(foodivaH)}
            </span>{" "}
            กก.
          </p>
          <p className="flex items-center gap-1 text-text-primary">
            {mismatch ? (
              <TriangleAlert aria-hidden className="size-4 text-warning" />
            ) : null}
            {diffH === null ? (
              "ยังไม่ได้กรอกน้ำหนักรับ"
            ) : diffH === 0 ? (
              "ตรงกับที่ Foodiva ส่ง"
            ) : (
              <>
                ต่าง{" "}
                <span className="font-mono tabular-nums">
                  {diffH > 0 ? "+" : ""}
                  {formatHundredths(diffH)}
                </span>{" "}
                กก.
              </>
            )}
          </p>
          <p className="text-caption text-text-secondary">
            เกณฑ์ที่ต้องมีเหตุผลเป็นค่าที่ Owner ตั้ง ระบบตรวจตอนกดบันทึก
          </p>
        </div>
      ) : null}

      <BottomActionBar>
        <button type="submit" disabled={pending} className={writeButton}>
          {pending ? (
            <LoaderCircle
              aria-hidden
              className="size-5 animate-spin motion-reduce:animate-none"
            />
          ) : null}
          {pending
            ? "กำลังบันทึก…"
            : failure
              ? "ส่งอีกครั้ง"
              : "บันทึกน้ำหนักรับ"}
        </button>
      </BottomActionBar>
    </form>
  );
}
