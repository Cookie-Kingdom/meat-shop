import Link from "next/link";

import { actionLink, control, Field } from "@/components/ui/controls";
import { submitSales, submitWaste } from "@/features/branch-close/actions";
import { ClosedDayNotice } from "@/features/branch-close/components/closed-day-notice";
import { DiffPanel } from "@/features/branch-close/components/diff-panel";
import { readDiff, readReadyLots } from "@/features/branch-close/queries";
import { BranchHeading } from "@/features/branch/components/branch-heading";
import { DateNavigator } from "@/features/branch/components/date-navigator";
import {
  CountField,
  ReasonField,
  WeightField,
} from "@/features/branch/components/fields";
import { NoBranch, Notice } from "@/features/branch/components/notice";
import { StockStateBadge } from "@/features/branch/components/stock-state-badge";
import { SubmitButton } from "@/features/branch/components/submit-button";
import { loadBranchDay } from "@/features/branch/context";
import {
  BottomActionBar,
  writeButton,
} from "@/features/production/components/bottom-action-bar";
import { thaiDate } from "@/lib/format/date";
import { one } from "@/lib/params";

/* BR 07 ปิดยอดรายวัน — the day's sales and the READY leftover's waste (card ^ref-46,
 * PLAN-sales.md T7, build notes PLAN-close-screens.md; skeleton S2).
 *
 * THE DIFF IS PINNED ABOVE and is v_branch_diff's saved row, re-read after every save (Finding 1).
 * It mirrors; fn_close_daily_report decides (ADR-004). Nothing on this page claims to decide.
 *
 * SALES are quantities, never money: an L2 enters counts and the function resolves and
 * snapshots the price (BR23, R20). Each READY (lot, smoke-date group) row takes a box count and
 * an add-on bag count — two SKUs, never one field (D03.1, UAT-16), and two lots are two rows
 * (D05). Chilli, rice and water are one field each. An empty field sends no line (Finding 4).
 *
 * WASTE is READY smoked meat only, one lot per submit, weight typed (Finding 5).
 *
 * TWO FORMS, TWO KEYS, one per page view (Finding 6). A CLOSED day keeps both forms under
 * ClosedDayNotice; REPORT_CLOSED decides (Finding 8). */

export default async function BranchClose(props: PageProps<"/branch/close">) {
  const params = await props.searchParams;
  const day = await loadBranchDay({
    location: one(params.location),
    date: one(params.date),
  });
  const branch = day.branch;
  if (!branch) return <NoBranch error={day.error} />;
  const report = day.report;

  const [ready, diff] = await Promise.all([
    readReadyLots(day.supabase, branch.id),
    readDiff(day.supabase, branch.id, day.date),
  ]);
  const lots = ready.rows;

  const here = new URLSearchParams({ location: branch.id, date: day.date }).toString();
  const back = `/branch/close?${here}`;
  const saved = one(params.saved);
  const err = one(params.err);
  const kept = (name: string) => one(params[name]);
  const salesKey = crypto.randomUUID();
  const wasteKey = crypto.randomUUID();

  return (
    <div className="flex flex-col gap-4">
      <BranchHeading
        title="ปิดยอดรายวัน"
        branches={day.branches}
        branch={branch}
        date={day.date}
        basePath="/branch/close"
      />
      <DateNavigator
        value={day.date}
        max={day.today}
        basePath="/branch/close"
        params={{ location: branch.id }}
      />

      {saved === "sales" ? <Notice tone="success">บันทึกยอดขายแล้ว</Notice> : null}
      {saved === "waste" ? <Notice tone="success">บันทึก Waste แล้ว</Notice> : null}
      {err ? <Notice tone="danger">{err}</Notice> : null}
      {ready.error || diff.error ? (
        <Notice tone="danger">
          อ่านข้อมูลของวันไม่สำเร็จ — {ready.error ?? diff.error}
        </Notice>
      ) : null}

      {!report ? (
        <Notice tone="warning">
          วันที่ {thaiDate(day.date)} ยังไม่ได้เปิด —{" "}
          <Link href={`/branch?${here}`} className={actionLink}>
            เปิดวันก่อน
          </Link>
        </Notice>
      ) : (
        <>
          <DiffPanel diff={diff.row} readyLots={lots} />
          {report.status === "CLOSED" ? (
            <ClosedDayNotice db={day.supabase} reportId={report.id} date={day.date} />
          ) : null}

          <form
            action={submitSales}
            aria-labelledby="br07-sales"
            className="flex flex-col gap-4 rounded-lg border border-border bg-surface p-4"
          >
            <input type="hidden" name="idempotency_key" value={salesKey} />
            <input type="hidden" name="daily_report_id" value={report.id} />
            <input type="hidden" name="back" value={back} />
            <h2 id="br07-sales" className="text-h3 text-text-primary">
              ยอดขาย
            </h2>
            <p className="text-caption text-text-muted">
              กรอกเป็นจำนวน — ราคาระบบใช้ตามที่เจ้าของร้านตั้งไว้ของวันนั้น ช่องที่เว้นว่างไม่ถูกบันทึก
            </p>

            <fieldset className="flex flex-col gap-2">
              <legend className="mb-2 text-label text-text-secondary">
                เนื้อรมควัน — แยกตามล็อตและวันรมควัน
              </legend>
              {lots.length === 0 ? (
                <p className="rounded-lg border border-border bg-surface-sunken p-4 text-body-sm text-text-secondary">
                  ไม่มีเนื้อพร้อมขายในสาขานี้ —{" "}
                  <Link href={`/branch/thaw?${here}`} className={actionLink}>
                    ละลายเนื้อก่อน
                  </Link>
                </p>
              ) : (
                /* The one internal scroll region (S2): --scroll-cap, 230px. */
                <div className="max-h-[230px] overflow-y-auto rounded-lg border border-border">
                  {lots.map((l) => {
                    const id = `${l.lot_id}:${l.smoke_date_group_id}`;
                    return (
                      <div
                        key={id}
                        className="flex flex-col gap-2 border-b border-border px-4 py-3 last:border-b-0"
                      >
                        <div className="flex flex-wrap items-center justify-between gap-2">
                          <span className="flex flex-col">
                            <span className="text-body text-text-primary">ล็อต {l.lot_code}</span>
                            <span className="text-caption text-text-muted">
                              รมควัน {thaiDate(l.smoke_date)}
                            </span>
                          </span>
                          <StockStateBadge state="ready" weightKg={l.available_qty} size="sm" />
                        </div>
                        <div className="grid grid-cols-2 gap-3">
                          <CountField
                            label="กล่องปกติ"
                            name={`box:${id}`}
                            unit="กล่อง"
                            defaultValue={kept(`box:${id}`)}
                          />
                          <CountField
                            label="Add-on ซีลเพิ่ม"
                            name={`addon:${id}`}
                            unit="ถุง"
                            defaultValue={kept(`addon:${id}`)}
                          />
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </fieldset>

            <fieldset className="grid gap-3 sm:grid-cols-3">
              <legend className="mb-2 text-label text-text-secondary">รายการอื่น</legend>
              <CountField
                label="น้ำพริก หลอด 30 กรัม"
                name="chilli"
                unit="หลอด"
                defaultValue={kept("chilli")}
              />
              <Field label="ข้าวเหนียว">
                <span className="flex items-center gap-2">
                  <input
                    type="text"
                    inputMode="decimal"
                    autoComplete="off"
                    name="rice"
                    defaultValue={kept("rice")}
                    className={`${control} h-12 font-mono text-num-md tabular-nums`}
                  />
                  <span className="text-body text-text-secondary">กก.</span>
                </span>
              </Field>
              <CountField
                label="น้ำเปล่า"
                name="water"
                unit="ขวด"
                defaultValue={kept("water")}
              />
            </fieldset>

            <SubmitButton>บันทึกยอดขาย</SubmitButton>
          </form>

          <form
            action={submitWaste}
            id="waste"
            aria-labelledby="br07-waste"
            className="flex flex-col gap-4 rounded-lg border border-border bg-surface p-4"
          >
            <input type="hidden" name="idempotency_key" value={wasteKey} />
            <input type="hidden" name="daily_report_id" value={report.id} />
            <input type="hidden" name="back" value={back} />
            <h2 id="br07-waste" className="text-h3 text-text-primary">
              Waste เนื้อพร้อมขายที่เหลือ
            </h2>
            <p className="text-caption text-text-muted">
              เนื้อที่ละลายแล้วเก็บข้ามวันไม่ได้ — ชั่งส่วนที่เหลือจริงแล้วบันทึกทีละล็อต
            </p>
            {lots.length === 0 ? (
              <p className="rounded-lg border border-border bg-surface-sunken p-4 text-body-sm text-text-secondary">
                ไม่มีเนื้อพร้อมขายเหลือในสาขานี้
              </p>
            ) : (
              <>
                <fieldset className="max-h-[230px] overflow-y-auto rounded-lg border border-border">
                  <legend className="sr-only">เลือกล็อต</legend>
                  {lots.map((l) => {
                    const value = `${l.lot_id}:${l.smoke_date_group_id}`;
                    return (
                      <label
                        key={value}
                        className="flex min-h-14 items-center gap-3 border-b border-border px-4 py-2 last:border-b-0"
                      >
                        <input
                          type="radio"
                          name="waste_pick"
                          value={value}
                          required
                          defaultChecked={lots.length === 1 || value === kept("waste_pick")}
                          className="size-5 shrink-0"
                        />
                        <span className="flex flex-1 flex-col">
                          <span className="text-body text-text-primary">ล็อต {l.lot_code}</span>
                          <span className="text-caption text-text-muted">
                            รมควัน {thaiDate(l.smoke_date)}
                          </span>
                        </span>
                        <StockStateBadge state="ready" weightKg={l.available_qty} size="sm" />
                      </label>
                    );
                  })}
                </fieldset>
                <WeightField
                  label="น้ำหนักที่ทิ้งจริง"
                  name="waste_kg"
                  defaultValue={kept("waste_kg")}
                />
                <ReasonField
                  label="เหตุผล"
                  name="waste_reason"
                  required
                  defaultValue={kept("waste_reason")}
                />
                <SubmitButton>บันทึก Waste</SubmitButton>
              </>
            )}
          </form>

          <BottomActionBar>
            <Link href={`/branch/close/confirm?${here}`} className={writeButton}>
              ไปหน้ายืนยันปิดวัน
            </Link>
          </BottomActionBar>
        </>
      )}
    </div>
  );
}
