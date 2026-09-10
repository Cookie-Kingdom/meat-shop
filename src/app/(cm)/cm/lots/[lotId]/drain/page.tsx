import Link from "next/link";

import { AlertBanner } from "@/features/production/components/alert-banner";
import {
  LotHeader,
  LotUnavailable,
} from "@/features/production/components/lot-header";
import { LockIndicator } from "@/features/production/components/lock-indicator";
import { PostDrainForm } from "@/features/production/components/post-drain-form";
import { SummaryRow } from "@/features/production/components/summary-row";
import { dbKg, formatKg } from "@/features/production/kg";
import { isUuid, readLot } from "@/features/production/queries";
import { isClosed } from "@/features/production/types";
import { newIdempotencyKey } from "@/lib/rpc/production";

/* CM 03 — น้ำหนักก่อนสโมค (S1). The second visit to CM 02's row: the pre-smoke weight, capped
 * at the received weight (v0.2 line 80). Needs the receipt first — there is no row to complete
 * without it. */

export default async function DrainPage(
  props: PageProps<"/cm/lots/[lotId]/drain">,
) {
  const { lotId } = await props.params;
  if (!isUuid(lotId)) return <LotUnavailable />;

  const { data, error } = await readLot(lotId);
  if (error || !data.lot) {
    return (
      <LotUnavailable error={error} retryHref={`/cm/lots/${lotId}/drain`} />
    );
  }
  const { lot } = data;
  const header = (
    <LotHeader
      lot={lot}
      title="น้ำหนักก่อนสโมค"
      backHref={`/cm/lots/${lotId}`}
    />
  );
  const receivedH = dbKg(lot.received_weight_kg);

  if (isClosed(lot.state)) {
    return (
      <div className="flex flex-col gap-4">
        {header}
        <LockIndicator closedAt={lot.closed_at} closedBy={lot.closed_by_name} />
        <dl className="rounded-lg border border-border bg-surface px-4">
          <SummaryRow
            label="น้ำหนักก่อนสโมค"
            value={
              lot.post_drain_weight_kg === null
                ? null
                : formatKg(lot.post_drain_weight_kg)
            }
            unit="กก."
            missing="ไม่ได้บันทึก"
          />
        </dl>
      </div>
    );
  }

  if (receivedH === null) {
    return (
      <div className="flex flex-col gap-4">
        {header}
        <AlertBanner tone="warning" title="ยังไม่มีบันทึกรับเนื้อ">
          น้ำหนักก่อนสโมคต้องไม่เกินน้ำหนักรับ จึงต้องบันทึกรับเนื้อก่อน —{" "}
          <Link
            href={`/cm/lots/${lotId}/receive`}
            className="text-accent underline"
          >
            ไปหน้ารับเนื้อ
          </Link>
        </AlertBanner>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4">
      {header}
      <PostDrainForm
        lotId={lotId}
        idempotencyKey={newIdempotencyKey()}
        receivedH={receivedH}
        initialDrain={
          lot.post_drain_weight_kg === null
            ? ""
            : formatKg(lot.post_drain_weight_kg)
        }
      />
    </div>
  );
}
