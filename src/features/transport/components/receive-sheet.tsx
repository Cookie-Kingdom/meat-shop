import { control, Field } from "@/components/ui/controls";
import { SubmitBar } from "@/components/shared/submit-bar";
import { Sheet } from "@/features/config/components/sheet";
import { thaiDate } from "@/lib/format/date";
import { submitReceipt } from "../actions";
import { ROUTE_LABEL } from "../labels";
import type { OutstandingRow, Place } from "../types";
import { ReceiptWeight } from "./receipt-weight";

/* `?receive=<line>` — the Owner signs for a line arriving at CENTRAL (OW 02, card ^ref-24,
 * clause 2).
 *
 * CENTRAL ONLY, BECAUSE THAT IS WHAT THE DATABASE LETS THE OWNER SIGN FOR (Finding 1).
 * fn_confirm_transport_receipt resolves the signer from the destination: a CHEF_HOUSE line
 * is the CM operator's (CM 02) and a BRANCH line is the branch admin's (BR 02). An L1 on
 * either is refused — TC-42a. The guard below is the mirror of that. It is not the rule.
 *
 * No bag count: no CM_TO_FOODIVA line carries one (the function's header, TC-44), and a
 * count posted against a line with none would demand a reason for nothing.
 */

export function ReceiveSheet({
  line,
  place,
  thresholdPct,
  requiresReason,
  idempotencyKey,
  today,
  echo,
  closeHref,
}: {
  line: OutstandingRow | null;
  place: Place | undefined;
  thresholdPct: string | null;
  requiresReason: boolean | null;
  idempotencyKey: string;
  today: string;
  echo: Record<string, string>;
  closeHref: string;
}) {
  if (!line) {
    return (
      <Sheet title="ไม่พบรายการนี้" closeHref={closeHref} closeLabel="ปิด">
        <p className="text-body text-text-secondary">
          รายการนี้ไม่ได้ค้างรับแล้ว หรือบัญชีนี้ไม่มีสิทธิ์เห็น
        </p>
      </Sheet>
    );
  }

  const title = `รับของ · ${line.lot_code}`;
  const subtitle = `${ROUTE_LABEL[line.route]} · ส่ง ${thaiDate(line.dispatch_date)} · ถึง ${place?.name ?? "—"}`;

  if (place?.kind !== "CENTRAL" || line.received_weight_kg !== null) {
    return (
      <Sheet
        title={title}
        subtitle={subtitle}
        closeHref={closeHref}
        closeLabel="ปิด"
      >
        <p className="text-body text-text-secondary">
          {line.received_weight_kg !== null
            ? "รายการนี้ยืนยันรับไปแล้ว ส่วนที่ขาดค้างอยู่บนรถจนกว่าจะปิดส่วนต่าง"
            : "รายการนี้ผู้ดูแลปลายทางเป็นผู้ยืนยันรับ — เชฟเฮาส์เชียงใหม่ หรือแอดมินสาขา"}
        </p>
      </Sheet>
    );
  }

  return (
    <Sheet title={title} subtitle={subtitle} closeHref={closeHref}>
      <form action={submitReceipt} className="flex flex-col gap-4">
        <input type="hidden" name="idempotency_key" value={idempotencyKey} />
        <input type="hidden" name="line_id" value={line.line_id} />

        <Field
          label="วันที่รับเข้าคลังกลาง"
          hint="เกณฑ์ส่วนต่างและการบังคับเหตุผลใช้ค่า ณ วันที่นี้"
        >
          <input
            type="date"
            name="event_date"
            required
            defaultValue={echo.event_date || today}
            className={control}
          />
        </Field>

        <ReceiptWeight
          dispatched={Number(line.dispatched_weight_kg).toFixed(2)}
          thresholdPct={thresholdPct}
          requiresReason={requiresReason}
          defaults={{
            received: echo.received_weight_kg ?? "",
            reason: echo.variance_reason ?? "",
            settlement: echo.variance_settlement ?? "",
          }}
        />

        <SubmitBar
          label="ยืนยันรับของ"
          note="ถ้ารับไม่ครบ ส่วนที่ขาดค้างอยู่บนรถ ไม่ถูกตัดทิ้ง"
        />
      </form>
    </Sheet>
  );
}
