"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { backTo, num, str, whole, withParams } from "@/lib/params";
import {
  closeDailyReport,
  recordSales,
  recordWaste,
  SKU,
  type SalesLine,
} from "@/lib/rpc/sales";

/* BR 07 / BR 09 write path (card ^ref-46, PLAN-close-screens.md Findings 4–7).
 *
 * THE KEY IS NOT MINTED HERE. Each form carries a hidden `idempotency_key` its server component
 * rendered once for the page view, so a double tap posts the same key and the second call is a
 * replay (R4). A refused call wrote nothing, so the re-rendered page's fresh key is correct.
 *
 * On a refusal the typed values ride back in the URL under their field names, so nobody
 * re-types a count with wet hands. `back` is the page's clean URL (branch + date only), so a
 * success redirect needs nothing cleared. */

/** Field name prefix → SKU. Meat fields are `box:<lot>:<group>` / `addon:<lot>:<group>`: two SKUs,
 * never one field (D03.1, UAT-16), one row per lot (D05). */
const SALE_FIELDS: Record<
  string,
  { code: string; meat: boolean; whole: boolean }
> = {
  box: { code: SKU.box, meat: true, whole: true },
  addon: { code: SKU.addon, meat: true, whole: true },
  chilli: { code: SKU.chilli, meat: false, whole: true },
  rice: { code: SKU.rice, meat: false, whole: false },
  water: { code: SKU.water, meat: false, whole: true },
};

export async function submitSales(form: FormData) {
  const to = backTo(form, "/branch");
  const keep: Record<string, string> = {};
  const lines: SalesLine[] = [];
  let bad: string | null = null;

  for (const [name, raw] of form.entries()) {
    const [kind, lotId, groupId] = name.split(":");
    const field = SALE_FIELDS[kind];
    const value = raw.toString().trim();
    if (!field || value === "") continue; // empty = not sold, never a zero line
    keep[name] = value;
    const qty = field.whole ? whole(value) : num(value);
    if (qty === null) {
      bad ??= field.whole
        ? "กล่อง ถุง หลอด และขวด ต้องกรอกเป็นจำนวนเต็ม"
        : "กรอกน้ำหนักข้าวเหนียวเป็นตัวเลข";
      continue;
    }
    if (qty === 0) continue; // a typed 0 is "none sold", which is no line
    lines.push(
      field.meat
        ? {
            product_code: field.code,
            qty,
            lot_id: lotId,
            smoke_date_group_id: groupId,
          }
        : { product_code: field.code, qty },
    );
  }

  if (bad) redirect(withParams(to, { ...keep, err: bad }));
  if (lines.length === 0) {
    redirect(
      withParams(to, {
        ...keep,
        err: "ยังไม่ได้กรอกยอดขาย — กรอกจำนวนอย่างน้อยหนึ่งช่อง",
      }),
    );
  }

  const result = await recordSales({
    idempotencyKey: str(form, "idempotency_key"),
    dailyReportId: str(form, "daily_report_id"),
    lines,
  });
  revalidatePath("/branch", "layout");
  redirect(
    withParams(
      to,
      result.ok ? { saved: "sales" } : { ...keep, err: result.message },
    ),
  );
}

/** One READY lot per submit, the function's own shape. The weight is typed, never prefilled
 * from the remainder (Finding 5, Open Question 6). */
export async function submitWaste(form: FormData) {
  const to = backTo(form, "/branch");
  const pick = str(form, "waste_pick"); // "<lot_id>:<smoke_date_group_id>"
  const [lotId = "", groupId = ""] = pick.split(":");
  const kgRaw = str(form, "waste_kg");
  const reason = str(form, "waste_reason");
  const keep = { waste_pick: pick, waste_kg: kgRaw, waste_reason: reason };

  if (!lotId || !groupId) {
    redirect(
      withParams(to, { ...keep, err: "เลือกล็อตที่จะบันทึก Waste ก่อน" }),
    );
  }
  const kg = num(kgRaw);
  if (kg === null) {
    redirect(withParams(to, { ...keep, err: "กรอกน้ำหนักที่ทิ้งเป็นตัวเลข" }));
  }

  const result = await recordWaste({
    idempotencyKey: str(form, "idempotency_key"),
    dailyReportId: str(form, "daily_report_id"),
    itemType: "SMOKED_MEAT",
    stockState: "READY",
    qty: kg,
    reason,
    lotId,
    smokeDateGroupId: groupId,
  });
  revalidatePath("/branch", "layout");
  redirect(
    withParams(
      to,
      result.ok ? { saved: "waste" } : { ...keep, err: result.message },
    ),
  );
}

/** BR 09. The gate's code rides back with its Thai sentence, so the screen can link the banner
 * to the form that fixes it (TC-59). DIFF_REASON_REQUIRED re-opens the sheet with the Remark
 * required (Finding 7). */
export async function submitClose(form: FormData) {
  const to = backTo(form, "/branch");
  const remark = str(form, "remark");
  const result = await closeDailyReport({
    idempotencyKey: str(form, "idempotency_key"),
    dailyReportId: str(form, "daily_report_id"),
    remark: remark || null,
  });
  revalidatePath("/branch", "layout");

  if (result.ok) {
    redirect(withParams(to, { closed: result.data.closed_at, confirm: null }));
  }
  const needRemark = result.code === "DIFF_REASON_REQUIRED" ? "1" : null;
  redirect(
    withParams(to, {
      err: result.message,
      code: result.code,
      remark,
      confirm: needRemark,
      need_remark: needRemark,
    }),
  );
}
