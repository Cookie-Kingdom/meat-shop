"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { str } from "@/lib/params";
import { newIdempotencyKey } from "@/lib/rpc/config";
import { decideUnlock } from "@/lib/rpc/unlock";

/* OW 11 unlock decision (card ^ref-08). Mirrors `features/config/actions.ts`.
 *
 * THE IDEMPOTENCY KEY IS MINTED HERE, once per submit (R4, ADR-005). A double tap on
 * "อนุมัติ" sends two keys, and fn_decide_unlock answers the second with the stored body,
 * because R4 rides the request's state (same Owner, same decision).
 *
 * The outcome comes back in the URL: `?unlock_saved=1`, or `?unlock=<id>&unlock_err=<Thai>`,
 * which reopens the same sheet with the reason the database gave. The panel is a Server
 * Component and ships no client JavaScript.
 */

const PANEL = "/owner/audit";

function back(query: Record<string, string>): never {
  revalidatePath(PANEL);
  redirect(`${PANEL}?${new URLSearchParams(query).toString()}#unlock`);
}

export async function submitUnlockDecision(form: FormData) {
  const id = str(form, "unlock_request_id");
  const decision = str(form, "decision");
  const note = str(form, "decision_note");

  if (decision !== "APPROVED" && decision !== "REJECTED") {
    back({ unlock: id, unlock_err: "เลือกได้เฉพาะ อนุมัติ หรือ ไม่อนุมัติ" });
  }

  const result = await decideUnlock({
    idempotencyKey: newIdempotencyKey(),
    unlockRequestId: id,
    decision,
    note,
  });

  if (result.ok) back({ unlock_saved: "1" });
  back({ unlock: id, unlock_err: result.message });
}
