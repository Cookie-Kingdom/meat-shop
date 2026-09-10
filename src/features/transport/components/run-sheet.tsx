import { actionButton, Field } from "@/components/ui/controls";
import { SubmitBar } from "@/components/shared/submit-bar";
import { Sheet } from "@/features/config/components/sheet";
import type { PoRoundRow } from "@/features/purchasing/types";
import { thaiDate } from "@/lib/format/date";
import { kg, thb } from "@/lib/format/number";
import { cn } from "@/lib/utils";
import { addLotsToRun, reallocateRun } from "../actions";
import { METHOD_LABEL, ROUTE_LABEL, tripLabel } from "../labels";
import type { FreightLineRow, TransportRunRow } from "../types";

/* `?run=<id>` — one run: the lots on it, the STORED split, and whether it still reconciles
 * to the fare (R24). OW 02, card ^ref-24.
 *
 * The figures here are the database's: v_transport_runs for the run and v_freight_allocation
 * for each line. This is where the preview on the booking sheet is checked against what
 * fn_allocate_freight actually wrote.
 *
 * The method shown is the run's own snapshot (R29). A config change after the run was
 * created does not change it, and the caption says so, so nobody reads a new config value
 * into an old run.
 *
 * TWO RECOVERY PATHS, BECAUSE A BOOKING IS SEVERAL TRANSACTIONS (Finding 5):
 *   - "แบ่งค่าขนส่งใหม่" when the shares do not reconcile — fn_allocate_freight recomputes,
 *     so pressing it twice writes the same numbers twice.
 *   - "เพิ่มล็อตขึ้นรถคันนี้" on an outbound run — for a lot whose dispatch failed mid-booking,
 *     or one the Owner adds to the same vehicle. Only PO_CREATED lots are offered, and the
 *     action re-checks.
 */

export function RunSheet({
  run,
  lines,
  dispatchable,
  idempotencyKey,
  closeHref,
}: {
  run: TransportRunRow | null;
  lines: FreightLineRow[];
  dispatchable: PoRoundRow[];
  idempotencyKey: string;
  closeHref: string;
}) {
  if (!run) {
    return (
      <Sheet title="ไม่พบรอบรถนี้" closeHref={closeHref} closeLabel="ปิด">
        <p className="text-body text-text-secondary">
          รอบรถนี้ไม่มีอยู่ หรือบัญชีนี้ไม่มีสิทธิ์เห็น
        </p>
      </Sheet>
    );
  }

  const canResplit =
    !run.fare_reconciles_to_satang &&
    run.route !== "CENTRAL_TO_BRANCH" &&
    run.alloc_method !== "MANUAL" &&
    run.line_count > 0;
  const canAddLots = run.route === "FOODIVA_TO_CM" && dispatchable.length > 0;

  return (
    <Sheet
      title={`รอบรถ ${thaiDate(run.event_date)}`}
      subtitle={`${ROUTE_LABEL[run.route]} · ${run.vehicle_type ?? "—"} · ${tripLabel(run.is_round_trip)}`}
      closeHref={closeHref}
      closeLabel="ปิด"
    >
      <dl className="flex flex-col gap-1 rounded-md border border-border bg-surface-sunken p-3 text-body-sm">
        <div className="flex justify-between gap-3">
          <dt className="text-text-secondary">ค่าเที่ยว</dt>
          <dd className="text-num-md text-text-primary tabular-nums">{thb(run.run_cost_thb)}</dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-text-secondary">วิธีแบ่ง</dt>
          <dd className="text-right text-text-primary">{METHOD_LABEL[run.alloc_method]}</dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-text-secondary">น้ำหนักบนรถ</dt>
          <dd className="text-text-primary tabular-nums">{kg(run.dispatched_weight_kg)}</dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-text-secondary">แบ่งแล้ว</dt>
          <dd className="text-text-primary tabular-nums">{thb(run.allocated_thb)}</dd>
        </div>
      </dl>
      <p className="text-caption text-text-muted">
        วิธีแบ่งบันทึกไว้ตอนสร้างรอบรถ การตั้งค่าที่เปลี่ยนภายหลังไม่ย้อนมาเปลี่ยนรอบนี้ (R29)
      </p>

      <p
        className={cn(
          "rounded-md border p-3 text-body-sm",
          run.fare_reconciles_to_satang
            ? "border-success bg-success-subtle text-success"
            : "border-warning bg-warning-subtle text-text-primary",
        )}
      >
        {run.fare_reconciles_to_satang
          ? "ส่วนแบ่งรวมเท่าค่าเที่ยวพอดี (R24)"
          : run.alloc_method === "MANUAL"
            ? "ยังไม่ได้แบ่งค่าขนส่ง — วิธีแบ่งเป็น MANUAL และรอบนี้ยังไม่มีหน้าจอกรอกส่วนแบ่งเอง"
            : "ส่วนแบ่งยังไม่ครบค่าเที่ยว — กด “แบ่งค่าขนส่งใหม่” ด้านล่าง"}
      </p>

      {lines.length === 0 ? (
        <p className="text-body-sm text-text-secondary">
          ยังไม่มีล็อตบนรถคันนี้
        </p>
      ) : (
        <ul className="flex flex-col gap-2">
          {lines.map((l) => (
            <li
              key={l.line_id}
              className="flex min-h-14 items-center justify-between gap-3 rounded-md border border-border bg-surface px-3 py-2"
            >
              <span className="flex flex-col">
                <span className="text-label text-text-primary tabular-nums">{l.lot_code}</span>
                <span className="text-caption text-text-secondary tabular-nums">
                  {kg(l.dispatched_weight_kg)}
                </span>
              </span>
              <span className="text-num-sm text-text-primary tabular-nums">
                {l.freight_share_thb === null ? "ยังไม่แบ่ง" : thb(l.freight_share_thb)}
              </span>
            </li>
          ))}
        </ul>
      )}

      {canResplit ? (
        <form action={reallocateRun}>
          <input type="hidden" name="idempotency_key" value={idempotencyKey} />
          <input type="hidden" name="run_id" value={run.run_id} />
          <button type="submit" className={cn(actionButton, "h-12 w-full md:w-auto")}>
            แบ่งค่าขนส่งใหม่
          </button>
        </form>
      ) : null}

      {canAddLots ? (
        <form action={addLotsToRun} className="flex flex-col gap-3">
          <input type="hidden" name="idempotency_key" value={idempotencyKey} />
          <input type="hidden" name="run_id" value={run.run_id} />
          <Field label="เพิ่มล็อตขึ้นรถคันนี้" hint="เฉพาะล็อตที่ยังรอรถ — น้ำหนักเป็นน้ำหนักรอบส่งจาก OW 01">
            <span className="flex flex-col gap-2">
              {dispatchable.map((r) => (
                <label
                  key={r.lot_id}
                  className="flex min-h-14 items-center gap-3 rounded-md border border-border bg-surface px-3 py-2"
                >
                  <input
                    type="checkbox"
                    name="lot"
                    value={r.lot_id}
                    className="size-6 shrink-0 accent-accent"
                  />
                  <span className="flex min-w-0 flex-1 flex-col">
                    <span className="text-label text-text-primary tabular-nums">{r.lot_code}</span>
                    <span className="text-caption text-text-secondary">
                      {r.supplier_name} · ถึง {r.chef_house_name ?? "—"}
                    </span>
                  </span>
                  <span className="shrink-0 text-num-sm text-text-primary tabular-nums">
                    {kg(r.foodiva_sent_weight_kg)}
                  </span>
                </label>
              ))}
            </span>
          </Field>
          <SubmitBar
            label="เพิ่มล็อตขึ้นรถคันนี้"
            note="ค่าเที่ยวเท่าเดิม ระบบแบ่งใหม่ให้ทุกล็อตบนรถ"
          />
        </form>
      ) : null}
    </Sheet>
  );
}
