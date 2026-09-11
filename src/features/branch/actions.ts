"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { backTo as backUnder, num, str, whole, withParams } from "@/lib/params";
import {
  confirmBranchReceipt,
  openDailyReport,
  recordThaw,
} from "@/lib/rpc/branch";

/* BR 01 / BR 02 / BR 05 write path (card ^ref-41, PLAN-thaw.md T8).
 *
 * THE IDEMPOTENCY KEY IS NOT MINTED HERE. It arrives as a hidden input the server component
 * rendered once for this page view (`idempotency_key`), so a double tap and a browser re-POST
 * carry the same key and the second one is a replay (R4). `features/config/actions.ts` mints per
 * submit, which is right for config — CONFIG_DUPLICATE_DATE refuses a repeat — and wrong for a
 * ledger write, where a second key is a second thaw.
 *
 * The outcome comes back in the URL, as config's does: `err` is already a Thai sentence. On a
 * refusal the typed values ride back too, so the operator never re-types a weight with wet
 * hands because the database asked for a reason (TDD TC-43).
 */

/** Only back into this route group — never an open redirect off a posted field. The helpers
 * live in `lib/params.ts` since ^ref-46, which shares them. */
const backTo = (form: FormData) => backUnder(form, "/branch");

export async function submitOpenDay(form: FormData) {
  const to = backTo(form);
  const result = await openDailyReport({
    idempotencyKey: str(form, "idempotency_key"),
    locationId: str(form, "location_id"),
    reportDate: str(form, "report_date"),
  });
  revalidatePath("/branch", "layout");
  redirect(
    withParams(
      to,
      result.ok
        ? { saved: "open", err: null }
        : { err: result.message, saved: null },
    ),
  );
}

export async function submitReceipt(form: FormData) {
  const to = backTo(form);
  const lineId = str(form, "line_id");
  const eventDate = str(form, "event_date");
  const weightRaw = str(form, "received_weight_kg");
  const bagsRaw = str(form, "received_bag_count");
  const reason = str(form, "variance_reason");
  const keep = { line: lineId, w: weightRaw, bags: bagsRaw, reason, date: eventDate, saved: null };

  const weight = num(weightRaw);
  if (weight === null) {
    redirect(withParams(to, { ...keep, err: "กรอกน้ำหนักจริงเป็นตัวเลข" }));
  }
  const bags = bagsRaw === "" ? null : whole(bagsRaw);
  if (bagsRaw !== "" && bags === null) {
    redirect(withParams(to, { ...keep, err: "กรอกจำนวนถุงเป็นจำนวนเต็ม" }));
  }

  const result = await confirmBranchReceipt({
    idempotencyKey: str(form, "idempotency_key"),
    lineId,
    eventDate,
    receivedWeightKg: weight,
    receivedBagCount: bags,
    varianceReason: reason || null,
  });
  revalidatePath("/branch", "layout");

  if (result.ok) {
    redirect(
      withParams(to, {
        saved: "receipt",
        line: null,
        w: null,
        bags: null,
        reason: null,
        date: null,
        need_reason: null,
        err: null,
      }),
    );
  }
  /* The function decided a reason is needed. The form comes back with the reason field
   * required and everything typed still in it (PLAN Finding 10). */
  redirect(
    withParams(to, {
      ...keep,
      err: result.message,
      need_reason: result.code === "VARIANCE_REASON_REQUIRED" ? "1" : null,
    }),
  );
}

export async function submitThaw(form: FormData) {
  const to = backTo(form);
  const pick = str(form, "pick"); // "<lot_id>:<smoke_date_group_id>" — one lot per submit
  const [lotId = "", groupId = ""] = pick.split(":");
  const weightRaw = str(form, "thawed_weight_kg");
  const reason = str(form, "fifo_override_reason");
  const keep = { pick, w: weightRaw, reason, done: null };

  if (!lotId || !groupId) {
    redirect(withParams(to, { ...keep, err: "เลือกล็อตที่จะละลายก่อน" }));
  }
  const weight = num(weightRaw);
  if (weight === null) {
    redirect(withParams(to, { ...keep, err: "กรอกน้ำหนักที่ละลายเป็นตัวเลข" }));
  }

  const result = await recordThaw({
    idempotencyKey: str(form, "idempotency_key"),
    dailyReportId: str(form, "daily_report_id"),
    lotId,
    smokeDateGroupId: groupId,
    thawedWeightKg: weight,
    fifoOverrideReason: reason || null,
  });
  revalidatePath("/branch", "layout");

  if (result.ok) {
    /* The pinned region re-reads v_stock_balance for this tuple — a refetch, not an optimistic
     * decrement: the ledger is the truth. */
    redirect(
      withParams(to, {
        done: "1",
        lot: result.data.lot_id,
        group: result.data.smoke_date_group_id,
        kg: String(result.data.thawed_weight_kg),
        pick: null,
        w: null,
        reason: null,
        err: null,
      }),
    );
  }
  redirect(withParams(to, { ...keep, err: result.message }));
}
