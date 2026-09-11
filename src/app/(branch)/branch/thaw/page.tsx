import Link from "next/link";

import { actionLink } from "@/components/ui/controls";
import { submitThaw } from "@/features/branch/actions";
import { BranchHeading } from "@/features/branch/components/branch-heading";
import { DateNavigator } from "@/features/branch/components/date-navigator";
import { ReasonField, WeightField } from "@/features/branch/components/fields";
import { NoBranch, Notice } from "@/features/branch/components/notice";
import { SmokeDateChip } from "@/features/branch/components/smoke-date-chip";
import { StockStateBadge } from "@/features/branch/components/stock-state-badge";
import { SubmitButton } from "@/features/branch/components/submit-button";
import { loadBranchDay } from "@/features/branch/context";
import { thaiDate } from "@/lib/format/date";
import { one } from "@/lib/params";

/* BR 05 แบ่งละลายเนื้อ — FROZEN -> READY against a named lot (card ^ref-41, PLAN T9, S2).
 *
 * THE PICKER READS v_branch_frozen_available, the view fn_record_thaw asserts against, so the
 * screen never offers meat still on the truck or already thawed (PLAN Finding 4, Seam 3).
 *
 * FIFO IS BY DATE (Finding 3). One chip per smoke date, oldest first and marked เก่าที่สุด; the
 * oldest is the default pick. A later date brings up the reason field and the line that the
 * Owner will be told. A second lot inside the oldest date does NOT — it is a choice, not an
 * override. The screen mirrors the rule; fn_record_thaw decides it (FIFO_REASON_REQUIRED).
 *
 * ONE LOT PER SUBMIT, deliberately. The contract is one call per lot; a multi-lot thaw is two
 * submits, with the pinned region refreshed between them.
 *
 * AFTER A SUBMIT the page redirects with the lot and group, and the pinned region re-reads the
 * ledger's balances for that tuple — a refetch, never an optimistic decrement — and shows TWO
 * badges, frozen and ready, never one summed figure (BR19, TDD TC-44).
 *
 * Needs a report for the date. None: link back to BR 01. A CLOSED day keeps the form, under a
 * locked notice: ^ref-08 admits a correction by an APPROVED, unexpired unlock_requests row and
 * leaves the day CLOSED (ref-08-unlock/PLAN-unlock.md Finding 1). Lane C's trigger reads that
 * approval at write time (R42). This screen cannot see the approval, so it does not guess:
 * without one, REPORT_CLOSED comes back as a Thai sentence and nothing is written.
 */

type FrozenRow = {
  smoke_date: string;
  smoke_date_group_id: string;
  lot_id: string;
  lot_code: string;
  available_qty: number;
};

type TupleRow = {
  stock_state: "IN_TRANSIT" | "FROZEN" | "READY";
  available_qty: number;
  lot_code: string;
};

export default async function BranchThaw(props: PageProps<"/branch/thaw">) {
  const params = await props.searchParams;
  const day = await loadBranchDay({
    location: one(params.location),
    date: one(params.date),
  });
  const branch = day.branch;
  if (!branch) return <NoBranch error={day.error} />;
  const report = day.report;

  const done = one(params.done) === "1" && one(params.lot) && one(params.group);
  const [frozenRes, tupleRes] = await Promise.all([
    day.supabase
      .from("v_branch_frozen_available")
      .select(
        "smoke_date, smoke_date_group_id, lot_id, lot_code, available_qty",
      )
      .eq("location_id", branch.id)
      .order("smoke_date")
      .order("lot_code"),
    done
      ? day.supabase
          .from("v_smoke_group_available")
          .select("stock_state, available_qty, lot_code")
          .eq("location_id", branch.id)
          .eq("lot_id", one(params.lot))
          .eq("smoke_date_group_id", one(params.group))
      : null,
  ]);
  const rows = (frozenRes.data ?? []) as FrozenRow[];
  const tuple = (tupleRes?.data ?? []) as TupleRow[];

  const dates = [...new Set(rows.map((r) => r.smoke_date))]; // the view's order: oldest first
  const oldest = dates[0] ?? null;
  const pick = one(params.pick);
  const picked = rows.find(
    (r) => `${r.lot_id}:${r.smoke_date_group_id}` === pick,
  );
  const sd = one(params.sd);
  const selected = dates.includes(sd) ? sd : (picked?.smoke_date ?? oldest);
  const lots = rows.filter((r) => r.smoke_date === selected);
  const override = selected !== null && oldest !== null && selected > oldest;

  const key = crypto.randomUUID();
  const here = { location: branch.id, date: day.date };
  const qs = (extra: Record<string, string>) =>
    new URLSearchParams({ ...here, ...extra }).toString();
  const err = one(params.err);

  // Absent from the view means a zero balance (it offers positive balances only).
  const frozenNow =
    tuple.find((t) => t.stock_state === "FROZEN")?.available_qty ?? 0;
  const readyNow =
    tuple.find((t) => t.stock_state === "READY")?.available_qty ?? 0;
  const lotCode = tuple[0]?.lot_code;

  return (
    <div className="flex flex-col gap-4">
      <BranchHeading
        title="แบ่งละลายเนื้อ"
        branches={day.branches}
        branch={branch}
        date={day.date}
        basePath="/branch/thaw"
      />
      <DateNavigator
        value={day.date}
        max={day.today}
        basePath="/branch/thaw"
        params={{ location: branch.id }}
      />

      {done ? (
        <section
          aria-live="polite"
          className="flex flex-col gap-2 rounded-lg border border-success bg-surface p-3"
        >
          <p className="text-body text-text-primary">
            ละลาย {one(params.kg)} กก.{lotCode ? ` จากล็อต ${lotCode}` : ""}{" "}
            แล้ว — ยอดของล็อตนี้ตอนนี้
          </p>
          <div className="flex flex-wrap gap-2">
            <StockStateBadge state="frozen" weightKg={frozenNow} />
            <StockStateBadge state="ready" weightKg={readyNow} />
          </div>
        </section>
      ) : null}
      {err ? <Notice tone="danger">{err}</Notice> : null}
      {frozenRes.error ? (
        <Notice tone="danger">
          อ่านสต็อกแช่แข็งไม่สำเร็จ — {frozenRes.error.message}
        </Notice>
      ) : null}

      {report?.status === "CLOSED" ? (
        <Notice tone="locked">
          วันที่ {thaiDate(day.date)} ปิดแล้ว —
          บันทึกได้เฉพาะเมื่อเจ้าของร้านอนุมัติปลดล็อกวันนี้ และยังไม่หมดเวลา
          ถ้ายังไม่ได้อนุมัติ ระบบจะไม่รับรายการ
        </Notice>
      ) : null}
      {!report ? (
        <Notice tone="warning">
          วันที่ {thaiDate(day.date)} ยังไม่ได้เปิด —{" "}
          <Link href={`/branch?${qs({})}`} className={actionLink}>
            เปิดวันก่อน
          </Link>
        </Notice>
      ) : rows.length === 0 ? (
        <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
          ไม่มีเนื้อแช่แข็งในสาขานี้
        </p>
      ) : (
        <form action={submitThaw} className="flex flex-col gap-4">
          <input type="hidden" name="idempotency_key" value={key} />
          <input type="hidden" name="daily_report_id" value={report.id} />
          <input
            type="hidden"
            name="back"
            value={`/branch/thaw?${qs(selected ? { sd: selected } : {})}`}
          />

          <fieldset className="flex flex-col gap-2">
            <legend className="mb-2 text-label text-text-secondary">
              เลือกวันรมควัน (เก่าที่สุดก่อนตาม FIFO)
            </legend>
            {dates.map((d) => {
              const inDate = rows.filter((r) => r.smoke_date === d);
              return (
                <SmokeDateChip
                  key={d}
                  smokeDate={d}
                  lotCount={inDate.length}
                  singleLotKg={
                    inDate.length === 1 ? inDate[0].available_qty : null
                  }
                  isOldest={d === oldest}
                  selected={d === selected}
                  href={`/branch/thaw?${qs({ sd: d })}`}
                />
              );
            })}
          </fieldset>

          <fieldset className="flex flex-col gap-2">
            <legend className="mb-2 text-label text-text-secondary">
              เลือกล็อต ({selected ? `รมควัน ${thaiDate(selected)}` : ""})
            </legend>
            {/* The one internal scroll region (S2): --scroll-cap, 230px = 4 rows of 56px. */}
            <div className="max-h-[230px] overflow-y-auto rounded-lg border border-border bg-surface">
              {lots.map((r) => {
                const value = `${r.lot_id}:${r.smoke_date_group_id}`;
                return (
                  <label
                    key={value}
                    className="flex min-h-14 items-center gap-3 border-b border-border px-4 py-2 last:border-b-0"
                  >
                    <input
                      type="radio"
                      name="pick"
                      value={value}
                      required
                      defaultChecked={lots.length === 1 || value === pick}
                      className="size-5 shrink-0"
                    />
                    <span className="flex flex-1 flex-col">
                      <span className="text-body text-text-primary">
                        ล็อต {r.lot_code}
                      </span>
                      <span className="text-caption text-text-muted">
                        รมควัน {thaiDate(r.smoke_date)}
                      </span>
                    </span>
                    <StockStateBadge
                      state="frozen"
                      weightKg={r.available_qty}
                      size="sm"
                    />
                  </label>
                );
              })}
            </div>
            <p className="text-caption text-text-muted">
              เห็น {lots.length} ล็อตในวันนี้ — ละลายครั้งละหนึ่งล็อต
            </p>
          </fieldset>

          {override ? (
            <ReasonField
              label="เหตุผลที่ข้ามวันเก่ากว่า"
              name="fifo_override_reason"
              required
              trigger="ข้ามวันที่เก่ากว่า — ต้องระบุเหตุผล และระบบจะแจ้งเจ้าของร้าน"
              defaultValue={one(params.reason)}
            />
          ) : null}

          <WeightField
            label="น้ำหนักที่ละลายจริง"
            name="thawed_weight_kg"
            defaultValue={one(params.w)}
            hint="ละลายบางส่วนได้ ส่วนที่เหลือยังแช่แข็งอยู่ในล็อตเดิม"
          />

          <SubmitButton>บันทึกการละลาย</SubmitButton>
        </form>
      )}
    </div>
  );
}
