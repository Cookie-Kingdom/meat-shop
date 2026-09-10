import Link from "next/link";

import { actionLink, control, Field } from "@/components/ui/controls";
import { SubmitBar } from "@/components/shared/submit-bar";
import { Sheet } from "@/features/config/components/sheet";
import type { PoRoundRow } from "@/features/purchasing/types";
import { thaiDate } from "@/lib/format/date";
import { fromHundredths, kg, toHundredths } from "@/lib/format/number";
import { cn } from "@/lib/utils";
import { confirmOutboundRun } from "../actions";
import { METHOD_LABEL } from "../labels";
import {
  fareFor,
  outboundSig,
  previewSplit,
  TRIP_KINDS,
  type FareTable,
  type TripKind,
} from "../outbound";
import type { AllocMethod } from "../types";

/* `?new=1` — ส่งรถขาไป, the outbound `TransportForm` (OW 02, card ^ref-24).
 *
 * v0.2 OW 02: "วันที่รับ เส้นทาง น้ำหนักที่ส่ง และรูปแบบไปกลับ" → "ดึงค่าขนส่งจาก Config และเปลี่ยน
 * สถานะเป็น In Transit". So:
 *
 *   - NO MONEY FIELD. The fare is read-only from freight_thb_by_vehicle_type at the run date
 *     (BR10, D04.1; the TransportForm contract: "if one appears in a diff, it was guessed").
 *   - THE WEIGHT IS THE ROUND'S, READ-ONLY. Each lot was declared once on OW 01, and that
 *     weight is its loss base (BR03, ADR-011). The route is Foodiva → the chef house each
 *     round named.
 *   - THE SPLIT IS SHOWN PER LOT BEFORE SUBMIT (TransportForm worst case, UAT-06). A plain
 *     GET form: "คำนวณค่าขนส่ง" writes the choice into the URL, and the page renders the fare,
 *     the method and each lot's share. The confirm button then posts to the Server Action.
 *     It carries a signature of what was previewed, and a changed selection goes back to the
 *     preview instead of booking.
 *
 * `เที่ยวเดียว / ไป-กลับ` is a vertical radio list on a phone and horizontal from `md:`
 * (RadioGroup contract, worst case at 360px). Every row is at least 44px.
 */

type Props = {
  date: string;
  vehicle: string;
  trip: TripKind | null;
  selected: string[];
  preview: boolean;
  note: string;
  fareTable: FareTable | null;
  method: AllocMethod | null;
  methodSet: boolean;
  dispatchable: PoRoundRow[];
  idempotencyKey: string;
  closeHref: string;
};

const CONFIG_FARE_HREF = "/owner/config?set=CONFIG:freight_thb_by_vehicle_type:";
const CONFIG_METHOD_HREF = "/owner/config?set=CONFIG:freight_alloc_method:";

function Notice({ children }: { children: React.ReactNode }) {
  return (
    <div className="rounded-md border border-warning bg-warning-subtle p-3 text-body-sm text-text-primary">
      {children}
    </div>
  );
}

export function NewRunSheet(p: Props) {
  const vehicles = p.fareTable ? [...p.fareTable.keys()].sort((a, b) => a.localeCompare(b, "th")) : [];
  const selectedRounds = p.dispatchable.filter((r) => p.selected.includes(r.lot_id));
  const stale = p.selected.length - selectedRounds.length;
  const fare = p.trip ? fareFor(p.fareTable, p.vehicle, p.trip) : null;
  const lines = selectedRounds.map((r) => ({
    id: r.lot_id,
    weight: toHundredths(String(r.foodiva_sent_weight_kg)) ?? BigInt(0),
  }));
  const totalWeight = lines.reduce((s, l) => s + l.weight, BigInt(0));
  const split = fare !== null && p.method ? previewSplit(fare, lines, p.method) : null;
  const destinations = [...new Set(selectedRounds.map((r) => r.chef_house_name ?? "—"))];

  const canConfirm =
    p.preview &&
    fare !== null &&
    p.method !== null &&
    selectedRounds.length > 0 &&
    stale === 0;

  return (
    <Sheet
      title="ส่งรถขาไป"
      subtitle="Foodiva → โรงรมควันเชียงใหม่ · ค่าขนส่งดึงจากการตั้งค่า ไม่มีช่องกรอก (BR10)"
      closeHref={p.closeHref}
    >
      {vehicles.length === 0 ? (
        <Notice>
          ยังไม่ได้ตั้งตารางค่าเที่ยวตามประเภทรถ ณ วันที่ {thaiDate(p.date)} จึงยังส่งรถไม่ได้ —{" "}
          <Link href={CONFIG_FARE_HREF} className="text-accent underline">
            ตั้งค่าขนส่งตามประเภทรถ
          </Link>
        </Notice>
      ) : null}
      {!p.methodSet ? (
        <Notice>
          ยังไม่ได้ตั้งวิธีเฉลี่ยค่าขนส่งหลายล็อต ณ วันที่นี้ — ระบบจะไม่สร้างรอบรถจนกว่าจะตั้ง (ADR-023){" "}
          <Link href={CONFIG_METHOD_HREF} className="text-accent underline">
            ตั้งวิธีเฉลี่ย
          </Link>
        </Notice>
      ) : null}

      <form method="get" className="flex flex-col gap-4">
        <input type="hidden" name="new" value="1" />

        <Field label="วันที่รถรับของ">
          <input type="date" name="date" required defaultValue={p.date} className={control} />
        </Field>

        <Field label="ประเภทรถ" hint="รายการมาจากตารางค่าเที่ยวในการตั้งค่า ณ วันที่รถรับของ">
          <select name="vehicle" required defaultValue={p.vehicle} className={control}>
            <option value="" disabled>
              — เลือก —
            </option>
            {vehicles.map((v) => (
              <option key={v} value={v}>
                {v}
              </option>
            ))}
          </select>
        </Field>

        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-label text-text-secondary">รูปแบบรถ</legend>
          <div className="flex flex-col gap-2 md:flex-row">
            {TRIP_KINDS.map((t) => (
              <label
                key={t.value}
                className="flex min-h-11 flex-1 items-center gap-3 rounded-md border border-border bg-surface px-3 py-2 text-body text-text-primary"
              >
                <input
                  type="radio"
                  name="trip"
                  value={t.value}
                  required
                  defaultChecked={p.trip === t.value}
                  className="size-5 shrink-0 accent-accent"
                />
                {t.label}
              </label>
            ))}
          </div>
        </fieldset>

        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-label text-text-secondary">
            ล็อตที่ขึ้นรถ — รอบส่งที่ยังรอรถ (OW 01)
          </legend>
          {p.dispatchable.length === 0 ? (
            <p className="text-body-sm text-text-secondary">
              ไม่มีล็อตที่รอส่งรถ — บันทึกรอบส่งที่หน้า{" "}
              <Link href="/owner/purchasing" className="text-accent underline">
                สั่งซื้อเนื้อ
              </Link>{" "}
              ก่อน
            </p>
          ) : (
            p.dispatchable.map((r) => (
              <label
                key={r.lot_id}
                className="flex min-h-14 items-center gap-3 rounded-md border border-border bg-surface px-3 py-2"
              >
                <input
                  type="checkbox"
                  name="lot"
                  value={r.lot_id}
                  defaultChecked={p.selected.includes(r.lot_id)}
                  className="size-6 shrink-0 accent-accent"
                />
                <span className="flex min-w-0 flex-1 flex-col">
                  <span className="text-label text-text-primary tabular-nums">{r.lot_code}</span>
                  <span className="text-caption text-text-secondary">
                    {r.supplier_name} · ถึง {r.chef_house_name ?? "—"} · รอบส่ง {thaiDate(r.dispatch_date)}
                  </span>
                </span>
                <span className="shrink-0 text-num-sm text-text-primary tabular-nums">
                  {kg(r.foodiva_sent_weight_kg)}
                </span>
              </label>
            ))
          )}
        </fieldset>

        <Field label="หมายเหตุ">
          <input type="text" name="note" defaultValue={p.note} className={control} />
        </Field>

        <button
          type="submit"
          name="preview"
          value="1"
          className={cn(actionLink, "h-12 justify-center rounded-md border border-accent px-4")}
        >
          คำนวณค่าขนส่ง
        </button>

        {p.preview ? (
          <section className="flex flex-col gap-3 rounded-md border border-border bg-surface-sunken p-3">
            <h3 className="text-h3 text-text-primary">ตรวจก่อนยืนยัน</h3>
            {stale > 0 ? (
              <Notice>มี {stale} ล็อตที่เลือกไว้ไม่อยู่ในรายการรอส่งแล้ว — เลือกใหม่แล้วคำนวณอีกครั้ง</Notice>
            ) : null}
            <dl className="flex flex-col gap-1 text-body-sm">
              <div className="flex justify-between gap-3">
                <dt className="text-text-secondary">เส้นทาง</dt>
                <dd className="text-right text-text-primary">Foodiva → {destinations.join(", ") || "—"}</dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="text-text-secondary">ค่าเที่ยว (จากการตั้งค่า)</dt>
                <dd className="text-right text-num-md text-text-primary tabular-nums">
                  {fare !== null ? `${fromHundredths(fare)} บาท` : "ยังไม่ได้ตั้ง"}
                </dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="text-text-secondary">วิธีแบ่ง (บันทึกติดรอบรถ)</dt>
                <dd className="text-right text-text-primary">{p.method ? METHOD_LABEL[p.method] : "ยังไม่ได้ตั้ง"}</dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="text-text-secondary">น้ำหนักรวมบนรถ</dt>
                <dd className="text-right text-text-primary tabular-nums">{fromHundredths(totalWeight)} กก.</dd>
              </div>
            </dl>

            {fare === null && p.vehicle && p.trip ? (
              <Notice>
                ยังไม่ได้ตั้งค่าเที่ยวสำหรับ “{p.vehicle}” แบบ{p.trip === "ROUND_TRIP" ? "ไป-กลับ" : "เที่ยวเดียว"} ณ วันที่นี้ —{" "}
                <Link href={CONFIG_FARE_HREF} className="text-accent underline">
                  ตั้งค่าขนส่งตามประเภทรถ
                </Link>
              </Notice>
            ) : null}
            {p.method === "MANUAL" ? (
              <Notice>
                วิธีแบ่งเป็น MANUAL — ระบบจะส่งรถและเปลี่ยนสถานะล็อตให้ แต่ไม่แบ่งค่าขนส่งอัตโนมัติ
                และรอบนี้ยังไม่มีหน้าจอกรอกส่วนแบ่งเอง ต้นทุนล็อตจะยังไม่รวมค่าขนส่งนี้
              </Notice>
            ) : null}

            {selectedRounds.length > 0 ? (
              <ul className="flex flex-col gap-2">
                {selectedRounds.map((r) => {
                  const share = split?.get(r.lot_id);
                  return (
                    <li key={r.lot_id} className="flex items-center justify-between gap-3 rounded-md border border-border bg-surface px-3 py-2">
                      <span className="flex flex-col">
                        <span className="text-label text-text-primary tabular-nums">{r.lot_code}</span>
                        <span className="text-caption text-text-secondary tabular-nums">{kg(r.foodiva_sent_weight_kg)}</span>
                      </span>
                      <span className="text-num-sm text-text-primary tabular-nums">
                        {share !== undefined ? `${fromHundredths(share)} บาท` : "—"}
                      </span>
                    </li>
                  );
                })}
              </ul>
            ) : (
              <p className="text-body-sm text-text-secondary">ยังไม่ได้เลือกล็อต</p>
            )}

            {p.trip === "ROUND_TRIP" ? (
              <p className="text-caption text-text-secondary">
                ไป-กลับ: ค่าเที่ยวนี้รวมขากลับของรถคันเดียวกันแล้ว ขากลับไม่คิดค่าเที่ยวซ้ำ (BR16, D04.1)
              </p>
            ) : null}
            <p className="text-caption text-text-muted">
              ส่วนแบ่งคำนวณแบบเดียวกับระบบ (ปัด 2 ตำแหน่ง ส่วนที่เหลือไปที่ล็อตหนักสุด ผลรวมเท่าค่าเที่ยวพอดี —
              UAT-06) ตัวเลขที่บันทึกจริงแสดงที่รอบรถหลังยืนยัน
            </p>
          </section>
        ) : null}

        {canConfirm ? (
          <>
            <input type="hidden" name="idempotency_key" value={p.idempotencyKey} />
            <input
              type="hidden"
              name="sig"
              value={outboundSig({ date: p.date, vehicle: p.vehicle, trip: p.trip ?? "", lots: p.selected })}
            />
            <SubmitBar
              label="ยืนยันส่งรถ"
              formAction={confirmOutboundRun}
              note="ล็อตที่เลือกจะเปลี่ยนเป็น “กำลังขนส่ง” และปรากฏที่หน้าเชียงใหม่"
            />
          </>
        ) : null}
      </form>
    </Sheet>
  );
}
