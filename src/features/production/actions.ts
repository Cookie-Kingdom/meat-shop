"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { requireRole } from "@/lib/auth/session";
import { todayBangkok } from "@/lib/format/date";
import { str } from "@/lib/params";
import {
  closeLot,
  newIdempotencyKey,
  recordLotBags,
  recordLotReceipt,
  upsertSmokeDailyLog,
  type SourceInput,
} from "@/lib/rpc/production";

import { dbKg, parseKg, toKgNumber } from "./kg";
import { isUuid, readLot } from "./queries";
import type { SaveResult, SmokeLogInput, SmokeLogResult } from "./types";

/* CM 02–05 write path (card ^ref-30).
 *
 * THE DATABASE IS THE RULE. Each action re-parses what the form sent — a Server Action is a
 * POST anyone can make — and then calls the RPC, which asks fn_require_operator's four
 * questions and every business check again (ADR-002, ADR-004). The requireRole call is the
 * mirror, so a signed-out or wrong-role POST stops before it costs a round trip.
 *
 * THE KEYS ARRIVE WITH THE FORM. They were minted when the page rendered and the form has held
 * them across failed attempts; a success returns fresh ones (CM 04) or leaves the page (CM 02,
 * CM 03, CM 05), so the next write is a new key and a retry of this one is the same key.
 *
 * A refusal is returned as a Thai sentence, never thrown: the typed values stay on screen
 * (LAYOUT-SKELETONS, ERROR state). CM 05 is a plain form with nothing typed, so it redirects. */

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function fail(code: string, message: string): SaveResult {
  return { ok: false, code, message };
}

/** A date the operator chose: well-formed and not in the future (ADR-007 — earlier is allowed,
 * later is a typo). */
function badDate(date: string): SaveResult | null {
  if (!ISO_DATE.test(date)) return fail("DATE_INVALID", "เลือกวันที่ก่อน");
  if (date > todayBangkok()) {
    return fail("DATE_IN_FUTURE", "วันที่ต้องไม่เกินวันนี้");
  }
  return null;
}

function refresh() {
  // Every CM page reads through views on each request; this drops the router's copy so the
  // next screen shows what was just written.
  revalidatePath("/cm", "layout");
}

/** CM 02 — the received weight, with a reason when it does not match Foodiva's dispatch. The
 * post-drain weight is not sent: a null falls back to what CM 03 already stored. */
export async function saveReceipt(input: {
  lotId: string;
  idempotencyKey: string;
  eventDate: string;
  receivedKg: string;
  reason: string;
}): Promise<SaveResult> {
  await requireRole("L3_CM_OPERATOR");
  if (!isUuid(input.lotId) || !isUuid(input.idempotencyKey)) {
    return fail("BAD_REQUEST", "คำสั่งบันทึกไม่สมบูรณ์ กรุณาโหลดหน้าใหม่");
  }
  const dateProblem = badDate(input.eventDate);
  if (dateProblem) return dateProblem;

  const received = parseKg(input.receivedKg);
  if (received === null) {
    return fail(
      "NOT_A_WEIGHT",
      "กรอกน้ำหนักรับเป็นตัวเลข ทศนิยมไม่เกิน 2 ตำแหน่ง",
    );
  }

  const result = await recordLotReceipt({
    idempotencyKey: input.idempotencyKey,
    lotId: input.lotId,
    eventDate: input.eventDate,
    receivedWeightKg: toKgNumber(received),
    varianceReason: input.reason.trim() || null,
  });
  if (result.ok) refresh();
  return result;
}

/** CM 03 — the pre-smoke weight, on the row CM 02 created. The receipt date and the received
 * weight are re-read from the view rather than trusted from the form: the upsert overwrites
 * both, and CM 03 must move neither. */
export async function savePostDrain(input: {
  lotId: string;
  idempotencyKey: string;
  postDrainKg: string;
}): Promise<SaveResult> {
  await requireRole("L3_CM_OPERATOR");
  if (!isUuid(input.lotId) || !isUuid(input.idempotencyKey)) {
    return fail("BAD_REQUEST", "คำสั่งบันทึกไม่สมบูรณ์ กรุณาโหลดหน้าใหม่");
  }
  const drain = parseKg(input.postDrainKg);
  if (drain === null) {
    return fail(
      "NOT_A_WEIGHT",
      "กรอกน้ำหนักก่อนสโมคเป็นตัวเลข ทศนิยมไม่เกิน 2 ตำแหน่ง",
    );
  }

  const { data, error } = await readLot(input.lotId);
  if (error) return fail("READ_FAILED", `อ่านข้อมูล Lot ไม่สำเร็จ — ${error}`);
  const received = dbKg(data.lot?.received_weight_kg);
  if (!data.lot?.receipt_date || received === null) {
    return fail(
      "NO_RECEIPT",
      "ยังไม่มีบันทึกรับเนื้อของ Lot นี้ — บันทึกรับเนื้อก่อน",
    );
  }

  const result = await recordLotReceipt({
    idempotencyKey: input.idempotencyKey,
    lotId: input.lotId,
    eventDate: data.lot.receipt_date,
    receivedWeightKg: toKgNumber(received),
    postDrainWeightKg: toKgNumber(drain),
  });
  if (result.ok) refresh();
  return result;
}

/** CM 04 — the day's log (when it changed), then the new batch of bags (when there is one).
 * Two RPCs, two transactions, two keys, in that order: fn_record_lot_bags refuses a smoke date
 * with no log (SMOKE_LOG_MISSING). A retry after a half-success replays the log under its key
 * and writes nothing, then sends the bags — except that a half-success rotates the log key,
 * so an edit made before the retry is a correction rather than a replay that drops it. */
export async function saveSmokeLog(
  input: SmokeLogInput,
): Promise<SmokeLogResult> {
  await requireRole("L3_CM_OPERATOR");
  if (
    !isUuid(input.lotId) ||
    !isUuid(input.keys.log) ||
    !isUuid(input.keys.bags)
  ) {
    return fail(
      "BAD_REQUEST",
      "คำสั่งบันทึกไม่สมบูรณ์ กรุณาโหลดหน้าใหม่",
    ) as SmokeLogResult;
  }
  const dateProblem = badDate(input.eventDate);
  if (dateProblem) return dateProblem as SmokeLogResult;

  /* Parse the whole payload before writing anything, the shape the functions themselves use,
   * so a typo in bag 40 does not arrive after the log has already been rewritten. */
  let log: {
    sources: SourceInput[];
    smoked: number | null;
    brine: number | null;
  } | null = null;
  if (input.log) {
    const sources: SourceInput[] = [];
    for (const [i, row] of input.log.sources.entries()) {
      const kg = parseKg(row.kg);
      if (!isUuid(row.lotId)) {
        return fail(
          "SOURCE_LOT_REQUIRED",
          `แถว Lot ที่ ${i + 1}: ยังไม่ได้เลือก Lot`,
        ) as SmokeLogResult;
      }
      if (kg === null || kg <= 0) {
        return fail(
          "SOURCE_WEIGHT_INVALID",
          `แถว Lot ที่ ${i + 1}: กรอกน้ำหนักที่นำไปรมควันมากกว่า 0`,
        ) as SmokeLogResult;
      }
      sources.push({ lot_id: row.lotId, input_weight_kg: toKgNumber(kg) });
    }
    const smoked =
      input.log.smokedKg === "" ? null : parseKg(input.log.smokedKg);
    const brine = input.log.brineKg === "" ? null : parseKg(input.log.brineKg);
    if (input.log.smokedKg !== "" && smoked === null) {
      return fail(
        "NOT_A_WEIGHT",
        "กรอกน้ำหนักหลังผลิตเป็นตัวเลข",
      ) as SmokeLogResult;
    }
    if (input.log.brineKg !== "" && brine === null) {
      return fail(
        "NOT_A_WEIGHT",
        "กรอกน้ำดองที่ใช้เป็นตัวเลข",
      ) as SmokeLogResult;
    }
    log = {
      sources,
      smoked: smoked === null ? null : toKgNumber(smoked),
      brine: brine === null ? null : toKgNumber(brine),
    };
  }

  const bags: number[] = [];
  for (const [i, raw] of input.bags.entries()) {
    const kg = parseKg(raw);
    if (kg === null || kg <= 0) {
      return fail(
        "PACK_WEIGHT_INVALID",
        `ถุงที่ ${i + 1}: น้ำหนักแพ็คต้องมากกว่า 0 และมีทศนิยมไม่เกิน 2 ตำแหน่ง`,
      ) as SmokeLogResult;
    }
    bags.push(toKgNumber(kg));
  }

  if (!log && bags.length === 0) {
    return fail("NOTHING_TO_SAVE", "ยังไม่มีอะไรเปลี่ยน") as SmokeLogResult;
  }

  if (log) {
    const logged = await upsertSmokeDailyLog({
      idempotencyKey: input.keys.log,
      lotId: input.lotId,
      eventDate: input.eventDate,
      sources: log.sources,
      smokedWeightKg: log.smoked,
      brineUsedKg: log.brine,
    });
    if (!logged.ok) return logged;
  }

  if (bags.length > 0) {
    const bagged = await recordLotBags({
      idempotencyKey: input.keys.bags,
      lotId: input.lotId,
      smokeDate: input.eventDate,
      packWeightsKg: bags,
    });
    if (!bagged.ok) {
      if (log) refresh();
      return {
        ...bagged,
        message: log
          ? `บันทึกรมควันของวันนี้แล้ว แต่ถุงยังไม่เข้า — ${bagged.message}`
          : bagged.message,
        logSaved: Boolean(log),
        keys: log
          ? { log: newIdempotencyKey(), bags: input.keys.bags }
          : undefined,
      };
    }
  }

  refresh();
  return {
    ok: true,
    keys: { log: newIdempotencyKey(), bags: newIdempotencyKey() },
  };
}

/** CM 05 — a plain form, nothing typed, so it redirects either way. The key was rendered into
 * the confirm sheet; a double tap on a slow connection sends it twice and the second is R4's
 * replay of the first, not a second close (TC-53). */
export async function closeLotAction(form: FormData): Promise<void> {
  await requireRole("L3_CM_OPERATOR");
  const lotId = str(form, "lot_id");
  const key = str(form, "idempotency_key");
  if (!isUuid(lotId) || !isUuid(key)) redirect("/cm");

  const base = `/cm/lots/${lotId}/close`;
  const result = await closeLot({ idempotencyKey: key, lotId });
  refresh();
  if (!result.ok) {
    const q = new URLSearchParams({ confirm: "1", err: result.message });
    redirect(`${base}?${q.toString()}`);
  }
  redirect(`${base}?closed=1`);
}
