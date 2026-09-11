import Link from "next/link";

import { Sheet } from "@/features/config/components/sheet";
import { closeLotAction } from "@/features/production/actions";
import { AlertBanner } from "@/features/production/components/alert-banner";
import { ReadError } from "@/components/shared/read-error";
import {
  BottomActionBar,
  dangerButton,
} from "@/features/production/components/bottom-action-bar";
import {
  LotHeader,
  LotUnavailable,
} from "@/features/production/components/lot-header";
import { LockIndicator } from "@/features/production/components/lock-indicator";
import { SummaryRow } from "@/features/production/components/summary-row";
import { dbKg, formatKg } from "@/features/production/kg";
import { isUuid, readLogDays, readLot } from "@/features/production/queries";
import { isClosed, isOpen } from "@/features/production/types";
import { thaiDate } from "@/lib/format/date";
import { one } from "@/lib/params";
import { newIdempotencyKey } from "@/lib/rpc/production";

/* CM 05 — ปิด Lot (S4, LotCloseSummary). A read-only summary, then one irreversible action
 * behind ConfirmDialog. Closing locks the lot and calculates in one transaction with no
 * approval step (C02, UAT-23), and creates no return-freight job (BR17).
 *
 * NO COST AND NO YIELD, FOR THIS ROLE, IN THE PAYLOAD. That is a data-layer difference, not
 * a conditional render (LotCloseSummary contract): the views this page reads have neither
 * column, and fn_close_lot's response carries neither (TC-57, UAT-15). The figures are the
 * weights the operator entered and the remainder the system computed.
 *
 * The confirm sheet is URL state (`?confirm=1`) and a plain form posting to a Server Action,
 * so it ships no client JavaScript; the idempotency key is rendered into it, and a double tap
 * is fn_close_lot's replay of the first tap, not a second close (TC-53). Banners stack danger,
 * then warning, then info — a fixed order, never by arrival (S4). */

export default async function ClosePage(
  props: PageProps<"/cm/lots/[lotId]/close">,
) {
  const { lotId } = await props.params;
  const params = await props.searchParams;
  const confirming = one(params.confirm) === "1";
  const err = one(params.err);
  const justClosed = one(params.closed) === "1";
  if (!isUuid(lotId)) return <LotUnavailable />;

  const base = `/cm/lots/${lotId}/close`;
  const [lotRead, daysRead] = await Promise.all([
    readLot(lotId),
    readLogDays(lotId),
  ]);
  if (lotRead.error || !lotRead.data.lot) {
    return <LotUnavailable error={lotRead.error} retryHref={base} />;
  }
  const { lot, pending, progress } = lotRead.data;
  const days = daysRead.data;
  const closed = isClosed(lot.state);
  const received = lot.received_weight_kg !== null;
  const drained = lot.post_drain_weight_kg !== null;
  const daysLogged = progress?.days_logged ?? 0;
  const pendingH = dbKg(pending?.pending_weight_kg);

  // Why the close is unavailable, in the order fn_close_lot would refuse it (LOT_NOT_READY).
  const blocker = closed
    ? null
    : !isOpen(lot.state)
      ? "Lot นี้ยังไม่ถึงโรงรม"
      : !received
        ? "ยังไม่มีบันทึกรับเนื้อ"
        : daysLogged === 0
          ? "ยังไม่มีบันทึกรมควัน"
          : null;

  return (
    <div className="flex flex-col gap-4">
      <LotHeader lot={lot} title="ปิด Lot" backHref={`/cm/lots/${lotId}`} />

      {closed ? (
        <>
          {justClosed ? (
            <AlertBanner tone="success" title="ปิด Lot แล้ว">
              ระบบล็อกข้อมูลและคำนวณผลให้ Owner แล้ว ไม่มีขั้นรออนุมัติ
            </AlertBanner>
          ) : null}
          <LockIndicator
            closedAt={lot.closed_at}
            closedBy={lot.closed_by_name}
          />
          <AlertBanner tone="info">
            การปิด Lot ยังไม่สร้างงานรถขากลับ — Owner
            หรือผู้ได้รับมอบหมายจะนัดวันรับเอง
          </AlertBanner>
        </>
      ) : (
        <>
          {blocker ? (
            <AlertBanner tone="danger" title="ยังปิด Lot ไม่ได้">
              {blocker} — ต้องมีบันทึกรับเนื้อ และบันทึกรมควันอย่างน้อยหนึ่งวัน{" "}
              <Link
                href={`/cm/lots/${lotId}`}
                className="text-accent underline"
              >
                กลับไปทำขั้นที่ขาด
              </Link>
            </AlertBanner>
          ) : null}
          {received && !drained ? (
            <AlertBanner tone="warning" title="ยังไม่ได้บันทึกน้ำหนักก่อนสโมค">
              ปิดได้ แต่ควรบันทึกก่อน —{" "}
              <Link
                href={`/cm/lots/${lotId}/drain`}
                className="text-accent underline"
              >
                ไปบันทึก
              </Link>
            </AlertBanner>
          ) : null}
          {pendingH !== null && pendingH > 0 ? (
            <AlertBanner tone="warning" title="ยังมีน้ำหนักรอทำ">
              เหลือ{" "}
              <span className="font-mono tabular-nums">
                {formatKg(pending?.pending_weight_kg)}
              </span>{" "}
              กก. ที่ยังไม่ได้บันทึกว่านำไปรมควัน — ตรวจว่าผลิตครบแล้วก่อนปิด
            </AlertBanner>
          ) : null}
          <AlertBanner tone="info">
            ปิดแล้วระบบล็อก Lot และคำนวณผลให้ Owner ทันที ไม่มีขั้นรออนุมัติ
          </AlertBanner>
        </>
      )}

      <dl className="rounded-lg border border-border bg-surface px-4">
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
          label="นำไปรมควันแล้ว"
          value={formatKg(progress?.input_consumed_kg ?? 0)}
          unit="กก."
        />
        <SummaryRow
          label="น้ำหนักรอทำ"
          value={
            pendingH === null ? null : formatKg(pending?.pending_weight_kg)
          }
          unit="กก."
          missing="รอน้ำหนักก่อนสโมค"
        />
        <SummaryRow
          label={
            progress?.first_log_date && progress.last_log_date
              ? `บันทึกรมควัน ${daysLogged} วัน (${thaiDate(progress.first_log_date)} – ${thaiDate(progress.last_log_date)})`
              : "บันทึกรมควัน"
          }
          value={String(daysLogged)}
          unit="วัน"
        />
        <SummaryRow
          label="น้ำหนักหลังผลิตรวม"
          value={
            progress?.smoked_weight_kg == null
              ? null
              : formatKg(progress.smoked_weight_kg)
          }
          unit="กก."
          missing="ยังไม่บันทึก"
        />
        <SummaryRow
          label="น้ำดองที่ใช้รวม"
          value={
            progress?.brine_used_kg == null
              ? null
              : formatKg(progress.brine_used_kg)
          }
          unit="กก."
          missing="ยังไม่บันทึก"
        />
        <SummaryRow
          label={`แพ็คแล้ว ${progress?.bag_count ?? 0} ถุง`}
          value={formatKg(progress?.packed_weight_kg ?? 0)}
          unit="กก."
          emphasis="strong"
        />
      </dl>

      {days.length > 0 ? (
        <section className="flex flex-col gap-2" aria-label="รายวัน">
          <h2 className="text-h3 text-text-primary">
            รายวัน (ตามวันรมควันบนถุง)
          </h2>
          <ul className="flex flex-col gap-2">
            {days.map((d) => (
              <li
                key={d.smoke_daily_log_id}
                className="rounded-lg border border-border bg-surface px-4 py-2"
              >
                <p className="text-label text-text-primary">
                  {thaiDate(d.event_date)}
                </p>
                <p className="text-body-sm text-text-secondary">
                  นำไปรมควัน{" "}
                  <span className="font-mono text-text-primary tabular-nums">
                    {formatKg(d.input_weight_kg)}
                  </span>{" "}
                  กก.
                  {" · "}แพ็ค{" "}
                  <span className="font-mono text-text-primary tabular-nums">
                    {d.bag_count}
                  </span>{" "}
                  ถุง{" "}
                  <span className="font-mono text-text-primary tabular-nums">
                    {formatKg(d.packed_weight_kg)}
                  </span>{" "}
                  กก.
                </p>
              </li>
            ))}
          </ul>
        </section>
      ) : daysRead.error ? (
        <ReadError title="อ่านบันทึกรายวันไม่สำเร็จ" raw={daysRead.error} />
      ) : null}

      {closed ? null : (
        <BottomActionBar>
          {blocker ? (
            /* Never a bare disabled button: the bar says why (S4, REVIEW 16). */
            <p className="flex h-12 items-center justify-center rounded-md border border-border bg-surface-sunken px-4 text-label text-text-secondary">
              ปิด Lot ไม่ได้ · {blocker}
            </p>
          ) : (
            <Link href={`${base}?confirm=1`} className={dangerButton}>
              ปิด Lot นี้
            </Link>
          )}
        </BottomActionBar>
      )}

      {confirming && !closed && !blocker ? (
        /* ConfirmDialog: a bottom sheet on a phone with confirm at the bottom, a centred panel
         * from md:. Cancel is a text link, never the same size and colour as confirm. */
        <div className="fixed inset-0 z-30 flex items-end bg-text-primary/40 md:items-center md:justify-center">
          <div className="w-full max-w-xl p-2 pb-[calc(0.5rem+env(safe-area-inset-bottom))] md:p-0">
            <Sheet
              title={`ยืนยันปิด Lot ${lot.lot_code}`}
              subtitle="ตรวจสรุปด้านหลังแล้วจึงยืนยัน"
              closeHref={base}
              closeLabel="ยกเลิก"
            >
              {err ? (
                <AlertBanner tone="danger" title="ปิด Lot ไม่สำเร็จ">
                  {err}
                </AlertBanner>
              ) : null}
              <ul className="flex list-disc flex-col gap-1 pl-5 text-body-sm text-text-primary">
                <li>
                  ปิดแล้วแก้บันทึกรับเนื้อ รมควัน และแพ็คของ Lot นี้ไม่ได้
                  ต้องขอ Owner ปลดล็อก
                </li>
                <li>ระบบคำนวณผลให้ Owner ทันที ไม่มีขั้นรออนุมัติ</li>
                <li>ยังไม่สร้างงานรถขากลับ จนกว่าจะมีคนนัดวันรับ</li>
              </ul>
              <form action={closeLotAction}>
                <input type="hidden" name="lot_id" value={lotId} />
                <input
                  type="hidden"
                  name="idempotency_key"
                  value={newIdempotencyKey()}
                />
                <button type="submit" className={dangerButton}>
                  ยืนยันปิด Lot
                </button>
              </form>
            </Sheet>
          </div>
        </div>
      ) : null}
    </div>
  );
}
