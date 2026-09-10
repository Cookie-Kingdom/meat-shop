"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { str } from "@/lib/params";
import { recordOwnerExpense } from "@/lib/rpc/expenses";
import { isKind } from "./types";

/* OW 09 write path (card ^ref-54).
 *
 * THE IDEMPOTENCY KEY ARRIVES WITH THE FORM — minted when the server rendered it — and is NOT
 * minted here. An owner expense has no natural key (R39), so a double tap is only one row if
 * both POSTs carry the same key; see `lib/rpc/expenses.ts`. A key that is not a uuid did not
 * come from our render, and is refused rather than replaced, since a replacement would turn a
 * retry into a second expense.
 *
 * The refusal comes back as a Thai sentence in the URL, not a thrown error — the Owner is the
 * one who decides what to do about it. A refused write wrote nothing, so the re-rendered form
 * carries a fresh key for the next attempt.
 */

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const AMOUNT = /^\d+(\.\d{1,2})?$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

function back(params: Record<string, string>): never {
  revalidatePath("/owner/expenses");
  redirect(`/owner/expenses?${new URLSearchParams(params).toString()}`);
}

export async function submitOwnerExpense(form: FormData) {
  const kind = str(form, "kind");
  const key = str(form, "idempotency_key");
  const eventDate = str(form, "event_date");
  const amountRaw = str(form, "amount_thb").replace(/,/g, "");
  const detail = str(form, "detail");
  const month = str(form, "expense_month");
  const location = str(form, "location_id");

  if (!isKind(kind)) back({ new: "1", err: "เลือกหมวดก่อน" });
  if (!UUID.test(key)) {
    back({ new: kind, err: "แบบฟอร์มไม่สมบูรณ์ กรุณากรอกใหม่" });
  }
  if (!DATE.test(eventDate)) back({ new: kind, err: "ต้องระบุวันที่จ่าย" });
  /* Parsed from the typed string with at most two decimals, so the number sent is exactly
   * what was typed — no arithmetic, no float drift. The database rounds to numeric(12,2). */
  if (!AMOUNT.test(amountRaw)) {
    back({
      new: kind,
      err: "กรอกจำนวนเงินเป็นตัวเลข ทศนิยมไม่เกิน 2 ตำแหน่ง",
    });
  }

  const result = await recordOwnerExpense({
    idempotencyKey: key,
    kind,
    eventDate,
    amountThb: Number(amountRaw),
    detail,
    // Only a monthly cost names a month; the function refuses one on any other kind.
    expenseMonth: kind === "MONTHLY_FIXED" ? month || null : null,
    locationId: location || null,
  });

  if (!result.ok) back({ new: kind, err: result.message });

  // Land on the month the P&L books it in — the same rule as v_owner_expenses.pnl_month.
  back({
    month: kind === "MONTHLY_FIXED" ? month : eventDate.slice(0, 7),
    saved: "1",
  });
}
