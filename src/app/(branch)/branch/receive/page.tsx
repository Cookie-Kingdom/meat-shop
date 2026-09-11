import Link from "next/link";

import { actionLink, control, Field } from "@/components/ui/controls";
import { submitReceipt } from "@/features/branch/actions";
import { BranchHeading } from "@/features/branch/components/branch-heading";
import {
  CountField,
  ReasonField,
  WeightField,
} from "@/features/branch/components/fields";
import { NoBranch, Notice } from "@/features/branch/components/notice";
import { SubmitButton } from "@/features/branch/components/submit-button";
import { loadBranchDay } from "@/features/branch/context";
import { formatKg } from "@/features/branch/format";
import { Sheet } from "@/features/config/components/sheet";
import { thaiDate } from "@/lib/format/date";
import { one } from "@/lib/params";

/* BR 02 รับเนื้อเข้าสาขา — the branch signs for an allocation (card ^ref-41, PLAN T9, S1).
 *
 * A SCREEN OVER fn_confirm_transport_receipt, NOT A SECOND WRITER of a transport line. The
 * function's BRANCH arm goes through fn_require_branch, posts IN_TRANSIT -> FROZEN at this
 * branch, and decides the variance (weight past the dated threshold, or a bag count that does
 * not match — ^ref-35). THE SCREEN CANNOT DECIDE IT: the threshold is dated config that no
 * session may read. So the dispatched weight and bag count sit beside the inputs, and a
 * VARIANCE_REASON_REQUIRED refusal re-renders the form with the reason field required, above
 * the weight, and everything typed still in it (PLAN Finding 10, TDD TC-43).
 *
 * The receipt date defaults to the OPEN report's date, else today. It is the receipt's own date
 * (R44) and attaches to no report, so a branch may receive before it opens (PLAN Open Question
 * 1). A line already signed for with a shortfall stays outstanding for the Owner's settlement
 * (D06) and cannot be signed for twice (LINE_ALREADY_RECEIVED), so it is listed, not offered.
 *
 * Reads v_outstanding_receipts only: no money, own branch only (R34, TC-39/TC-40). */

type Line = {
  line_id: string;
  dispatch_date: string;
  lot_code: string;
  smoke_date: string | null;
  dispatched_weight_kg: number;
  received_weight_kg: number | null;
  outstanding_weight_kg: number;
  bag_count: number | null;
};

export default async function BranchReceive(
  props: PageProps<"/branch/receive">,
) {
  const params = await props.searchParams;
  const day = await loadBranchDay({ location: one(params.location), date: "" });
  const branch = day.branch;
  if (!branch) return <NoBranch error={day.error} />;

  const { data, error } = await day.supabase
    .from("v_outstanding_receipts")
    .select(
      "line_id, dispatch_date, lot_code, smoke_date, dispatched_weight_kg, received_weight_kg, outstanding_weight_kg, bag_count",
    )
    .eq("route", "CENTRAL_TO_BRANCH")
    .eq("to_location_id", branch.id)
    .order("dispatch_date")
    .order("lot_code");
  const lines = (data ?? []) as Line[];

  const key = crypto.randomUUID();
  const base = new URLSearchParams({ location: branch.id }).toString();
  const lineId = one(params.line);
  const line = lines.find(
    (l) => l.line_id === lineId && l.received_weight_kg === null,
  );
  const needReason = one(params.need_reason) === "1";
  const defaultDate = one(params.date) || (day.open?.report_date ?? day.today);
  const saved = one(params.saved);
  const err = one(params.err);

  return (
    <div className="flex flex-col gap-4">
      <BranchHeading
        title="รับเนื้อเข้าสาขา"
        branches={day.branches}
        branch={branch}
        date={defaultDate}
        basePath="/branch/receive"
      />
      <Link href={`/branch?${base}`} className={actionLink}>
        ‹ กลับไปงานวันนี้
      </Link>

      {saved === "receipt" ? (
        <Notice tone="success">รับเข้าสาขาแล้ว</Notice>
      ) : null}
      {err ? <Notice tone="danger">{err}</Notice> : null}
      {error ? (
        <Notice tone="danger">
          อ่านรายการค้างรับไม่สำเร็จ — {error.message}
        </Notice>
      ) : null}

      {line ? (
        <Sheet
          title={`รับล็อต ${line.lot_code}`}
          subtitle={
            line.smoke_date
              ? `รมควัน ${thaiDate(line.smoke_date)} · ส่งเมื่อ ${thaiDate(line.dispatch_date)}`
              : `ส่งเมื่อ ${thaiDate(line.dispatch_date)}`
          }
          closeHref={`/branch/receive?${base}`}
        >
          <dl className="grid grid-cols-2 gap-2 rounded-md bg-surface-sunken p-3">
            <div>
              <dt className="text-caption text-text-secondary">ยอดที่ส่งมา</dt>
              <dd className="text-num-md text-text-primary tabular-nums">
                {formatKg(line.dispatched_weight_kg)} กก.
              </dd>
            </div>
            <div>
              <dt className="text-caption text-text-secondary">
                จำนวนถุงที่ส่ง
              </dt>
              <dd className="text-num-md text-text-primary tabular-nums">
                {line.bag_count ?? "ไม่ได้นับ"}
                {line.bag_count ? " ถุง" : ""}
              </dd>
            </div>
          </dl>

          <form action={submitReceipt} className="flex flex-col gap-4">
            <input type="hidden" name="idempotency_key" value={key} />
            <input type="hidden" name="line_id" value={line.line_id} />
            <input
              type="hidden"
              name="back"
              value={`/branch/receive?${base}&line=${line.line_id}`}
            />
            {needReason ? (
              <ReasonField
                label="เหตุผลที่ไม่ตรง"
                name="variance_reason"
                required
                trigger="น้ำหนักหรือจำนวนถุงไม่ตรงกับที่ส่งมา — ต้องระบุเหตุผลก่อนรับเข้า"
                defaultValue={one(params.reason)}
              />
            ) : null}
            <WeightField
              label="น้ำหนักจริงที่รับ"
              name="received_weight_kg"
              defaultValue={one(params.w)}
              hint={`ส่งมา ${formatKg(line.dispatched_weight_kg)} กก. — รับไม่ครบก็บันทึกตามจริง`}
            />
            <CountField
              label="จำนวนถุงที่นับได้"
              name="received_bag_count"
              unit="ถุง"
              defaultValue={one(params.bags)}
              hint="เว้นว่างถ้าไม่ได้นับ"
            />
            <Field label="วันที่รับ">
              <input
                type="date"
                name="event_date"
                required
                defaultValue={defaultDate}
                max={day.today}
                className={control}
              />
            </Field>
            {needReason ? null : (
              <ReasonField
                label="เหตุผล (ถ้าน้ำหนักหรือจำนวนถุงไม่ตรง)"
                name="variance_reason"
                defaultValue={one(params.reason)}
              />
            )}
            <SubmitButton>ยืนยันรับเข้า</SubmitButton>
          </form>
        </Sheet>
      ) : null}

      <section aria-labelledby="br02-list" className="flex flex-col gap-2">
        <h2 id="br02-list" className="text-h3 text-text-primary">
          รายการค้างรับ
        </h2>
        {lines.length === 0 ? (
          <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
            ไม่มีของค้างรับ
          </p>
        ) : (
          <ul className="flex flex-col gap-2">
            {lines.map((l) => {
              const detail = (
                <span className="flex flex-col">
                  <span className="text-body text-text-primary">
                    ล็อต {l.lot_code}
                    {l.smoke_date ? ` · รมควัน ${thaiDate(l.smoke_date)}` : ""}
                  </span>
                  <span className="text-caption text-text-secondary tabular-nums">
                    ส่ง {formatKg(l.dispatched_weight_kg)} กก.
                    {l.bag_count ? ` · ${l.bag_count} ถุง` : ""} · ส่งเมื่อ{" "}
                    {thaiDate(l.dispatch_date)}
                  </span>
                  {l.received_weight_kg !== null ? (
                    <span className="text-caption text-warning tabular-nums">
                      รับแล้ว {formatKg(l.received_weight_kg)} กก. · ค้างบนรถ{" "}
                      {formatKg(l.outstanding_weight_kg)} กก. —
                      รอเจ้าของร้านสรุปส่วนต่าง
                    </span>
                  ) : null}
                </span>
              );
              return (
                <li key={l.line_id}>
                  {l.received_weight_kg === null ? (
                    <Link
                      href={`/branch/receive?${base}&line=${l.line_id}`}
                      className="flex min-h-14 items-center justify-between gap-3 rounded-lg border border-border bg-surface px-4 py-2 hover:bg-surface-sunken"
                    >
                      {detail}
                      <span aria-hidden className="text-h3 text-text-muted">
                        ›
                      </span>
                    </Link>
                  ) : (
                    <div className="flex min-h-14 items-center rounded-lg border border-border bg-surface-sunken px-4 py-2">
                      {detail}
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
