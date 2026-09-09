import Link from "next/link";

import { submitSmokeFeeTier } from "../actions";
import { todayBangkok, type ConfigRow } from "../types";

/* The smoke-fee band-set form — OW 10 (card ^ref-12).
 *
 * THE WHOLE SET AT ONE DATE, NEVER ONE BAND (D02, R37). A gap is a property of the set:
 * validating one band at a time cannot see one, which is why `fn_set_smoke_fee_tier` takes
 * the array and refuses a partial write. So this form posts every band together, and there
 * is no per-band save button anywhere.
 *
 * ADR-024 — THE OWNER QUOTES THE FEE IN บาท/กรัม; THE TABLE STORES บาท/กก. The ×1000
 * happens once, in the Server Action, and the current value is echoed in both units above
 * the form so the two never quietly diverge. A `FLAT` band is a flat baht amount and is not
 * converted — it is not a rate per anything.
 *
 * ponytail: six fixed band rows, no add/remove buttons. Blank rows are skipped by the
 * action, so a 1-band set is one filled row and a 6-band set fills the sheet — and the whole
 * screen stays a Server Component with no client JavaScript. Ceiling: a seventh band. Upgrade
 * path is making this one file `"use client"` with a row counter in `useState`; nothing else
 * on the screen changes.
 */

const control =
  "h-11 w-full rounded-md border border-border bg-surface px-3 text-body text-text-primary " +
  "focus-visible:border-focus-ring focus-visible:outline-2 focus-visible:outline-focus-ring";

const ROWS = [0, 1, 2, 3, 4, 5];

type Band = {
  min_weight_kg: number;
  max_weight_kg: number | null;
  rate_thb: number;
  rate_basis: string;
};

/** The bands of the row in force, so the Owner starts from what is set rather than from
 * blank. `value_json` is the aggregate the view built, in min_weight_kg order. */
function bandsOf(row: ConfigRow | null): Band[] {
  return Array.isArray(row?.value_json) ? (row.value_json as Band[]) : [];
}

export function SmokeFeeTierForm({
  current,
  backHref,
  closeHref,
}: {
  current: ConfigRow | null;
  backHref: string;
  closeHref: string;
}) {
  const bands = bandsOf(current);

  return (
    <section className="flex flex-col gap-4 rounded-lg border border-accent bg-surface p-4">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-h2 text-text-primary">
            ตั้งขั้นค่ารมควันใหม่ทั้งชุด
          </h2>
          <p className="text-caption text-text-muted">
            ขั้นต้องเริ่มที่ 0 กก. ต่อกันทุกช่วง และขั้นสุดท้ายต้องเปิดปลาย —
            ระบบบันทึกทั้งชุดพร้อมกัน หรือไม่บันทึกเลย
          </p>
        </div>
        <Link
          href={closeHref}
          className="inline-flex h-11 items-center text-label text-accent hover:underline"
        >
          ยกเลิก
        </Link>
      </div>

      {bands.length > 0 ? (
        <p className="rounded-md border border-border bg-surface-sunken p-3 text-caption text-text-secondary">
          ชุดที่ใช้อยู่: {current?.value_display}
        </p>
      ) : null}

      <form action={submitSmokeFeeTier} className="flex flex-col gap-4">
        <input type="hidden" name="back" value={backHref} />

        <label className="flex flex-col gap-1 sm:max-w-xs">
          <span className="text-label text-text-secondary">
            เริ่มใช้ตั้งแต่วันที่
          </span>
          <input
            type="date"
            name="effective_from"
            required
            defaultValue={todayBangkok()}
            className={control}
          />
          <span className="text-caption text-text-muted">
            ชุดเดิมยังใช้กับล็อตที่ปิดไปแล้วเสมอ (BR23)
          </span>
        </label>

        <div className="overflow-x-auto">
          <table className="w-full min-w-[40rem] text-body-sm">
            <thead className="text-label text-text-secondary">
              <tr>
                <th className="px-2 py-2 text-left font-medium">
                  ตั้งแต่ (กก.)
                </th>
                <th className="px-2 py-2 text-left font-medium">
                  ถึง (กก.) — เว้นว่าง = ไม่จำกัด
                </th>
                <th className="px-2 py-2 text-left font-medium">
                  ค่ารมควัน (บาท/กรัม)
                </th>
                <th className="px-2 py-2 text-left font-medium">หน่วย</th>
              </tr>
            </thead>
            <tbody>
              {ROWS.map((i) => {
                const b = bands[i];
                const perGram =
                  b && b.rate_basis === "PER_KG"
                    ? String(Number(b.rate_thb) / 1000)
                    : b
                      ? String(b.rate_thb)
                      : "";
                return (
                  <tr key={i}>
                    <td className="px-2 py-1">
                      <input
                        type="text"
                        inputMode="decimal"
                        name="min_weight_kg"
                        defaultValue={b ? String(b.min_weight_kg) : ""}
                        className={control}
                      />
                    </td>
                    <td className="px-2 py-1">
                      <input
                        type="text"
                        inputMode="decimal"
                        name="max_weight_kg"
                        defaultValue={
                          b?.max_weight_kg == null
                            ? ""
                            : String(b.max_weight_kg)
                        }
                        className={control}
                      />
                    </td>
                    <td className="px-2 py-1">
                      <input
                        type="text"
                        inputMode="decimal"
                        name="rate_thb_per_g"
                        defaultValue={perGram}
                        className={control}
                      />
                    </td>
                    <td className="px-2 py-1">
                      <select
                        name="rate_basis"
                        defaultValue={b?.rate_basis ?? "PER_KG"}
                        className={control}
                      >
                        <option value="PER_KG">ต่อน้ำหนัก</option>
                        <option value="FLAT">เหมาจ่าย</option>
                      </select>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        <p className="text-caption text-text-muted">
          ช่วงน้ำหนักนับแบบ [ต่ำสุด, สูงสุด) — น้ำหนัก 100.00 กก. พอดี
          จะตกอยู่ในขั้นที่เริ่มต้นที่ 100 ไม่ใช่ขั้นก่อนหน้า ·
          แถวที่เว้นว่างไว้ระบบจะข้าม · “เหมาจ่าย” คือจำนวนบาทตรง ๆ
          ไม่ใช่ต่อกรัม
        </p>

        <button
          type="submit"
          className="h-11 self-start rounded-md bg-accent px-4 text-label text-accent-fg hover:bg-accent-hover"
        >
          บันทึกทั้งชุด
        </button>
      </form>
    </section>
  );
}
