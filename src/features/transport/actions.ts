"use server";

import { createHash } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { configAt } from "@/features/config/resolve";
import { hundredthsToDecimal, toHundredths } from "@/lib/format/number";
import { str } from "@/lib/params";
import {
  allocateFreight,
  confirmTransportReceipt,
  createTransportRun,
  dispatchTransportLine,
} from "@/lib/rpc/transport";
import { createClient } from "@/lib/supabase/server";
import { tripLabel } from "./labels";
import {
  allocMethod,
  fareFor,
  outboundHref,
  outboundSig,
  parseFareTable,
  tripKind,
} from "./outbound";
import { getRun, roundsByLotIds } from "./queries";

/* OW 02 write path (card ^ref-24). Four actions over four existing functions; nothing here
 * writes a table.
 *
 * ONE FORM KEY, ONE KEY PER STEP (PLAN-transport.md ^ref-24 build notes, Finding 5). An
 * outbound booking is fn_create_transport_run, then fn_dispatch_transport_line per lot,
 * then fn_allocate_freight, and each is its own transaction. Every step's key is derived
 * from the key the page minted at render: md5(`<form key>:run`),
 * md5(`<form key>:line:<lot id>`), md5(`<form key>:alloc`) — the same shape
 * fn_dispatch_transport_line uses for its own ':out' row. A double tap, or a resubmit after
 * a dropped connection, replays every finished step and continues from the one that failed.
 * If a step fails after the run exists, the Owner lands on that run's sheet, which shows
 * what is on the truck and can add the rest.
 *
 * THE FARE AND THE WEIGHTS ARE RE-READ HERE, NEVER POSTED. The fare comes from
 * freight_thb_by_vehicle_type at the run date (BR10, D04.1 — never typed). Each lot's weight
 * is its round's foodiva_sent_weight_kg from v_po_rounds (the loss base, BR03/ADR-011). A
 * hidden input carrying either would be a typed number with extra steps.
 */

const BASE = "/owner/transport";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
const BAD_KEY = "คำสั่งบันทึกไม่สมบูรณ์ กรุณาเปิดหน้านี้ใหม่แล้วลองอีกครั้ง";

function go(path: string): never {
  revalidatePath(BASE);
  revalidatePath("/owner/purchasing"); // lot states moved; OW 01's round list shows them
  redirect(path);
}

function runHref(runId: string, extra: Record<string, string>): string {
  const q = new URLSearchParams({ run: runId });
  for (const [k, v] of Object.entries(extra)) if (v) q.set(k, v);
  return `${BASE}?${q.toString()}`;
}

/** md5(`<base>:<part>`) as a uuid — Postgres' `md5(text)::uuid`, byte for byte. */
function deriveKey(base: string, part: string): string {
  const h = createHash("md5").update(`${base}:${part}`).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

function lotIds(form: FormData): string[] {
  return [
    ...new Set(
      form
        .getAll("lot")
        .map((v) => v.toString())
        .filter((v) => UUID.test(v)),
    ),
  ];
}

// ─── Outbound: create the run, put the lots on it, split the fare ─────────────────────

export async function confirmOutboundRun(form: FormData) {
  const formKey = str(form, "idempotency_key");
  const date = str(form, "date");
  const vehicle = str(form, "vehicle");
  const trip = tripKind(str(form, "trip"));
  const lots = lotIds(form);
  const choice = { date, vehicle, trip: trip ?? ("" as const), lots };
  // Typed on the variable, not the arrow: TypeScript narrows after a never-returning call
  // only when the callee's declared type says so.
  const back: (err: string) => never = (err) =>
    go(outboundHref(choice, { preview: "1", err }));

  if (!UUID.test(formKey)) back(BAD_KEY);
  if (!ISO_DATE.test(date)) back("ต้องระบุวันที่รถรับของ");
  if (!vehicle) back("เลือกประเภทรถ");
  if (!trip) back("เลือกเที่ยวเดียวหรือไป-กลับ");
  if (lots.length === 0) back("เลือกอย่างน้อยหนึ่งล็อตขึ้นรถ");
  if (str(form, "sig") !== outboundSig(choice)) {
    back(
      "ข้อมูลเปลี่ยนหลังคำนวณค่าขนส่ง — ตรวจค่าขนส่งด้านล่างอีกครั้งแล้วค่อยยืนยัน",
    );
  }

  const db = await createClient();
  const [fareCfg, methodCfg, rounds] = await Promise.all([
    configAt(db, "freight_thb_by_vehicle_type", date),
    configAt(db, "freight_alloc_method", date),
    roundsByLotIds(db, lots),
  ]);

  const fare = fareFor(parseFareTable(fareCfg?.value_json), vehicle, trip!);
  if (fare === null) {
    back(
      `ยังไม่ได้ตั้งค่าเที่ยวสำหรับ “${vehicle}” แบบ${tripLabel(trip === "ROUND_TRIP")} ณ วันที่ ${date} — ตั้งได้ที่ ตั้งค่าระบบ → ค่าขนส่งตามประเภทรถ`,
    );
  }
  if (rounds.error) back(`อ่านข้อมูลล็อตไม่สำเร็จ — ${rounds.error}`);
  if (rounds.rows.length !== lots.length)
    back("ไม่พบบางล็อตที่เลือก — โหลดหน้าใหม่แล้วเลือกอีกครั้ง");

  // A lot already on a truck is refused BEFORE anything is written. fn_dispatch_transport_line
  // does not check lot state itself (Cross-lane gaps), so this is the check.
  const moved = rounds.rows.filter((r) => r.lot_state !== "PO_CREATED");
  if (moved.length > 0) {
    back(
      `ล็อต ${moved.map((r) => r.lot_code).join(", ")} ขึ้นรถไปแล้ว — เอาออกจากรายการแล้วคำนวณใหม่`,
    );
  }
  const noDestination = rounds.rows.filter((r) => !r.chef_house_location_id);
  if (noDestination.length > 0) {
    back(
      `ล็อต ${noDestination.map((r) => r.lot_code).join(", ")} ไม่มีโรงรมควันปลายทาง`,
    );
  }

  const run = await createTransportRun({
    idempotencyKey: deriveKey(formKey, "run"),
    route: "FOODIVA_TO_CM",
    eventDate: date,
    vehicleType: vehicle,
    isRoundTrip: trip === "ROUND_TRIP",
    runCostThb: Number(hundredthsToDecimal(fare!)),
    lotIds: null,
    note: str(form, "note") || null,
  });
  if (!run.ok) back(run.message);

  const ordered = [...rounds.rows].sort((a, b) =>
    a.lot_code.localeCompare(b.lot_code),
  );
  for (const r of ordered) {
    const line = await dispatchTransportLine({
      idempotencyKey: deriveKey(formKey, `line:${r.lot_id}`),
      runId: run.data,
      lotId: r.lot_id,
      smokeDateGroupId: null,
      fromLocationId: null, // Foodiva is a supplier, not one of our locations
      toLocationId: r.chef_house_location_id!,
      dispatchedWeightKg: Number(r.foodiva_sent_weight_kg),
    });
    if (!line.ok) {
      go(
        runHref(run.data, {
          err: `ล็อต ${r.lot_code}: ${line.message} — รอบรถถูกสร้างแล้ว ล็อตที่ขึ้นรถแล้วแสดงด้านล่าง เพิ่มล็อตที่เหลือจากหน้านี้ได้`,
        }),
      );
    }
  }

  // MANUAL: fn_allocate_freight refuses, and nothing on the board writes manual shares. The
  // meat still moves; the run sheet says the fare is unallocated.
  if (allocMethod(methodCfg?.value_text) !== "MANUAL") {
    const alloc = await allocateFreight({
      idempotencyKey: deriveKey(formKey, "alloc"),
      runId: run.data,
    });
    if (!alloc.ok) go(runHref(run.data, { err: alloc.message }));
  }

  go(runHref(run.data, { saved: "run" }));
}

// ─── An existing outbound run: add lots, or re-split the fare ─────────────────────────

export async function addLotsToRun(form: FormData) {
  const formKey = str(form, "idempotency_key");
  const runId = str(form, "run_id");
  const lots = lotIds(form);

  if (!UUID.test(runId))
    go(`${BASE}?err=${encodeURIComponent("ไม่พบรอบรถนี้")}`);
  if (!UUID.test(formKey)) go(runHref(runId, { err: BAD_KEY }));
  if (lots.length === 0) go(runHref(runId, { err: "เลือกอย่างน้อยหนึ่งล็อต" }));

  const db = await createClient();
  const [run, rounds] = await Promise.all([
    getRun(db, runId),
    roundsByLotIds(db, lots),
  ]);
  if (!run || run.route !== "FOODIVA_TO_CM") {
    go(
      runHref(runId, {
        err: "เพิ่มล็อตได้เฉพาะรอบรถขาไป (Foodiva → เชียงใหม่)",
      }),
    );
  }
  if (rounds.error || rounds.rows.length !== lots.length) {
    go(
      runHref(runId, {
        err: "ไม่พบบางล็อตที่เลือก — โหลดหน้าใหม่แล้วเลือกอีกครั้ง",
      }),
    );
  }
  const moved = rounds.rows.filter((r) => r.lot_state !== "PO_CREATED");
  if (moved.length > 0) {
    go(
      runHref(runId, {
        err: `ล็อต ${moved.map((r) => r.lot_code).join(", ")} ขึ้นรถไปแล้ว`,
      }),
    );
  }

  for (const r of rounds.rows) {
    const line = await dispatchTransportLine({
      idempotencyKey: deriveKey(formKey, `line:${r.lot_id}`),
      runId,
      lotId: r.lot_id,
      smokeDateGroupId: null,
      fromLocationId: null,
      toLocationId: r.chef_house_location_id!,
      dispatchedWeightKg: Number(r.foodiva_sent_weight_kg),
    });
    if (!line.ok)
      go(runHref(runId, { err: `ล็อต ${r.lot_code}: ${line.message}` }));
  }

  // The method is the RUN's snapshot (R29), not config today.
  if (run!.alloc_method !== "MANUAL") {
    const alloc = await allocateFreight({
      idempotencyKey: deriveKey(formKey, "alloc"),
      runId,
    });
    if (!alloc.ok) go(runHref(runId, { err: alloc.message }));
  }

  go(runHref(runId, { saved: "lines" }));
}

export async function reallocateRun(form: FormData) {
  const key = str(form, "idempotency_key");
  const runId = str(form, "run_id");
  if (!UUID.test(runId))
    go(`${BASE}?err=${encodeURIComponent("ไม่พบรอบรถนี้")}`);
  if (!UUID.test(key)) go(runHref(runId, { err: BAD_KEY }));

  const alloc = await allocateFreight({ idempotencyKey: key, runId });
  if (!alloc.ok) go(runHref(runId, { err: alloc.message }));
  go(runHref(runId, { saved: "alloc" }));
}

// ─── Receipt of a CENTRAL line ────────────────────────────────────────────────────────

const RECEIPT_FIELDS = [
  "event_date",
  "received_weight_kg",
  "variance_reason",
  "variance_settlement",
] as const;

export async function submitReceipt(form: FormData) {
  const key = str(form, "idempotency_key");
  const lineId = str(form, "line_id");
  const eventDate = str(form, "event_date");
  const received = toHundredths(str(form, "received_weight_kg"));

  const fail = (message: string, keepKey = true): never => {
    const q = new URLSearchParams({ receive: lineId, err: message });
    if (keepKey && UUID.test(key)) q.set("k", key);
    for (const f of RECEIPT_FIELDS) {
      const v = str(form, f);
      if (v) q.set(f, v);
    }
    go(`${BASE}?${q.toString()}`);
  };

  if (!UUID.test(lineId))
    go(`${BASE}?err=${encodeURIComponent("ไม่พบรายการขนส่งนี้")}`);
  if (!UUID.test(key)) fail(BAD_KEY, false);
  if (!ISO_DATE.test(eventDate)) fail("ต้องระบุวันที่รับของ");
  // 0 is allowed — nothing arrived, and the whole dispatch stays outstanding (D06).
  if (received === null)
    fail("กรอกน้ำหนักที่รับจริง — ตัวเลขทศนิยมไม่เกิน 2 ตำแหน่ง");

  const result = await confirmTransportReceipt({
    idempotencyKey: key,
    lineId,
    eventDate,
    receivedWeightKg: Number(hundredthsToDecimal(received!)),
    varianceReason: str(form, "variance_reason") || null,
    varianceSettlement: str(form, "variance_settlement") || null,
    receivedBagCount: null, // no CM_TO_FOODIVA line carries a bag count (fn header, TC-44)
  });
  if (!result.ok) fail(result.message);

  go(`${BASE}?saved=receipt`);
}
