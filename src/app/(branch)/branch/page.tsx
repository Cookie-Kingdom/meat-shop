import Link from "next/link";

import { actionLink } from "@/components/ui/controls";
import { submitOpenDay } from "@/features/branch/actions";
import { BranchHeading } from "@/features/branch/components/branch-heading";
import {
  ChecklistBody,
  ChecklistItem,
  checklistItem,
} from "@/features/branch/components/checklist-item";
import { DateNavigator } from "@/features/branch/components/date-navigator";
import { NoBranch, Notice } from "@/features/branch/components/notice";
import { loadBranchDay, REPORT_STATUS_TH } from "@/features/branch/context";
import { formatKg } from "@/features/branch/format";
import { thaiDate, thaiDateTime } from "@/lib/format/date";
import { one } from "@/lib/params";

/* BR 01 งานวันนี้ — the branch's home screen (card ^ref-41, PLAN-thaw.md T9, skeleton S6).
 *
 * It dispatches; it does not submit — except the one item that IS an action, opening the day
 * (fn_open_daily_report). Every done mark is derived from a view, never from a tick:
 *   เปิดวัน           a report exists for the date            (v_daily_reports)
 *   รับเนื้อเข้าสาขา     no CENTRAL_TO_BRANCH line is outstanding (v_outstanding_receipts)
 *   แบ่งละลายเนื้อ       thawed_kg > 0 for the date               (v_daily_reports)
 * BR 03, BR 07, BR 08 and BR 09 render disabled until their cards land. BR 04 is not listed:
 * it is Phase 2 (v0.2:114).
 *
 * THE ROLE GATE IS NOT HERE. Every view carries its role test in its WHERE (R34); the (branch)
 * layout's requireRole is the mirror. The morning group is three items, so it sits above the
 * fold at 360px (S6's worst case). */

export default async function BranchToday(props: PageProps<"/branch">) {
  const params = await props.searchParams;
  const day = await loadBranchDay({
    location: one(params.location),
    date: one(params.date),
  });
  const branch = day.branch;
  if (!branch) return <NoBranch error={day.error} />;

  const { count: outstanding } = await day.supabase
    .from("v_outstanding_receipts")
    .select("line_id", { count: "exact", head: true })
    .eq("route", "CENTRAL_TO_BRANCH")
    .eq("to_location_id", branch.id);

  /* One key per page view (PLAN T8): a double tap on เปิดวัน is a replay, and the redirect after
   * it renders a fresh key. */
  const key = crypto.randomUUID();
  const report = day.report;
  const here = new URLSearchParams({ location: branch.id, date: day.date }).toString();
  const saved = one(params.saved);
  const err = one(params.err);

  return (
    <div className="flex flex-col gap-4">
      <BranchHeading
        title="งานวันนี้"
        branches={day.branches}
        branch={branch}
        date={day.date}
        basePath="/branch"
      />
      <DateNavigator
        value={day.date}
        max={day.today}
        basePath="/branch"
        params={{ location: branch.id }}
      />

      {saved === "open" ? <Notice tone="success">เปิดวันแล้ว</Notice> : null}
      {err ? <Notice tone="danger">{err}</Notice> : null}
      {day.open && day.open.report_date !== day.date ? (
        <Notice tone="warning">
          วันที่ {thaiDate(day.open.report_date)} ยังเปิดอยู่ —
          งานของกะที่เปิดอยู่บันทึกเข้าวันนั้น{" "}
          <Link
            href={`/branch?${new URLSearchParams({ location: branch.id, date: day.open.report_date })}`}
            className={actionLink}
          >
            ไปที่วันนั้น
          </Link>
        </Notice>
      ) : null}

      <div className="grid gap-4 md:grid-cols-3">
        <section aria-labelledby="br01-morning" className="flex flex-col gap-2">
          <h2 id="br01-morning" className="text-h3 text-text-primary">
            ช่วงเช้า
          </h2>
          {report ? (
            <ChecklistItem
              label="เปิดวัน"
              done
              detail={`${REPORT_STATUS_TH[report.status]} · เริ่มกะ ${thaiDateTime(report.shift_started_at)}`}
            />
          ) : (
            <form action={submitOpenDay}>
              <input type="hidden" name="idempotency_key" value={key} />
              <input type="hidden" name="location_id" value={branch.id} />
              <input type="hidden" name="report_date" value={day.date} />
              <input type="hidden" name="back" value={`/branch?${here}`} />
              <button type="submit" className={checklistItem({ state: "todo" })}>
                <ChecklistBody
                  state="todo"
                  label={`เปิดวัน ${thaiDate(day.date)}`}
                  detail="กดเพื่อเริ่มกะ — ต้องเปิดวันก่อนจึงจะบันทึกงานของสาขาได้"
                  chevron
                />
              </button>
            </form>
          )}
          <ChecklistItem
            label="รับเนื้อเข้าสาขา"
            href={`/branch/receive?${here}`}
            done={outstanding === 0}
            detail={
              outstanding === null
                ? "อ่านรายการค้างรับไม่สำเร็จ"
                : outstanding > 0
                  ? `รอรับ ${outstanding} รายการ`
                  : "ไม่มีของค้างรับ"
            }
          />
          <ChecklistItem
            label="ข้าวเหนียวช่วงเช้า"
            disabled
            detail="ยังไม่เปิดใช้งาน"
          />
        </section>

        <section aria-labelledby="br01-during" className="flex flex-col gap-2">
          <h2 id="br01-during" className="text-h3 text-text-primary">
            ระหว่างวัน
          </h2>
          <ChecklistItem
            label="แบ่งละลายเนื้อ"
            href={`/branch/thaw?${here}`}
            done={Boolean(report) && Number(report?.thawed_kg) > 0}
            blocked={report ? undefined : "เปิดวันก่อน"}
            detail={
              report && Number(report.thawed_kg) > 0
                ? `ละลายแล้ว ${formatKg(report.thawed_kg)} กก.`
                : "ยังไม่ได้ละลาย"
            }
          />
        </section>

        <section aria-labelledby="br01-close" className="flex flex-col gap-2">
          <h2 id="br01-close" className="text-h3 text-text-primary">
            ปิดวัน
          </h2>
          <ChecklistItem label="ปิดยอดรายวัน" disabled detail="ยังไม่เปิดใช้งาน" />
          <ChecklistItem label="เช็ควัสดุ" disabled detail="ยังไม่เปิดใช้งาน" />
          <ChecklistItem label="ยืนยันปิดวัน" disabled detail="ยังไม่เปิดใช้งาน" />
        </section>
      </div>
    </div>
  );
}
