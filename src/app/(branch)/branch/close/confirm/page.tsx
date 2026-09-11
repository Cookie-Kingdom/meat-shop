import Link from "next/link";

import { submitClose } from "@/features/branch-close/actions";
import { formatKg } from "@/features/branch/format";
import {
  largestFirst,
  readDiff,
  readReadyLots,
} from "@/features/branch-close/queries";
import { BranchHeading } from "@/features/branch/components/branch-heading";
import { DateNavigator } from "@/features/branch/components/date-navigator";
import { ReasonField } from "@/features/branch/components/fields";
import { NoBranch, Notice } from "@/features/branch/components/notice";
import { loadBranchDay } from "@/features/branch/context";
import { Sheet } from "@/features/config/components/sheet";
import { readMaterials, readRiceDay } from "@/features/materials/queries";
import { AlertBanner } from "@/features/production/components/alert-banner";
import {
  BottomActionBar,
  dangerButton,
} from "@/features/production/components/bottom-action-bar";
import { thaiDate, thaiDateTime } from "@/lib/format/date";
import { one } from "@/lib/params";

/* BR 09 ยืนยันปิดวัน — a read-only summary, then the day's one irreversible action (card
 * ^ref-46, PLAN-sales.md T8, PLAN-close-screens.md Findings 2, 3, 7, 8; skeleton S4, UAT-14).
 *
 * THE CARD'S ACCEPTANCE: the operator cannot close a day that does not reconcile, and is told
 * which line is wrong. fn_close_daily_report refuses; this page names the line. Each refusal
 * comes back as its gate's code plus a Thai sentence, and the banner links to the form that
 * fixes it (TC-59). Before the press, the same two views that name the lots (v_branch_diff,
 * v_smoke_group_available) raise the mirror banners — danger, then warning, then info, a fixed
 * order (S4). No gate is re-derived: the mirrors read columns the views computed.
 *
 * NO PRE-PRESS TIME BANNER (Finding 2): an L2 cannot read business_day_close_earliest.
 * CLOSE_TOO_EARLY names the time when it refuses.
 *
 * THE CONFIRM IS URL STATE (`?confirm=1`), lane G's CM 05 sheet. A double tap is the close's
 * replay of the first tap (close_idempotency_key), never a second close. */

const FIX: Record<string, { href: (q: string) => string; label: string }> = {
  DIFF_OVER_THRESHOLD: { href: (q) => `/branch/close?${q}`, label: "ไปตรวจยอดขาย" },
  READY_STOCK_NOT_ZERO: { href: (q) => `/branch/close?${q}#waste`, label: "ไปบันทึก Waste" },
  MATERIAL_COUNT_INCOMPLETE: { href: (q) => `/branch/count?${q}`, label: "ไปหน้าเช็ควัสดุ" },
  RICE_RECORD_MISSING: { href: (q) => `/branch/count?${q}`, label: "ไปบันทึกข้าวเย็น" },
};

export default async function BranchCloseConfirm(
  props: PageProps<"/branch/close/confirm">,
) {
  const params = await props.searchParams;
  const day = await loadBranchDay({
    location: one(params.location),
    date: one(params.date),
  });
  const branch = day.branch;
  if (!branch) return <NoBranch error={day.error} />;
  const report = day.report;

  const here = new URLSearchParams({ location: branch.id, date: day.date }).toString();
  const base = `/branch/close/confirm?${here}`;
  const err = one(params.err);
  const code = one(params.code);
  const needRemark = one(params.need_remark) === "1";
  const closedRaw = one(params.closed);
  const closedAt = Number.isNaN(Date.parse(closedRaw)) ? "" : closedRaw;

  const heading = (
    <>
      <BranchHeading
        title="ยืนยันปิดวัน"
        branches={day.branches}
        branch={branch}
        date={day.date}
        basePath="/branch/close/confirm"
      />
      <DateNavigator
        value={day.date}
        max={day.today}
        basePath="/branch/close/confirm"
        params={{ location: branch.id }}
      />
    </>
  );

  if (!report) {
    return (
      <div className="flex flex-col gap-4">
        {heading}
        <Notice tone="warning">
          วันที่ {thaiDate(day.date)} ยังไม่ได้เปิด — ไม่มีวันให้ปิด
        </Notice>
      </div>
    );
  }

  const [ready, diff, materials, rice, expenses] = await Promise.all([
    readReadyLots(day.supabase, branch.id),
    readDiff(day.supabase, branch.id, day.date),
    readMaterials(day.supabase, branch.id),
    readRiceDay(day.supabase, report.id),
    day.supabase
      .from("v_branch_expenses")
      .select("branch_expense_id", { count: "exact", head: true })
      .eq("daily_report_id", report.id),
  ]);
  const riceModel = rice.row?.model ?? branch.rice_model;
  const lots = largestFirst(ready.rows);
  const lotsText = lots
    .map((l) => `ล็อต ${l.lot_code} ${formatKg(l.available_qty)} กก.`)
    .join(", ");
  const alerts = materials.rows;
  const low = alerts.filter((a) => a.is_low === true).map((a) => a.name_th);
  const unknown = alerts.filter((a) => a.is_low === null).map((a) => a.name_th);

  const closed = report.status === "CLOSED";
  const confirming = one(params.confirm) === "1" && !closed;
  const fix = FIX[code];
  const overBand = diff.row?.verdict === "OVER_THRESHOLD";
  const key = crypto.randomUUID();

  return (
    <div className="flex flex-col gap-4">
      {heading}

      {closed ? (
        closedAt ? (
          <AlertBanner tone="success" title="ปิดวันแล้ว">
            ปิดเมื่อ {thaiDateTime(closedAt)} — รายการของวันนี้ถูกล็อกแล้ว
          </AlertBanner>
        ) : (
          <Notice tone="locked">
            วันที่ {thaiDate(day.date)} ปิดแล้ว — ถ้าต้องแก้ ต้องขอปลดล็อกจากเจ้าของร้าน
          </Notice>
        )
      ) : (
        <>
          {/* danger: the refusal the close just gave, then the mirrors. */}
          {err && !confirming ? (
            <AlertBanner tone="danger" title="ปิดวันไม่สำเร็จ">
              <p>{err}</p>
              {code === "DIFF_OVER_THRESHOLD" && lotsText ? (
                <p>ล็อตที่ยังมีเนื้อพร้อมขาย: {lotsText}</p>
              ) : null}
              {fix ? (
                <Link href={fix.href(here)} className="text-accent underline">
                  {fix.label}
                </Link>
              ) : null}
            </AlertBanner>
          ) : null}
          {overBand && code !== "DIFF_OVER_THRESHOLD" ? (
            <AlertBanner tone="danger" title="Diff เกินเกณฑ์ — ยังปิดวันไม่ได้">
              <p>
                ยังไม่มียอดขายหรือ Waste รองรับเนื้อ {formatKg(diff.row?.diff_kg)} กก.
                {lotsText ? ` — ตรวจยอดขายของ ${lotsText}` : ""}
              </p>
              <Link href={`/branch/close?${here}`} className="text-accent underline">
                ไปตรวจยอดขาย
              </Link>
            </AlertBanner>
          ) : null}
          {!overBand && lots.length > 0 && code !== "READY_STOCK_NOT_ZERO" ? (
            <AlertBanner tone="danger" title="ยังมีเนื้อพร้อมขายเหลือ">
              <p>{lotsText} — ชั่งแล้วบันทึกเป็น Waste ทีละล็อตก่อนปิดวัน</p>
              <Link href={`/branch/close?${here}#waste`} className="text-accent underline">
                ไปบันทึก Waste
              </Link>
            </AlertBanner>
          ) : null}
          {/* warning: materials. null is not configured or not counted, never "fine" (R9). */}
          {low.length > 0 || unknown.length > 0 ? (
            <AlertBanner tone="warning" title="วัสดุ">
              {low.length > 0 ? <p>ใกล้หมด: {low.join(", ")}</p> : null}
              {unknown.length > 0 ? (
                <p>ยังไม่ได้นับหรือยังไม่ตั้งค่า: {unknown.join(", ")}</p>
              ) : null}
            </AlertBanner>
          ) : null}
          {/* info */}
          <AlertBanner tone="info">
            ระบบตรวจเวลาเมื่อกดปิดวัน — ถ้ากดก่อนเวลาที่เจ้าของร้านตั้งไว้ ระบบจะบอกเวลาที่ปิดได้
          </AlertBanner>
        </>
      )}

      {ready.error || diff.error ? (
        <Notice tone="danger">อ่านข้อมูลของวันไม่สำเร็จ — {ready.error ?? diff.error}</Notice>
      ) : null}

      <dl className="rounded-lg border border-border bg-surface px-4 text-body-sm">
        {diff.row ? (
          <>
            <div className="flex justify-between gap-3 border-b border-border py-2">
              <dt className="text-text-secondary">ละลายพร้อมขาย</dt>
              <dd className="font-mono tabular-nums">{formatKg(diff.row.ready_in_kg)} กก.</dd>
            </div>
            <div className="flex justify-between gap-3 border-b border-border py-2">
              <dt className="text-text-secondary">ขาย {Number(diff.row.sold_pack_qty)} ซอง</dt>
              <dd className="font-mono tabular-nums">{formatKg(diff.row.sold_kg)} กก.</dd>
            </div>
            <div className="flex justify-between gap-3 border-b border-border py-2">
              <dt className="text-text-secondary">Waste</dt>
              <dd className="font-mono tabular-nums">{formatKg(diff.row.wasted_kg)} กก.</dd>
            </div>
            <div className="flex justify-between gap-3 border-b border-border py-2">
              <dt className="text-label">Diff</dt>
              <dd className="font-mono text-label tabular-nums">
                {formatKg(diff.row.diff_kg)} กก.
                {diff.row.variance_pct === null ? "" : ` · ${formatKg(diff.row.variance_pct)}%`}
              </dd>
            </div>
          </>
        ) : (
          <div className="border-b border-border py-2 text-text-secondary">
            วันนี้ไม่มีเนื้อพร้อมขายเข้าหรือออก
          </div>
        )}
        <div className="flex justify-between gap-3 border-b border-border py-2">
          <dt className="text-text-secondary">เนื้อพร้อมขายคงเหลือ</dt>
          <dd className="text-right">{lotsText || "ไม่มี"}</dd>
        </div>
        <div className="flex justify-between gap-3 border-b border-border py-2">
          <dt className="text-text-secondary">ข้าวเหนียวสุกคงเหลือ</dt>
          <dd className="text-right">
            {riceModel === null ? (
              "สาขานี้ยังไม่ได้ตั้งรูปแบบข้าว"
            ) : rice.row?.cooked_remaining_kg == null ? (
              <Link href={`/branch/count?${here}`} className="text-accent underline">
                ยังไม่บันทึก
              </Link>
            ) : (
              <span className="font-mono tabular-nums">
                {formatKg(rice.row.cooked_remaining_kg)} กก.
              </span>
            )}
          </dd>
        </div>
        <div className="flex justify-between gap-3 py-2">
          <dt className="text-text-secondary">ค่าใช้จ่ายสาขา</dt>
          <dd className="text-right">
            <Link href={`/branch/close?${here}#expense`} className="text-accent underline">
              {expenses.count ?? 0} รายการ
            </Link>
          </dd>
        </div>
      </dl>

      {closed ? null : (
        <BottomActionBar>
          <Link href={`${base}&confirm=1`} className={dangerButton}>
            ปิดวัน {thaiDate(day.date)}
          </Link>
        </BottomActionBar>
      )}

      {confirming ? (
        /* ConfirmDialog: a bottom sheet on a phone, a centred panel from md:. Cancel is a text
         * link, never the same size and colour as confirm. */
        <div className="fixed inset-0 z-30 flex items-end bg-text-primary/40 md:items-center md:justify-center">
          <div className="w-full max-w-xl p-2 pb-[calc(0.5rem+env(safe-area-inset-bottom))] md:p-0">
            <Sheet
              title={`ยืนยันปิดวัน ${thaiDate(day.date)}`}
              subtitle="ตรวจสรุปด้านหลังแล้วจึงยืนยัน"
              closeHref={base}
              closeLabel="ยกเลิก"
            >
              {err ? (
                <AlertBanner tone="danger" title="ปิดวันไม่สำเร็จ">
                  {err}
                </AlertBanner>
              ) : null}
              <ul className="flex list-disc flex-col gap-1 pl-5 text-body-sm text-text-primary">
                <li>ปิดแล้วรายการของวันนี้ถูกล็อก แก้ได้เฉพาะเมื่อเจ้าของร้านอนุมัติปลดล็อก</li>
                <li>
                  ระบบตรวจก่อนปิด: เวลา, Diff, เนื้อพร้อมขายต้องเหลือศูนย์, นับวัสดุครบ
                  และข้าวเหนียวคงเหลือตอนเย็น
                </li>
              </ul>
              <form action={submitClose} className="flex flex-col gap-3">
                <input type="hidden" name="idempotency_key" value={key} />
                <input type="hidden" name="daily_report_id" value={report.id} />
                <input type="hidden" name="back" value={base} />
                <ReasonField
                  label="หมายเหตุ"
                  name="remark"
                  required={needRemark}
                  trigger={
                    needRemark
                      ? "วันนี้ไม่มีเนื้อละลายเข้า แต่มียอดออก — ต้องเขียนหมายเหตุ"
                      : undefined
                  }
                  defaultValue={one(params.remark)}
                />
                <button type="submit" className={dangerButton}>
                  ยืนยันปิดวัน
                </button>
              </form>
            </Sheet>
          </div>
        </div>
      ) : null}
    </div>
  );
}
