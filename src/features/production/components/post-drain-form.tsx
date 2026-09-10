"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition, type FormEvent } from "react";
import { LoaderCircle } from "lucide-react";

import { savePostDrain } from "@/features/production/actions";
import { parseKg } from "@/features/production/kg";

import { AlertBanner } from "./alert-banner";
import { BottomActionBar, writeButton } from "./bottom-action-bar";
import { WeightField } from "./weight-field";

/* CM 03 — น้ำหนักก่อนสโมค (S1). The weight after unpacking and blotting, which may not exceed
 * the received weight (v0.2 line 80). WeightField shows that ceiling before it is reached and
 * marks the breach live; the submit refuses while over and says why in its own label
 * (REVIEW 16). fn_record_lot_receipt refuses it again by name, POST_DRAIN_EXCEEDS_RECEIVED —
 * that is the rule, this is the mirror.
 *
 * No yield is shown or derived here. v0.2 calls this weight the base of Smoke Yield, and that
 * figure is the Owner's (BR15). */

const TIME = new Intl.DateTimeFormat("th-TH", {
  timeZone: "Asia/Bangkok",
  timeStyle: "short",
});

export function PostDrainForm({
  lotId,
  idempotencyKey,
  receivedH,
  initialDrain,
}: {
  lotId: string;
  idempotencyKey: string;
  receivedH: number;
  initialDrain: string;
}) {
  const router = useRouter();
  const [key] = useState(idempotencyKey);
  const [drain, setDrain] = useState(initialDrain);
  const [failure, setFailure] = useState<{
    message: string;
    at: string;
  } | null>(null);
  const [pending, startTransition] = useTransition();

  const drainH = drain === "" ? null : parseKg(drain);
  const overMax = drainH !== null && drainH > receivedH;

  function submit(e: FormEvent) {
    e.preventDefault();
    const at = TIME.format(new Date());
    if (drainH === null) {
      setFailure({
        message: "กรอกน้ำหนักก่อนสโมคเป็นตัวเลข ทศนิยมไม่เกิน 2 ตำแหน่ง",
        at,
      });
      return;
    }
    if (overMax) return;
    startTransition(async () => {
      try {
        const result = await savePostDrain({
          lotId,
          idempotencyKey: key,
          postDrainKg: drain,
        });
        if (result.ok) {
          router.push(`/cm/lots/${lotId}?saved=drain`);
          return;
        }
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

      <WeightField
        id="post-drain-weight"
        label="น้ำหนักก่อนสโมค (หลังแกะและซับเลือด)"
        value={drain}
        onChange={setDrain}
        max={receivedH}
        maxLabel="น้ำหนักที่รับเข้ามา"
        autoFocus={initialDrain === ""}
      />

      <BottomActionBar>
        <button
          type="submit"
          disabled={pending || overMax}
          className={writeButton}
        >
          {pending ? (
            <LoaderCircle
              aria-hidden
              className="size-5 animate-spin motion-reduce:animate-none"
            />
          ) : null}
          {overMax
            ? "เกินน้ำหนักรับ · บันทึกไม่ได้"
            : pending
              ? "กำลังบันทึก…"
              : failure
                ? "ส่งอีกครั้ง"
                : "บันทึกน้ำหนักก่อนสโมค"}
        </button>
      </BottomActionBar>
    </form>
  );
}
