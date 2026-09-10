import Link from "next/link";

import { actionButton, control, Field } from "@/components/ui/controls";
import { Sheet } from "@/features/config/components/sheet";
import type { CatalogueRow } from "@/features/config/types";
import { todayBangkok } from "@/lib/format/date";
import { newIdempotencyKey } from "@/lib/rpc/config";
import type { ExpenseKind } from "@/lib/rpc/expenses";
import { cn } from "@/lib/utils";
import { submitOwnerExpense } from "../actions";
import { KIND_HINT, KIND_LABEL, KINDS } from "../types";

/* OW 09 sheets (card ^ref-54). Server-rendered, zero client JavaScript — the OW 10 precedent.
 *
 * THE หมวด IS CHOSEN FIRST (`?new=KIND`), so the server renders exactly the fields that kind
 * takes: the month input exists only for MONTHLY_FIXED. No client-side toggling, and no field
 * the function would refuse (PLAN-owner-expenses.md Finding 7).
 *
 * Phone, one hand, sometimes gloved: every control is h-11 (44px), the kind choices are 72px
 * cards, and the amount opens the numeric keypad. */

export function ChooseKindSheet({
  hrefFor,
  closeHref,
}: {
  hrefFor: (kind: ExpenseKind) => string;
  closeHref: string;
}) {
  return (
    <Sheet title="บันทึกรายการ — เลือกหมวด" closeHref={closeHref}>
      <ul className="flex flex-col gap-3">
        {KINDS.map((kind) => (
          <li key={kind}>
            <Link
              href={hrefFor(kind)}
              className="flex min-h-[72px] flex-col justify-center gap-1 rounded-lg border border-border bg-surface p-4 hover:border-accent"
            >
              <span className="text-label text-text-primary">
                {KIND_LABEL[kind]}
              </span>
              <span className="text-caption text-text-secondary">
                {KIND_HINT[kind]}
              </span>
            </Link>
          </li>
        ))}
      </ul>
    </Sheet>
  );
}

export function ExpenseForm({
  kind,
  locations,
  closeHref,
}: {
  kind: ExpenseKind;
  /** Branches and the chef house. Central is the empty choice (`location_id` null). */
  locations: CatalogueRow[];
  closeHref: string;
}) {
  const today = todayBangkok();

  return (
    <Sheet
      title={`บันทึก${KIND_LABEL[kind]}`}
      subtitle={KIND_HINT[kind]}
      closeHref={closeHref}
    >
      <form action={submitOwnerExpense} className="grid gap-3 sm:grid-cols-2">
        <input type="hidden" name="kind" value={kind} />
        {/* One key per render: a double tap re-sends THIS key and lands once (R39, R4). */}
        <input
          type="hidden"
          name="idempotency_key"
          value={newIdempotencyKey()}
        />

        <Field label="วันที่จ่าย">
          <input
            type="date"
            name="event_date"
            required
            defaultValue={today}
            className={control}
          />
        </Field>

        <Field label="จำนวนเงิน (บาท)" hint="ทศนิยมไม่เกิน 2 ตำแหน่ง">
          <input
            type="text"
            inputMode="decimal"
            name="amount_thb"
            required
            pattern="[0-9,]+(\.[0-9]{1,2})?"
            className={cn(control, "tabular-nums")}
          />
        </Field>

        {kind === "MONTHLY_FIXED" ? (
          <Field
            label="เป็นค่าใช้จ่ายของเดือน"
            hint="เช่น ค่าเช่าเดือน ต.ค. ที่จ่ายวันที่ 28 ก.ย. ให้เลือกเดือน ต.ค."
          >
            <input
              type="month"
              name="expense_month"
              required
              defaultValue={today.slice(0, 7)}
              className={control}
            />
          </Field>
        ) : null}

        <Field label="สาขา" hint="เว้นว่าง = ส่วนกลาง">
          <select name="location_id" defaultValue="" className={control}>
            <option value="">ส่วนกลาง</option>
            {locations.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name_th}
              </option>
            ))}
          </select>
        </Field>

        <div className="sm:col-span-2">
          <Field
            label="รายละเอียด"
            hint="เขียนให้จับคู่กับรายการโอนได้ เช่น ผู้รับเงิน เลขอ้างอิง วันที่โอน"
          >
            <textarea
              name="detail"
              required
              rows={3}
              className={cn(control, "h-auto py-2")}
            />
          </Field>
        </div>

        <p className="text-caption text-text-muted sm:col-span-2">
          รายการที่บันทึกแล้วยังแก้หรือยกเลิกจากหน้านี้ไม่ได้ —
          ตรวจจำนวนเงินก่อนกดบันทึก
        </p>

        <div className="sm:col-span-2">
          <button type="submit" className={actionButton}>
            บันทึก
          </button>
        </div>
      </form>
    </Sheet>
  );
}
