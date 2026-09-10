"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { str } from "@/lib/params";
import { newIdempotencyKey, type RpcResult } from "@/lib/rpc/config";
import { setSmokeFeeOverride } from "@/lib/rpc/cost";

/* OW 04 write path — the per-lot smoke-fee override (ADR-024, R41, card ^ref-33).
 *
 * THE IDEMPOTENCY KEY IS MINTED HERE, once per submit, never during render (R38, ADR-005).
 *
 * The refusal comes back as a Thai sentence in the URL, not as a thrown error: the Owner is
 * the person who decides what to do about it (the OW 10 precedent, features/config/actions).
 */

const RESULTS = "/owner/lots/results";

/** Back to the screen with the outcome. Only a path under the lot screens is honoured, so a
 * forged `back` cannot turn this action into an open redirect. */
function finish(result: RpcResult, back: string): never {
  const target = back.startsWith("/owner/lots") ? back : RESULTS;
  const q = new URLSearchParams();
  if (result.ok) q.set("saved", "1");
  else q.set("err", result.message);
  revalidatePath(RESULTS);
  redirect(`${target}${target.includes("?") ? "&" : "?"}${q.toString()}`);
}

/** A decimal the Owner typed, or null for anything that is not a finite number. Parsing
 * only — the stored figure is rounded by the database (numeric(12,2)). */
function num(value: string): number | null {
  if (value === "") return null;
  const n = Number(value.replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

export async function submitSmokeFeeOverride(form: FormData) {
  const back = str(form, "back") || RESULTS;
  const lotId = str(form, "lot_id");

  /* "ใช้อัตราปกติ" clears the override. Clearing takes no reason (PLAN-cost Finding 8): the
   * audit row keeps what was cleared. */
  if (str(form, "intent") === "clear") {
    finish(
      await setSmokeFeeOverride({
        idempotencyKey: newIdempotencyKey(),
        lotId,
        amountThb: null,
        reason: null,
      }),
      back,
    );
  }

  /* An empty amount is not "clear" — that is a separate button, so a field left blank by
   * accident cannot silently undo a discount. 0 is a real value: a free run. */
  const amount = num(str(form, "amount_thb"));
  if (amount === null) {
    finish(
      {
        ok: false,
        code: "NOT_A_NUMBER",
        message:
          "กรอกค่ารมควันที่เรียกเก็บจริงเป็นตัวเลข — ถ้าต้องการกลับไปใช้อัตราปกติ ให้กด “ใช้อัตราปกติ”",
      },
      back,
    );
  }

  finish(
    await setSmokeFeeOverride({
      idempotencyKey: newIdempotencyKey(),
      lotId,
      amountThb: amount,
      reason: str(form, "reason") || null,
    }),
    back,
  );
}
