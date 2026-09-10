import { actionButton, control, Field } from "@/components/ui/controls";
import { Sheet } from "@/features/config/components/sheet";
import { cn } from "@/lib/utils";
import { submitSmokeFeeOverride } from "../actions";
import { thb } from "../format";
import type { LotCostRow } from "../types";

/* The per-lot smoke-fee override — OW 04 (ADR-024, R41, card ^ref-33).
 *
 * WHAT WAS ACTUALLY CHARGED, BESIDE WHAT THE RATE SAYS. The computed fee is echoed above the
 * form so a discount is entered as a difference from the rate, never in place of it; the rate
 * in OW 10 does not change and no other lot moves.
 *
 * TWO FORMS, TWO INTENTS. Saving an amount needs a reason (SMOKE_FEE_REASON_REQUIRED). Going
 * back to the rate is its own button: an amount field left blank by accident must not
 * silently undo a discount, so a blank amount is refused by the action rather than read as
 * "clear". 0 is a real value — a free run.
 *
 * No client JavaScript: plain forms posting to a Server Action, opened through the URL. */

export function SmokeFeeOverrideForm({
  row,
  backHref,
  closeHref,
}: {
  row: LotCostRow;
  backHref: string;
  closeHref: string;
}) {
  const current =
    row.smoke_fee_override_thb === null
      ? ""
      : String(row.smoke_fee_override_thb);

  return (
    <Sheet
      title={`ค่ารมควันที่เรียกเก็บจริง · ล็อต ${row.lot_code}`}
      subtitle="ใช้เมื่อโรงรมคิดต่างจากอัตราที่ตั้งไว้ เช่น ได้ส่วนลด — อัตราในหน้าตั้งค่าไม่เปลี่ยน และไม่กระทบล็อตอื่น"
      closeHref={closeHref}
    >
      <p className="rounded-md border border-border bg-surface-sunken p-3 text-body-sm text-text-secondary">
        ถ้าคิดตามอัตรา ล็อตนี้จะเป็น {thb(row.smoke_fee_computed_thb)}
        {row.smoke_fee_is_overridden
          ? ` · ตอนนี้กำหนดไว้ ${thb(row.smoke_fee_override_thb)}`
          : " · ตอนนี้ใช้อัตราปกติ"}
      </p>

      <form action={submitSmokeFeeOverride} className="flex flex-col gap-4">
        <input type="hidden" name="back" value={backHref} />
        <input type="hidden" name="lot_id" value={row.lot_id} />

        <div className="sm:max-w-xs">
          <Field
            label="ค่ารมควันที่เรียกเก็บจริง (บาท)"
            hint="กรอก 0 ถ้าโรงรมไม่คิดเงินรอบนี้"
          >
            <input
              type="text"
              inputMode="decimal"
              name="amount_thb"
              required
              defaultValue={current}
              className={control}
            />
          </Field>
        </div>

        <Field
          label="เหตุผล"
          hint="เช่น ส่วนลดที่ตกลงกับโรงรม — จำเป็นต้องกรอก"
        >
          <input
            type="text"
            name="reason"
            required
            defaultValue={row.smoke_fee_override_reason ?? ""}
            className={control}
          />
        </Field>

        <button type="submit" className={cn(actionButton, "self-start")}>
          บันทึกค่ารมควันของล็อตนี้
        </button>
      </form>

      {row.smoke_fee_is_overridden ? (
        <form
          action={submitSmokeFeeOverride}
          className="border-t border-border pt-4"
        >
          <input type="hidden" name="back" value={backHref} />
          <input type="hidden" name="lot_id" value={row.lot_id} />
          <input type="hidden" name="intent" value="clear" />
          <button
            type="submit"
            className="inline-flex h-11 items-center rounded-md border border-border px-4 text-label text-text-primary hover:bg-surface-sunken"
          >
            ใช้อัตราปกติ ({thb(row.smoke_fee_computed_thb)})
          </button>
        </form>
      ) : null}
    </Sheet>
  );
}
