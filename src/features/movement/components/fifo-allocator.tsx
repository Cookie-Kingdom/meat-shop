"use client";

import { useActionState, useState } from "react";

import { control, Field } from "@/components/ui/controls";
import { thaiDate } from "@/lib/format/date";
import { kg, parseKg, toHundredths } from "@/lib/format/weight";
import { cn } from "@/lib/utils";
import { submitAllocation } from "../actions";
import type { ActionState, Branch, CentralAvailableRow } from "../types";
import { ActionBar, primaryAction } from "./action-bar";
import { CountField } from "./count-field";
import { ReasonField } from "./reason-field";
import { WeightField } from "./weight-field";

/* FifoAllocator (DESIGN-CONTRACTS.md) — OW 07, skeleton S2. It sends part of central stock to
 * one branch, by weight and by bag count, through fn_allocate_to_branch (BR11, BR07,
 * v0.2:108).
 *
 * THE PICKER IS v_central_available AND NOTHING ELSE. It holds FROZEN meat at central and no
 * other state or place, so a lot still on the return truck is not in the list at all (BR11).
 * There is no "from" field: the function takes the origin from the same view. That is the
 * card's acceptance line as a property of the call, not of this screen (ADR-004).
 *
 * FIFO IS BY SMOKE DATE, AND THE LOT INSIDE THE DATE IS A CHOICE (v0.2:184, :188, :329). The
 * oldest date is proposed and pre-selected. Any lot on that date is a FIFO pick, with no
 * reason. A lot on a later date is an override: ReasonField appears, required, directly under
 * the picker that triggered it. The function decides (FIFO_OVERRIDE_REASON_REQUIRED). This
 * mirrors it on the tap.
 *
 * OVER-AVAILABLE IS THE ONE HARD STOP (contract, BR24). A weight above the lot's central
 * balance disables submit, and INSUFFICIENT_CENTRAL_STOCK refuses it again server-side.
 *
 * THE PINNED BALANCE IS REFETCHED, NEVER DECREMENTED (LAYOUT-SKELETONS.md S2, TC-41). After a
 * submit, the action revalidates the route, `rows` arrives fresh from the ledger, and the
 * picked group, branch and date stay put, so the next branch's share is one weight away. */

const idle: ActionState = { status: "idle" };

export function FifoAllocator({
  rows,
  branches,
  idempotencyKey,
  today,
}: {
  rows: CentralAvailableRow[];
  branches: Branch[];
  idempotencyKey: string;
  today: string;
}) {
  const [groupId, setGroupId] = useState(rows[0]?.smoke_date_group_id ?? "");
  const [branchId, setBranchId] = useState("");
  const [eventDate, setEventDate] = useState(today);
  const [weight, setWeight] = useState("");
  const [bags, setBags] = useState("");
  const [reason, setReason] = useState("");

  const [state, formAction, pending] = useActionState(
    async (prev: ActionState, form: FormData) => {
      const next = await submitAllocation(prev, form);
      if (next.status === "ok") {
        // The quantities belong to the allocation just made; the pick, branch and date do not.
        setWeight("");
        setBags("");
        setReason("");
      }
      return next;
    },
    idle,
  );

  // A group emptied by the last allocation drops out of the refetched rows; fall back to the
  // proposal rather than holding an id the view no longer offers.
  const selected =
    rows.find((r) => r.smoke_date_group_id === groupId) ?? rows[0];
  const oldest = rows.reduce(
    (m, r) => (r.smoke_date < m ? r.smoke_date : m),
    rows[0]?.smoke_date ?? "",
  );
  const isOverride = selected !== undefined && selected.smoke_date > oldest;

  const totalH = rows.reduce((s, r) => s + toHundredths(r.available_qty), 0);
  const actual = parseKg(weight);
  const overAvailable =
    actual !== null &&
    selected !== undefined &&
    toHundredths(actual) > toHundredths(selected.available_qty);
  const branchName = branches.find((b) => b.id === branchId)?.name_th ?? "";

  const pick = (row: CentralAvailableRow) => {
    setGroupId(row.smoke_date_group_id);
    if (row.smoke_date <= oldest) setReason(""); // back on FIFO: the reason no longer applies
  };

  return (
    <form action={formAction} className="flex flex-col gap-4">
      <input type="hidden" name="idempotency_key" value={idempotencyKey} />
      <input type="hidden" name="branch_name" value={branchName} />

      {state.status === "ok" ? (
        <p
          role="status"
          className="rounded-lg border border-success bg-success-subtle p-3 text-body-sm text-success"
        >
          {state.message}
        </p>
      ) : null}
      {state.status === "error" ? (
        <p
          role="alert"
          className="rounded-lg border border-danger bg-danger-subtle p-3 text-body-sm text-danger"
        >
          {state.message}
        </p>
      ) : null}

      {/* PINNED above the region, outside its scroll: the central balance, from the ledger. */}
      <section
        aria-label="ยอดคลังกลาง"
        className="flex flex-col gap-1 rounded-lg border border-border bg-surface p-4"
      >
        <span className="flex items-baseline justify-between gap-2">
          <span className="text-body-sm text-text-secondary">คงเหลือในคลังกลาง</span>
          <span className="text-num-md text-text-primary tabular-nums">
            {kg(totalH / 100)} กก.
          </span>
        </span>
        {selected ? (
          <span className="flex items-baseline justify-between gap-2 text-body-sm">
            <span className="text-text-secondary">
              Lot {selected.lot_code} · รมควัน {thaiDate(selected.smoke_date)}
            </span>
            <span className="text-label text-text-primary tabular-nums">
              เหลือ {kg(selected.available_qty)} กก.
            </span>
          </span>
        ) : null}
      </section>

      {/* THE ONE INTERNAL SCROLL REGION — capped at 230px (S2's `--scroll-cap`, four 56px rows,
          not yet a token), taller from md:, uncapped at lg:. Oldest date first; each lot on a
          date is its own row, because the date does not identify the lot (D01, ADR-017). */}
      <fieldset className="flex min-w-0 flex-col gap-1">
        <legend className="mb-1 text-label text-text-secondary">
          เลือกวันรมควันและ Lot — วันที่เก่าที่สุดขึ้นก่อน (FIFO)
        </legend>
        <div className="max-h-[230px] overflow-y-auto overscroll-contain rounded-lg border border-border bg-surface md:max-h-[560px] lg:max-h-none">
          {rows.map((r, i) => (
            <div key={r.smoke_date_group_id}>
              {i === 0 || rows[i - 1].smoke_date !== r.smoke_date ? (
                <div className="sticky top-0 z-[1] flex items-center justify-between gap-2 border-b border-border bg-surface-sunken px-3 py-1 text-caption text-text-secondary">
                  <span>รมควัน {thaiDate(r.smoke_date)}</span>
                  {r.smoke_date === oldest ? (
                    <span className="rounded-full bg-accent-subtle px-2 text-accent">
                      เก่าที่สุด · แนะนำ
                    </span>
                  ) : null}
                </div>
              ) : null}
              <label className="flex min-h-14 cursor-pointer items-center gap-3 border-b border-border px-3 last:border-b-0 has-checked:bg-accent-subtle">
                <input
                  type="radio"
                  name="smoke_date_group_id"
                  value={r.smoke_date_group_id}
                  checked={selected?.smoke_date_group_id === r.smoke_date_group_id}
                  onChange={() => pick(r)}
                  className="size-5 shrink-0 accent-accent"
                />
                <span className="text-body text-text-primary">Lot {r.lot_code}</span>
                <span className="ml-auto text-body text-text-primary tabular-nums">
                  {kg(r.available_qty)} กก.
                </span>
              </label>
            </div>
          ))}
        </div>
        <span className="text-caption text-text-muted">
          {rows.length} รายการในคลังกลาง — เลื่อนในกรอบเพื่อดูทั้งหมด
        </span>
      </fieldset>

      {isOverride ? (
        <ReasonField
          id="fifo-reason"
          name="fifo_override_reason"
          label="เหตุผลที่ข้าม FIFO"
          trigger={`คลังกลางยังมีของรมควันวันที่ ${thaiDate(oldest)} ซึ่งเก่ากว่า — ส่งวันที่ใหม่กว่าก่อนต้องบอกเหตุผล (BR07)`}
          value={reason}
          onChange={setReason}
          required
        />
      ) : null}

      <Field label="สาขาปลายทาง">
        <select
          name="branch_location_id"
          required
          value={branchId}
          onChange={(e) => setBranchId(e.target.value)}
          className={cn(control, "h-12")}
        >
          <option value="" disabled>
            — เลือกสาขา —
          </option>
          {branches.map((b) => (
            <option key={b.id} value={b.id}>
              {b.name_th}
            </option>
          ))}
        </select>
      </Field>

      <Field label="วันที่ส่ง">
        <input
          type="date"
          name="event_date"
          required
          value={eventDate}
          onChange={(e) => setEventDate(e.target.value)}
          className={control}
        />
      </Field>

      <WeightField
        id="dispatch-weight"
        name="dispatched_weight_kg"
        label="น้ำหนักที่ส่ง"
        value={weight}
        onChange={setWeight}
        max={selected?.available_qty}
        maxLabel="ยอดของ Lot นี้ในคลังกลาง"
        invalid={overAvailable || (weight !== "" && actual === null)}
        helper={
          overAvailable
            ? "มากกว่ายอดในคลังกลาง — ส่งเกินที่มีไม่ได้ (BR24)"
            : undefined
        }
      />

      <CountField
        id="bag-count"
        name="bag_count"
        label="จำนวนถุง"
        unit="ถุง"
        value={bags}
        onChange={setBags}
        hint="ถุงที่ขึ้นรถจริง สาขาจะนับเทียบตอนรับของ (BR 02)"
      />

      <ActionBar>
        <button
          type="submit"
          disabled={pending || !selected || overAvailable}
          className={primaryAction}
        >
          {pending ? "กำลังจัดสรร…" : "จัดสรรให้สาขา"}
        </button>
      </ActionBar>
    </form>
  );
}
