import Link from "next/link";

import { AlertBanner } from "@/features/production/components/alert-banner";
import { ReadError } from "@/components/shared/read-error";
import { DateNavigator } from "@/features/production/components/date-navigator";
import { EmptyState } from "@/features/production/components/empty-state";
import {
  LotHeader,
  LotUnavailable,
} from "@/features/production/components/lot-header";
import type { SourceOption } from "@/features/production/components/lot-source-list";
import { LockIndicator } from "@/features/production/components/lock-indicator";
import { SmokeLogForm } from "@/features/production/components/smoke-log-form";
import { SummaryRow } from "@/features/production/components/summary-row";
import { dbKg, formatKg } from "@/features/production/kg";
import {
  isUuid,
  readLogDay,
  readLot,
  readSourceLots,
} from "@/features/production/queries";
import { isClosed, type SmokeLogDay } from "@/features/production/types";
import { todayBangkok } from "@/lib/format/date";
import { one } from "@/lib/params";
import { newIdempotencyKey } from "@/lib/rpc/production";

/* CM 04 — Daily Smoke Log (S2). The date is in the URL and defaults to today (v0.2 line 81,
 * ADR-007); the page reads that day's saved log from v_smoke_log_day and pre-fills the form
 * with it, because the evening visit has to re-send the morning's sources (Finding 3).
 *
 * The form is keyed by (lot, date), so moving to another day remounts it with that day's log.
 * The idempotency keys are minted here, once per render, and the form holds them from then
 * on (REVIEW item 10). */

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function DayReadOnly({ day }: { day: SmokeLogDay }) {
  return (
    <dl className="rounded-lg border border-border bg-surface px-4">
      {day.sources.map((s) => (
        <SummaryRow
          key={s.lot_id}
          label={`นำไปรมควันจาก ${s.lot_code}`}
          value={formatKg(s.input_weight_kg)}
          unit="กก."
        />
      ))}
      <SummaryRow
        label="น้ำดองที่ใช้"
        value={day.brine_used_kg === null ? null : formatKg(day.brine_used_kg)}
        unit="กก."
        missing="ไม่ได้บันทึก"
      />
      <SummaryRow
        label="น้ำหนักหลังผลิต"
        value={
          day.smoked_weight_kg === null ? null : formatKg(day.smoked_weight_kg)
        }
        unit="กก."
        missing="ไม่ได้บันทึก"
      />
      <SummaryRow
        label={`แพ็ค ${day.bag_count} ถุง`}
        value={formatKg(day.packed_weight_kg)}
        unit="กก."
      />
    </dl>
  );
}

export default async function SmokeLogPage(
  props: PageProps<"/cm/lots/[lotId]/smoke-log">,
) {
  const { lotId } = await props.params;
  const today = todayBangkok();
  const raw = one((await props.searchParams).date);
  const date = ISO_DATE.test(raw) && raw <= today ? raw : today;
  if (!isUuid(lotId)) return <LotUnavailable />;

  const path = `/cm/lots/${lotId}/smoke-log`;
  const { data, error } = await readLot(lotId);
  if (error || !data.lot) {
    return <LotUnavailable error={error} retryHref={path} />;
  }
  const { lot } = data;
  const header = (
    <LotHeader
      lot={lot}
      title="บันทึกรมควันรายวัน"
      backHref={`/cm/lots/${lotId}`}
    />
  );

  if (lot.received_weight_kg === null) {
    return (
      <div className="flex flex-col gap-4">
        {header}
        <AlertBanner tone="warning" title="ยังไม่มีบันทึกรับเนื้อ">
          เนื้อต้องถึงโรงรมก่อนจึงนำไปรมควันได้ —{" "}
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

  const [dayRead, sourceRead] = await Promise.all([
    readLogDay(lotId, date),
    lot.chef_house_location_id
      ? readSourceLots(lot.chef_house_location_id)
      : Promise.resolve({ data: [], error: null }),
  ]);
  const day = dayRead.data;
  const readError = dayRead.error ?? sourceRead.error;

  if (isClosed(lot.state)) {
    return (
      <div className="flex flex-col gap-4">
        {header}
        <DateNavigator path={path} date={date} today={today} />
        <LockIndicator closedAt={lot.closed_at} closedBy={lot.closed_by_name} />
        {day ? (
          <DayReadOnly day={day} />
        ) : (
          <EmptyState
            title="ไม่มีบันทึกรมควันของวันนี้"
            body="เลือกวันอื่นจากแถบวันที่ด้านบน"
          />
        )}
      </div>
    );
  }

  if (readError) {
    return (
      <div className="flex flex-col gap-4">
        {header}
        <DateNavigator path={path} date={date} today={today} />
        <ReadError title="อ่านบันทึกรมควันไม่สำเร็จ" raw={readError}>
          <Link href={`${path}?date=${date}`} className="text-accent underline">
            ลองอีกครั้ง
          </Link>
        </ReadError>
      </div>
    );
  }

  /* What each lot can still give today, BEFORE this form's entry: the view's remainder already
   * has today's saved sources taken off, and saving replaces them, so they are added back. */
  const savedToday = new Map<string, number>();
  for (const s of day?.sources ?? []) {
    savedToday.set(s.lot_id, dbKg(s.input_weight_kg) ?? 0);
  }
  const options: SourceOption[] = sourceRead.data.map((p) => {
    const pendingH = dbKg(p.pending_weight_kg);
    return {
      lotId: p.lot_id,
      lotCode: p.lot_code,
      availableH:
        pendingH === null ? null : pendingH + (savedToday.get(p.lot_id) ?? 0),
    };
  });
  // A lot today's log already drew from stays selectable even if it has since left the list.
  for (const s of day?.sources ?? []) {
    if (!options.some((o) => o.lotId === s.lot_id)) {
      options.push({ lotId: s.lot_id, lotCode: s.lot_code, availableH: null });
    }
  }

  return (
    <div className="flex flex-col gap-4">
      {header}
      <DateNavigator path={path} date={date} today={today} />
      <SmokeLogForm
        key={`${lotId}:${date}`}
        lotId={lotId}
        eventDate={date}
        keys={{ log: newIdempotencyKey(), bags: newIdempotencyKey() }}
        options={options}
        existing={
          day
            ? {
                sources: day.sources.map((s) => ({
                  lotId: s.lot_id,
                  kg: formatKg(s.input_weight_kg),
                })),
                smokedKg:
                  day.smoked_weight_kg === null
                    ? ""
                    : formatKg(day.smoked_weight_kg),
                brineKg:
                  day.brine_used_kg === null ? "" : formatKg(day.brine_used_kg),
              }
            : null
        }
        savedBagCount={day?.bag_count ?? 0}
        savedPackedH={dbKg(day?.packed_weight_kg) ?? 0}
      />
    </div>
  );
}
