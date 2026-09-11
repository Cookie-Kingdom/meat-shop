import Link from "next/link";

import { actionLink } from "@/components/ui/controls";
import { ClosedDayNotice } from "@/features/branch-close/components/closed-day-notice";
import { BranchHeading } from "@/features/branch/components/branch-heading";
import { DateNavigator } from "@/features/branch/components/date-navigator";
import { NoBranch, Notice } from "@/features/branch/components/notice";
import { SubmitButton } from "@/features/branch/components/submit-button";
import { loadBranchDay } from "@/features/branch/context";
import { formatKg } from "@/features/branch/format";
import { submitRice } from "@/features/materials/actions";
import { KgField } from "@/features/materials/components/fields";
import { asField, readRiceDay } from "@/features/materials/queries";
import { thaiDate } from "@/lib/format/date";
import { one } from "@/lib/params";
import { ReadError } from "@/components/shared/read-error";

/* BR 03 ข้าวเหนียวช่วงเช้า — the morning half of the day's rice (card ^ref-52,
 * PLAN-material-screens.md Findings 6–7; skeleton S1, M7).
 *
 * THE CARRY-IN COMES FIRST, before anything is typed (v0.2:90 "แสดงยอดยกมาจากเมื่อวาน"). It is
 * v_rice_day's carried_in_cooked_kg: null reads ยังไม่มีข้อมูล, never 0.00.
 *
 * THE FORM FOLLOWS THE MODEL: the row's snapshot once a row exists, else the branch's (R29).
 *   EXTERNAL_COOKED (มีนบุรี)  ข้าวสุกที่รับ
 *   SELF_COOK (ศาลาแดง)        หุงวันนี้, ข้าวดิบคงเหลือ, and ข้าวดิบที่ซื้อเพิ่ม when bought
 * No model: RICE_MODEL_NOT_SET as a notice, and no form. The evening figure is BR 08's. Each
 * visit sends only its own fields and fn_record_rice merges them, so a saved value re-fills its
 * field and can be corrected but not cleared. */

export default async function BranchRice(props: PageProps<"/branch/rice">) {
  const params = await props.searchParams;
  const day = await loadBranchDay({
    location: one(params.location),
    date: one(params.date),
  });
  const branch = day.branch;
  if (!branch) return <NoBranch error={day.error} />;
  const report = day.report;

  const rice = report
    ? await readRiceDay(day.supabase, report.id)
    : { row: null, error: null };
  const row = rice.row;
  const model = row?.model ?? branch.rice_model;
  const here = new URLSearchParams({
    location: branch.id,
    date: day.date,
  }).toString();
  const err = one(params.err);
  const value = (name: keyof NonNullable<typeof row>) =>
    one(params[name]) || asField(row?.[name] as number | null | undefined);
  const key = crypto.randomUUID();

  return (
    <div className="flex flex-col gap-4">
      <BranchHeading
        title="ข้าวเหนียวช่วงเช้า"
        branches={day.branches}
        branch={branch}
        date={day.date}
        basePath="/branch/rice"
      />
      <DateNavigator
        value={day.date}
        max={day.today}
        basePath="/branch/rice"
        params={{ location: branch.id }}
      />

      {one(params.saved) === "rice" ? (
        <Notice tone="success">บันทึกข้าวเหนียวแล้ว</Notice>
      ) : null}
      {err ? <Notice tone="danger">{err}</Notice> : null}
      {rice.error ? (
        <ReadError title="อ่านข้อมูลข้าวไม่สำเร็จ" raw={rice.error} />
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
          {report.status === "CLOSED" ? (
            <ClosedDayNotice
              db={day.supabase}
              reportId={report.id}
              date={day.date}
            />
          ) : null}

          <section className="flex items-baseline justify-between gap-3 rounded-lg border border-border bg-surface p-4">
            <span className="text-label text-text-secondary">
              ข้าวสุกยกมาจากวันก่อน
            </span>
            <span className="font-mono text-num-md text-text-primary tabular-nums">
              {row?.carried_in_cooked_kg == null
                ? "ยังไม่มีข้อมูล"
                : `${formatKg(row.carried_in_cooked_kg)} กก.`}
            </span>
          </section>

          {model === null ? (
            <Notice tone="warning">
              เจ้าของร้านยังไม่ได้ตั้งรูปแบบข้าวเหนียวของสาขานี้ —
              แจ้งเจ้าของร้านก่อน จึงบันทึกข้าวได้
            </Notice>
          ) : (
            <form
              action={submitRice}
              className="flex flex-col gap-4 rounded-lg border border-border bg-surface p-4"
            >
              <input type="hidden" name="idempotency_key" value={key} />
              <input type="hidden" name="daily_report_id" value={report.id} />
              <input type="hidden" name="back" value={`/branch/rice?${here}`} />
              {model === "EXTERNAL_COOKED" ? (
                <KgField
                  label="ข้าวสุกที่รับ"
                  name="cooked_received_kg"
                  defaultValue={value("cooked_received_kg")}
                />
              ) : (
                <>
                  <KgField
                    label="หุงวันนี้"
                    name="cooked_today_kg"
                    defaultValue={value("cooked_today_kg")}
                  />
                  <KgField
                    label="ข้าวดิบคงเหลือ"
                    name="raw_remaining_kg"
                    defaultValue={value("raw_remaining_kg")}
                  />
                  <KgField
                    label="ข้าวดิบที่ซื้อเพิ่ม"
                    name="raw_purchased_kg"
                    defaultValue={value("raw_purchased_kg")}
                    hint="เว้นว่างถ้าวันนี้ไม่ได้ซื้อ"
                  />
                </>
              )}
              <p className="text-caption text-text-muted">
                ข้าวสุกคงเหลือตอนเย็นบันทึกที่หน้าเช็ควัสดุ —
                ช่องที่เว้นว่างไม่ถูกบันทึก
              </p>
              <SubmitButton>บันทึกข้าวเหนียว</SubmitButton>
            </form>
          )}
        </>
      )}
    </div>
  );
}
