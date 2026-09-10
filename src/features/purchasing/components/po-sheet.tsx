import { control, Field } from "@/components/ui/controls";
import { WeightField } from "@/components/shared/decimal-field";
import { SubmitBar } from "@/components/shared/submit-bar";
import { Sheet } from "@/features/config/components/sheet";
import { thaiDate } from "@/lib/format/date";
import { kg, pct, thb } from "@/lib/format/number";
import { submitRound } from "../actions";
import { LOT_STATE_LABEL } from "../labels";
import type { LocationOption, PoRegisterRow, PoRoundRow } from "../types";

/* `?po=<id>` — one PO, its rounds, and the round form (OW 01, card ^ref-20).
 *
 * D01 IS THE SCREEN'S MAIN JOB (PLAN-purchasing.md, "What ^ref-20 owes"). Every round is
 * listed with the lot it created, so 100 kg sent as 40 + 30 reads as two lots with two codes,
 * never one PO with a weight. Ordered, sent and outstanding sit in one stacked list that fits
 * at 360px with no horizontal table (PurchaseOrderForm, worst case). All three come from
 * v_po_outstanding through v_po_register — none is a field anyone types.
 *
 * THE OVERSHOOT RULE IS SHOWN BEFORE IT IS HIT. The outstanding weight is the round weight
 * field's hint, so PO_OVERDELIVERY is a message the Owner should almost never see. The
 * database still refuses; the hint is the mirror (ADR-004).
 *
 * The chef house is a picker, because fn_add_po_delivery takes the lot's destination at
 * booking. When there is only one, it is preselected.
 */

function Figure({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="text-body-sm text-text-secondary">{label}</dt>
      <dd className="text-num-md text-text-primary tabular-nums">{value}</dd>
    </div>
  );
}

export function PoSheet({
  po,
  rounds,
  chefHouses,
  idempotencyKey,
  today,
  savedLotId,
  echo,
  closeHref,
}: {
  po: PoRegisterRow | null;
  rounds: PoRoundRow[];
  chefHouses: LocationOption[];
  idempotencyKey: string;
  today: string;
  savedLotId: string;
  echo: Record<string, string>;
  closeHref: string;
}) {
  if (!po) {
    return (
      <Sheet title="ไม่พบ PO นี้" closeHref={closeHref} closeLabel="ปิด">
        <p className="text-body text-text-secondary">
          PO นี้ไม่มีอยู่ หรือบัญชีนี้ไม่มีสิทธิ์เห็น
        </p>
      </Sheet>
    );
  }

  const savedLot = rounds.find((r) => r.lot_id === savedLotId);
  const outstanding = Number(po.outstanding_weight_kg);

  return (
    <Sheet
      title={`PO ${po.po_number}`}
      subtitle={`${po.supplier_name} · สั่งเมื่อ ${thaiDate(po.order_date)}`}
      closeHref={closeHref}
      closeLabel="ปิด"
    >
      {savedLot ? (
        <p className="rounded-lg border border-success bg-success-subtle p-3 text-body-sm text-success">
          บันทึกรอบที่ {savedLot.seq} แล้ว — สร้างล็อต{" "}
          <strong className="tabular-nums">{savedLot.lot_code}</strong>
        </p>
      ) : null}

      <dl className="flex flex-col gap-2 rounded-md border border-border bg-surface-sunken p-3">
        <Figure label="สั่ง" value={kg(po.ordered_weight_kg)} />
        <Figure label="ส่งแล้ว (สะสม)" value={kg(po.dispatched_weight_kg)} />
        <Figure label="ค้างส่ง" value={kg(po.outstanding_weight_kg)} />
      </dl>

      <dl className="flex flex-col gap-1 text-body-sm">
        <Figure label="ราคาต่อกิโลกรัม" value={thb(po.unit_price_thb_per_kg)} />
        <Figure label="ยอดรวมค่าเนื้อ" value={thb(po.meat_total_thb)} />
        <Figure
          label={`น้ำดองที่เสนอ ${pct(po.brine_pct_offered)}`}
          value={kg(po.brine_offered_kg)}
        />
        <Figure label="ต้นทุนน้ำดอง" value={thb(po.brine_cost_thb)} />
      </dl>

      <section className="flex flex-col gap-2">
        <h3 className="text-h3 text-text-primary">
          รอบส่ง — หนึ่งรอบ = หนึ่งล็อต
        </h3>
        {rounds.length === 0 ? (
          <p className="text-body-sm text-text-secondary">
            ยังไม่มีรอบส่ง — ยอดส่งแล้ว 0.00 กก. ค้างส่งเท่าที่สั่ง
          </p>
        ) : (
          <ol className="flex flex-col gap-2">
            {rounds.map((r) => (
              <li
                key={r.delivery_id}
                className="flex min-h-[72px] flex-col gap-1 rounded-lg border border-border bg-surface p-3"
              >
                <div className="flex items-start justify-between gap-2">
                  <span className="text-label text-text-primary">
                    รอบที่ {r.seq} → ล็อต{" "}
                    <span className="tabular-nums">{r.lot_code}</span>
                  </span>
                  <span className="text-num-sm text-text-primary tabular-nums">
                    {kg(r.foodiva_sent_weight_kg)}
                  </span>
                </div>
                <span className="text-caption text-text-secondary">
                  ส่ง {thaiDate(r.dispatch_date)} · {r.chef_house_name ?? "—"} ·{" "}
                  {LOT_STATE_LABEL[r.lot_state] ?? r.lot_state}
                </span>
              </li>
            ))}
          </ol>
        )}
      </section>

      {outstanding <= 0 ? (
        <p className="rounded-md border border-border bg-surface-sunken p-3 text-body-sm text-text-secondary">
          ส่งครบตามที่สั่งแล้ว — PO นี้ไม่รับรอบส่งเพิ่ม
        </p>
      ) : chefHouses.length === 0 ? (
        <p className="rounded-md border border-border bg-surface-sunken p-3 text-body-sm text-text-secondary">
          ยังไม่มีโรงรมควันที่เปิดใช้งานในระบบ จึงบันทึกรอบส่งไม่ได้ —
          ต้องเพิ่มสถานที่ประเภทโรงรมควันก่อน
        </p>
      ) : (
        <form action={submitRound} className="flex flex-col gap-4">
          <h3 className="text-h3 text-text-primary">บันทึกรอบส่งใหม่</h3>
          <input type="hidden" name="idempotency_key" value={idempotencyKey} />
          <input type="hidden" name="po_id" value={po.po_id} />

          <Field label="วันที่ Foodiva ส่งรอบนี้">
            <input
              type="date"
              name="event_date"
              required
              defaultValue={echo.event_date || today}
              className={control}
            />
          </Field>

          <Field label="ส่งไปโรงรมควัน">
            <select
              name="chef_house_location_id"
              required
              defaultValue={
                echo.chef_house_location_id ||
                (chefHouses.length === 1 ? chefHouses[0].id : "")
              }
              className={control}
            >
              <option value="" disabled>
                — เลือก —
              </option>
              {chefHouses.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name_th}
                </option>
              ))}
            </select>
          </Field>

          <WeightField
            label="น้ำหนักที่ Foodiva ส่งรอบนี้"
            name="foodiva_sent_weight_kg"
            required
            defaultValue={echo.foodiva_sent_weight_kg ?? ""}
            hint={`ส่งได้อีกไม่เกิน ${kg(po.outstanding_weight_kg)} — น้ำหนักนี้เป็นฐานคิด Loss ของล็อต (BR03)`}
          />

          <Field label="หมายเหตุ">
            <input
              type="text"
              name="note"
              defaultValue={echo.note ?? ""}
              className={control}
            />
          </Field>

          <SubmitBar
            label="บันทึกรอบส่ง"
            note="บันทึกแล้วจะสร้างล็อตใหม่ผูกกับ PO นี้ ยังไม่ตัดสต็อกจนกว่าจะส่งรถ (OW 02)"
          />
        </form>
      )}
    </Sheet>
  );
}
