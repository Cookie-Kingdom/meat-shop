import { AlertBanner } from "@/features/production/components/alert-banner";
import {
  LotHeader,
  LotUnavailable,
} from "@/features/production/components/lot-header";
import { LockIndicator } from "@/features/production/components/lock-indicator";
import { ReceiptForm } from "@/features/production/components/receipt-form";
import { SummaryRow } from "@/features/production/components/summary-row";
import { dbKg, formatKg } from "@/features/production/kg";
import { isUuid, readLot } from "@/features/production/queries";
import { isClosed } from "@/features/production/types";
import { todayBangkok } from "@/lib/format/date";
import { newIdempotencyKey } from "@/lib/rpc/production";

/* CM 02 — รับเนื้อเชียงใหม่ (S1). Offered in every open state: lane H widens
 * fn_record_lot_receipt's floor to IN_TRANSIT and leaves the ceiling to fn_guard_lot_closed,
 * so a received weight can be corrected until the lot closes. PO_CREATED is meat still on
 * Foodiva's floor, and a closed lot is LOCKED. The database refuses both anyway
 * (LOT_STATE_INVALID, LOT_CLOSED); this only picks the screen. */

export default async function ReceivePage(
  props: PageProps<"/cm/lots/[lotId]/receive">,
) {
  const { lotId } = await props.params;
  if (!isUuid(lotId)) return <LotUnavailable />;

  const { data, error } = await readLot(lotId);
  if (error || !data.lot) {
    return (
      <LotUnavailable error={error} retryHref={`/cm/lots/${lotId}/receive`} />
    );
  }
  const { lot } = data;
  const header = (
    <LotHeader
      lot={lot}
      title="รับเนื้อเชียงใหม่"
      backHref={`/cm/lots/${lotId}`}
    />
  );

  if (isClosed(lot.state)) {
    return (
      <div className="flex flex-col gap-4">
        {header}
        <LockIndicator closedAt={lot.closed_at} closedBy={lot.closed_by_name} />
        <dl className="rounded-lg border border-border bg-surface px-4">
          <SummaryRow
            label="น้ำหนักรับจริง"
            value={formatKg(lot.received_weight_kg)}
            unit="กก."
          />
          <SummaryRow
            label="เหตุผลที่ไม่ตรง"
            value={lot.variance_reason}
            missing="ไม่มี"
          />
        </dl>
      </div>
    );
  }

  if (lot.state === "PO_CREATED") {
    return (
      <div className="flex flex-col gap-4">
        {header}
        <AlertBanner tone="info" title="Lot นี้ยังไม่ออกจาก Foodiva">
          บันทึกรับเนื้อได้เมื่อรถออกแล้ว — Owner เป็นผู้บันทึกรถขาไป
        </AlertBanner>
      </div>
    );
  }

  const today = todayBangkok();
  return (
    <div className="flex flex-col gap-4">
      {header}
      <ReceiptForm
        lotId={lotId}
        idempotencyKey={newIdempotencyKey()}
        today={today}
        foodivaH={dbKg(lot.foodiva_sent_weight_kg)}
        postDrainH={dbKg(lot.post_drain_weight_kg)}
        initialReceived={
          lot.received_weight_kg === null
            ? ""
            : formatKg(lot.received_weight_kg)
        }
        initialReason={lot.variance_reason ?? ""}
        initialDate={lot.receipt_date ?? today}
      />
    </div>
  );
}
