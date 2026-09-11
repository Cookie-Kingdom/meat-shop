"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { kg, parseKg } from "@/lib/format/weight";
import { str } from "@/lib/params";
import {
  allocateToBranch,
  confirmCentralIntake,
  setReturnPickupDate,
} from "@/lib/rpc/movement";
import type { ActionState } from "./types";

/* OW 05–07 write path (card ^ref-37).
 *
 * WHO MAY DO THIS IS NOT DECIDED HERE. Every RPC runs under the caller's JWT, and the
 * function's own preamble decides: fn_require_central_receiver for OW 05 and OW 06,
 * fn_require_owner for OW 07. There is no other write path to skip to (ADR-002, ADR-004).
 * The `(owner)` layout's requireRole is the mirror.
 *
 * THE KEY COMES FROM THE FORM (`idempotency_key`, rendered by the page — PLAN-movement.md
 * Finding 13). Nothing here mints one.
 *
 * What these actions validate is SHAPE only: a weight that is not a number never reaches the
 * RPC as NaN. Every business rule — FIFO, central-only, the bag count, the variance — is the
 * function's, and its refusal comes back as Thai. */

const failed = (code: string, message: string): ActionState => ({
  status: "error",
  code,
  message,
});

const NOT_A_WEIGHT = "กรอกน้ำหนักเป็นตัวเลข ทศนิยมไม่เกิน 2 ตำแหน่ง";

/** OW 05 — a zero-JS form. The outcome rides the URL, the way OW 10 does it. */
export async function submitReturnPickupDate(form: FormData) {
  const lotId = str(form, "lot_id");
  const result = await setReturnPickupDate({
    idempotencyKey: str(form, "idempotency_key") || null,
    lotId,
    returnPickupDate: str(form, "return_pickup_date") || null,
  });
  const q = new URLSearchParams({ lot: lotId });
  if (result.ok) q.set("saved", "1");
  else q.set("err", result.message);
  revalidatePath("/owner/returns");
  redirect(`/owner/returns?${q.toString()}`);
}

/** OW 06. On success the line leaves the outstanding list, so the screen returns to it. */
export async function submitCentralIntake(
  _prev: ActionState,
  form: FormData,
): Promise<ActionState> {
  const weight = parseKg(str(form, "received_weight_kg"));
  if (weight === null) return failed("NOT_A_WEIGHT", NOT_A_WEIGHT);

  const result = await confirmCentralIntake({
    idempotencyKey: str(form, "idempotency_key") || null,
    lineId: str(form, "line_id"),
    eventDate: str(form, "event_date") || null,
    receivedWeightKg: weight,
    // Only posted while the field is on screen — ReasonField unmounts when it no longer applies.
    varianceReason: str(form, "variance_reason") || null,
  });
  if (!result.ok) return failed(result.code, result.message);

  revalidatePath("/owner/central");
  revalidatePath("/owner/allocate");
  redirect(`/owner/central?received=${encodeURIComponent(weight)}`);
}

/** OW 07. The screen STAYS: the second allocation of one lot to another branch is entered
 * without leaving it (LAYOUT-SKELETONS.md S2 worst case, TC-41). revalidatePath refetches
 * v_central_available, so the pinned balance is the ledger's, not a local decrement — and the
 * same render hands the form its next idempotency key. */
export async function submitAllocation(
  _prev: ActionState,
  form: FormData,
): Promise<ActionState> {
  const branchId = str(form, "branch_location_id");
  if (!branchId) return failed("BRANCH_REQUIRED", "เลือกสาขาปลายทางก่อน");
  const groupId = str(form, "smoke_date_group_id");
  if (!groupId) {
    return failed(
      "SMOKE_GROUP_REQUIRED",
      "เลือกกลุ่มวันรมควันและ Lot ที่จะส่งก่อน",
    );
  }
  const weight = parseKg(str(form, "dispatched_weight_kg"));
  if (weight === null) return failed("NOT_A_WEIGHT", NOT_A_WEIGHT);
  const bagsRaw = str(form, "bag_count");
  if (!/^\d{1,6}$/.test(bagsRaw)) {
    return failed("NOT_A_COUNT", "กรอกจำนวนถุงเป็นจำนวนเต็ม");
  }

  const result = await allocateToBranch({
    idempotencyKey: str(form, "idempotency_key") || null,
    branchLocationId: branchId,
    eventDate: str(form, "event_date") || null,
    smokeDateGroupId: groupId,
    dispatchedWeightKg: weight,
    // 0 is sent as 0: BAG_COUNT_REQUIRED is the function's to raise (v0.2:108), not ours.
    bagCount: Number(bagsRaw),
    // Posted only for a pick later than the oldest smoke date; a FIFO pick's reason is dropped
    // by the function anyway, so an override count stays honest (BR07).
    fifoOverrideReason: str(form, "fifo_override_reason") || null,
  });
  if (!result.ok) return failed(result.code, result.message);

  revalidatePath("/owner/allocate");
  revalidatePath("/owner/central");
  const branch = str(form, "branch_name") || "สาขา";
  return {
    status: "ok",
    message: `จัดสรร ${kg(weight)} กก. ${bagsRaw} ถุง ให้ ${branch} แล้ว — รายการไปรอที่หน้ารับของของสาขา`,
  };
}
