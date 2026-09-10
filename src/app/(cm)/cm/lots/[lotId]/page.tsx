import { AlertBanner } from "@/features/production/components/alert-banner";
import {
  LotHeader,
  LotUnavailable,
} from "@/features/production/components/lot-header";
import { LockIndicator } from "@/features/production/components/lock-indicator";
import { StepLink } from "@/features/production/components/step-link";
import { SummaryRow } from "@/features/production/components/summary-row";
import { formatKg } from "@/features/production/kg";
import { isUuid, readLot } from "@/features/production/queries";
import { isClosed } from "@/features/production/types";
import { one } from "@/lib/params";

/* The lot's full screen (S3's detail): what is known about it, and the next step. Every
 * "done" below is derived from the records the views return — a receipt row, a post-drain
 * weight, a logged day — never from a tick the operator set (ChecklistItem's rule). A step
 * that cannot be opened yet says why instead of rendering as a dead link.
 *
 * The figures are the ones v0.2 already puts in front of the operator one screen at a time:
 * the declared weight (CM 01), received and pre-smoke (CM 02, CM 03), the computed remainder
 * and what has been packed (CM 04). No ratio of any two of them is computed here (BR15). */

const SAVED: Record<string, string> = {
  receive: "บันทึกน้ำหนักรับแล้ว",
  drain: "บันทึกน้ำหนักก่อนสโมคแล้ว",
};

export default async function LotHub(props: PageProps<"/cm/lots/[lotId]">) {
  const { lotId } = await props.params;
  const saved = SAVED[one((await props.searchParams).saved)];
  if (!isUuid(lotId)) return <LotUnavailable />;

  const { data, error } = await readLot(lotId);
  if (error || !data.lot) {
    return <LotUnavailable error={error} retryHref={`/cm/lots/${lotId}`} />;
  }
  const { lot, pending, progress } = data;
  const base = `/cm/lots/${lotId}`;
  const closed = isClosed(lot.state);
  const onTruck = lot.state === "PO_CREATED";
  const received = lot.received_weight_kg !== null;
  const drained = lot.post_drain_weight_kg !== null;
  const days = progress?.days_logged ?? 0;

  return (
    <div className="flex flex-col gap-4">
      <LotHeader
        lot={lot}
        title="รายละเอียด Lot"
        backHref="/cm"
        backLabel="งานของฉัน"
      />

      {saved ? <AlertBanner tone="success" title={saved} /> : null}
      {closed ? (
        <LockIndicator closedAt={lot.closed_at} closedBy={lot.closed_by_name} />
      ) : null}

      <dl className="rounded-lg border border-border bg-surface px-4">
        <SummaryRow
          label="น้ำหนักที่ Owner แจ้ง (Foodiva ส่ง)"
          value={
            lot.foodiva_sent_weight_kg === null
              ? null
              : formatKg(lot.foodiva_sent_weight_kg)
          }
          unit="กก."
        />
        <SummaryRow
          label="รับจริงที่เชียงใหม่"
          value={received ? formatKg(lot.received_weight_kg) : null}
          unit="กก."
          missing="ยังไม่บันทึก"
        />
        <SummaryRow
          label="ก่อนสโมค"
          value={drained ? formatKg(lot.post_drain_weight_kg) : null}
          unit="กก."
          missing="ยังไม่บันทึก"
        />
        <SummaryRow
          label="น้ำหนักรอทำ"
          value={
            pending?.pending_weight_kg == null
              ? null
              : formatKg(pending.pending_weight_kg)
          }
          unit="กก."
          missing={drained ? undefined : "รอน้ำหนักก่อนสโมค"}
        />
        <SummaryRow
          label={`แพ็คแล้ว ${progress?.bag_count ?? 0} ถุง`}
          value={formatKg(progress?.packed_weight_kg ?? 0)}
          unit="กก."
        />
      </dl>

      <nav aria-label="ขั้นตอนของ Lot นี้" className="flex flex-col gap-2">
        {closed ? (
          <StepLink href={`${base}/close`} label="ดูสรุป Lot ที่ปิดแล้ว" done />
        ) : (
          <>
            <StepLink
              href={`${base}/receive`}
              label="1 · รับเนื้อ"
              detail={
                received
                  ? "แก้น้ำหนักรับได้จนกว่าจะปิด Lot"
                  : "กรอกน้ำหนักรับจริงเมื่อรถมาถึง"
              }
              done={received}
              blocked={onTruck ? "รอรถออกจาก Foodiva" : null}
            />
            <StepLink
              href={`${base}/drain`}
              label="2 · น้ำหนักก่อนสโมค"
              detail="หลังแกะและซับเลือด"
              done={drained}
              blocked={received ? null : "บันทึกรับเนื้อก่อน"}
            />
            <StepLink
              href={`${base}/smoke-log`}
              label="3 · บันทึกรมควันวันนี้"
              detail={days > 0 ? `บันทึกแล้ว ${days} วัน` : "ยังไม่มีบันทึก"}
              done={days > 0}
              blocked={received ? null : "บันทึกรับเนื้อก่อน"}
            />
            <StepLink
              href={`${base}/close`}
              label="4 · ปิด Lot"
              detail="ตรวจสรุปแล้วยืนยันเมื่อผลิตครบ"
              blocked={
                !received
                  ? "ต้องมีบันทึกรับเนื้อก่อน"
                  : days === 0
                    ? "ต้องมีบันทึกรมควันอย่างน้อยหนึ่งวัน"
                    : null
              }
            />
          </>
        )}
      </nav>
    </div>
  );
}
