import Link from "next/link";

import { actionLink } from "@/components/ui/controls";
import { ClosedDayNotice } from "@/features/branch-close/components/closed-day-notice";
import { BranchHeading } from "@/features/branch/components/branch-heading";
import { DateNavigator } from "@/features/branch/components/date-navigator";
import { NoBranch, Notice } from "@/features/branch/components/notice";
import { SubmitButton } from "@/features/branch/components/submit-button";
import { loadBranchDay } from "@/features/branch/context";
import { submitCount } from "@/features/materials/actions";
import { KgField, WholeInput } from "@/features/materials/components/fields";
import { MaterialCountRow } from "@/features/materials/components/material-count-row";
import {
  asField,
  readMaterials,
  readRiceDay,
} from "@/features/materials/queries";
import { thaiDate } from "@/lib/format/date";
import { one } from "@/lib/params";
import { ReadError } from "@/components/shared/read-error";

/* BR 08 เช็ควัสดุ — the card's "one phone screen" (card ^ref-52, PLAN-material-screens.md
 * Findings 1–5; skeleton S5). Three kinds of count on it:
 *   the materials   every active item at the branch, from v_material_alerts, never a constant 7
 *   chilli paste    whole 30 g tubes (BR21)
 *   evening rice    cooked_remaining_kg, and raw_remaining_kg at a SELF_COOK branch
 *
 * ONE SUBMIT, TWO RPCs, TWO KEYS (Finding 2). Rice cannot be a physical count (COUNT_ITEM_INVALID:
 * its balance is rice_records), so the action calls fn_record_physical_count, then fn_record_rice.
 * Both keys are minted once per page view and ride back in the URL on a refusal:
 *   the count refused → nothing written, both keys still unused;
 *   the count saved, the rice refused → the page returns with `count_saved=1`, the counts
 *   READ-ONLY, and re-sends them under the same key (a replay writes nothing, R4) while the rice
 *   retries under its own unused key. A saved count is never editable on the same page view,
 *   so an edit cannot hide behind a replay. A recount on a fresh view appends (v0.2:253).
 *
 * BLIND (Finding 3). No system figure shows before the count. After the save, chilli shows
 * counted, system and variance from v_count_variance (M6: 88 in the system, 87 on the shelf → −1),
 * and each material shows the view's state for today's count. An empty field is not counted,
 * never 0 (Finding 5). Whether the day's counts are complete is fn_close_daily_report's call. */

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function BranchCount(props: PageProps<"/branch/count">) {
  const params = await props.searchParams;
  const day = await loadBranchDay({
    location: one(params.location),
    date: one(params.date),
  });
  const branch = day.branch;
  if (!branch) return <NoBranch error={day.error} />;
  const report = day.report;
  const here = new URLSearchParams({
    location: branch.id,
    date: day.date,
  }).toString();

  const heading = (
    <>
      <BranchHeading
        title="เช็ควัสดุ"
        branches={day.branches}
        branch={branch}
        date={day.date}
        basePath="/branch/count"
      />
      <DateNavigator
        value={day.date}
        max={day.today}
        basePath="/branch/count"
        params={{ location: branch.id }}
      />
    </>
  );

  if (!report) {
    return (
      <div className="flex flex-col gap-4">
        {heading}
        <Notice tone="warning">
          วันที่ {thaiDate(day.date)} ยังไม่ได้เปิด —{" "}
          <Link href={`/branch?${here}`} className={actionLink}>
            เปิดวันก่อน
          </Link>
        </Notice>
      </div>
    );
  }

  const [materials, rice, chilliRes] = await Promise.all([
    readMaterials(day.supabase, branch.id),
    readRiceDay(day.supabase, report.id),
    day.supabase
      .from("v_count_variance")
      .select("counted_qty, system_qty, variance_qty")
      .eq("daily_report_id", report.id)
      .eq("item_type", "CHILLI_PASTE")
      .order("counted_at", { ascending: false })
      .limit(1),
  ]);
  const rows = materials.rows;
  const allUnset =
    rows.length > 0 && rows.every((r) => r.full_stock_qty === null);
  const model = rice.row?.model ?? branch.rice_model;
  const chilli = (chilliRes.data?.[0] ?? null) as {
    counted_qty: number;
    system_qty: number;
    variance_qty: number;
  } | null;

  const countSaved = one(params.count_saved) === "1";
  const reuse = (k: string) => (UUID.test(k) ? k : crypto.randomUUID());
  const countKey = reuse(one(params.count_key));
  const riceKey = reuse(one(params.rice_key));
  const kept = (name: string) => one(params[name]);
  const saved = one(params.saved) === "count";
  const err = one(params.err);

  return (
    <div className="flex flex-col gap-4">
      {heading}

      {saved ? <Notice tone="success">บันทึกยอดนับแล้ว</Notice> : null}
      {err ? <Notice tone="danger">{err}</Notice> : null}
      {countSaved ? (
        <Notice tone="warning">
          บันทึกยอดนับวัสดุและน้ำพริกแล้ว แต่ข้าวยังไม่ได้บันทึก —
          แก้ช่องข้าวแล้วกดบันทึกอีกครั้ง ยอดนับจะไม่ถูกบันทึกซ้ำ
        </Notice>
      ) : null}
      {materials.error || rice.error ? (
        <ReadError
          title="อ่านข้อมูลไม่สำเร็จ"
          raw={materials.error ?? rice.error}
        />
      ) : null}
      {report.status === "CLOSED" ? (
        <ClosedDayNotice
          db={day.supabase}
          reportId={report.id}
          date={day.date}
        />
      ) : null}

      <form action={submitCount} className="flex flex-col gap-4">
        <input type="hidden" name="count_key" value={countKey} />
        <input type="hidden" name="rice_key" value={riceKey} />
        <input type="hidden" name="daily_report_id" value={report.id} />
        <input type="hidden" name="back" value={`/branch/count?${here}`} />
        {countSaved ? (
          <input type="hidden" name="count_saved" value="1" />
        ) : null}

        <section
          aria-labelledby="br08-materials"
          className="flex flex-col gap-2"
        >
          <h2 id="br08-materials" className="text-h3 text-text-primary">
            วัสดุ {rows.length} รายการ
          </h2>
          {allUnset ? (
            <Notice tone="warning">
              เจ้าของร้านยังไม่ได้ตั้งสต็อกเต็มของวัสดุ — นับได้
              แต่ระบบยังเตือนของใกล้หมดไม่ได้
            </Notice>
          ) : null}
          {rows.length === 0 ? (
            <p className="rounded-lg border border-border bg-surface-sunken p-4 text-body-sm text-text-secondary">
              ยังไม่มีรายการวัสดุในระบบ — แจ้งเจ้าของร้าน
            </p>
          ) : (
            <div className="rounded-lg border border-border bg-surface">
              {rows.map((r) => (
                <MaterialCountRow
                  key={r.packaging_item_id}
                  row={r}
                  name={`pkg:${r.packaging_item_id}`}
                  defaultValue={kept(`pkg:${r.packaging_item_id}`)}
                  readOnly={countSaved}
                  countedToday={!countSaved && r.counted_on === day.date}
                  showNotConfigured={!allUnset}
                />
              ))}
            </div>
          )}
        </section>

        <section
          aria-labelledby="br08-chilli"
          className="flex flex-col gap-2 rounded-lg border border-border bg-surface p-4"
        >
          <h2 id="br08-chilli" className="text-h3 text-text-primary">
            น้ำพริก หลอด 30 กรัม
          </h2>
          <WholeInput
            label="ยอดนับน้ำพริก"
            name="chilli"
            unit="หลอด"
            defaultValue={kept("chilli")}
            readOnly={countSaved}
          />
          {chilli && !countSaved ? (
            <p className="text-body-sm text-text-secondary tabular-nums">
              นับล่าสุด {Number(chilli.counted_qty)} หลอด · ในระบบ{" "}
              {Number(chilli.system_qty)} หลอด · ต่าง{" "}
              {Number(chilli.variance_qty) > 0 ? "+" : ""}
              {Number(chilli.variance_qty)} หลอด
            </p>
          ) : null}
        </section>

        <section
          aria-labelledby="br08-rice"
          className="flex flex-col gap-3 rounded-lg border border-border bg-surface p-4"
        >
          <h2 id="br08-rice" className="text-h3 text-text-primary">
            ข้าวเหนียวตอนเย็น
          </h2>
          {model === null ? (
            <Notice tone="warning">
              เจ้าของร้านยังไม่ได้ตั้งรูปแบบข้าวเหนียวของสาขานี้ —
              แจ้งเจ้าของร้านก่อน
            </Notice>
          ) : (
            <>
              <KgField
                label="ข้าวสุกคงเหลือ"
                name="cooked_remaining_kg"
                defaultValue={
                  kept("cooked_remaining_kg") ||
                  asField(rice.row?.cooked_remaining_kg)
                }
                hint="พรุ่งนี้ยกยอดจากตัวเลขนี้"
              />
              {model === "SELF_COOK" ? (
                <KgField
                  label="ข้าวดิบคงเหลือ"
                  name="raw_remaining_kg"
                  defaultValue={
                    kept("raw_remaining_kg") ||
                    asField(rice.row?.raw_remaining_kg)
                  }
                />
              ) : null}
            </>
          )}
        </section>

        <p className="text-caption text-text-muted">
          ช่องที่เว้นว่าง = ยังไม่ได้นับ ไม่ใช่ศูนย์ —
          ต้องนับวัสดุครบทุกรายการก่อนปิดวัน
        </p>
        <SubmitButton>บันทึกยอดนับ</SubmitButton>
      </form>
    </div>
  );
}
