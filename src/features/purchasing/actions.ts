"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { toHundredths } from "@/lib/format/number";
import { str } from "@/lib/params";
import { addPoDelivery, createPo } from "@/lib/rpc/purchasing";

/* OW 01 write path (card ^ref-20). Two actions, each one RPC.
 *
 * THE KEY COMES FROM THE FORM. The page mints it at render (PLAN-purchasing.md P5), so a
 * double tap posts the same key and the function replays. On a refusal the SAME key goes
 * back into the URL (`k`) and the re-rendered form reuses it. That matters for the one
 * failure a refusal cannot rule out: a dropped connection after the database committed.
 * The retry then replays instead of creating a second PO or a second lot. If the first
 * attempt wrote nothing, reusing the key is harmless — the function only conflicts when a
 * row already holds it.
 *
 * WHAT WAS TYPED GOES BACK TOO. The form is server-rendered, so a refusal re-renders it
 * from the URL. Echoing the fields means a phone user fixes one digit instead of retyping
 * the PO. It is the Owner's own session on an L1-only route.
 *
 * Parsing is exact (toHundredths), and a third decimal is refused rather than rounded —
 * numeric(12,2) would round it away without saying so.
 */

const BASE = "/owner/purchasing";
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function go(params: Record<string, string>): never {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v) q.set(k, v);
  revalidatePath(BASE);
  redirect(`${BASE}?${q.toString()}`);
}

/** "" → null (left blank on purpose); a valid decimal → its value; anything else →
 * undefined, which is a typo and gets a message rather than being sent as NaN. */
function decimal(raw: string): number | null | undefined {
  if (raw === "") return null;
  const h = toHundredths(raw);
  return h === null ? undefined : Number(h) / 100;
}

const NOT_A_DECIMAL = "ตัวเลขทศนิยมไม่เกิน 2 ตำแหน่ง";

const PO_FIELDS = [
  "supplier_id",
  "event_date",
  "ordered_weight_kg",
  "unit_price_thb_per_kg",
  "brine_pct_offered",
  "brine_cost_thb",
  "note",
] as const;

function failPo(form: FormData, key: string, message: string): never {
  const echo: Record<string, string> = {};
  for (const f of PO_FIELDS) echo[f] = str(form, f);
  go({ new: "1", err: message, k: key, ...echo });
}

export async function submitPo(form: FormData) {
  const key = str(form, "idempotency_key");
  const supplierId = str(form, "supplier_id");
  const eventDate = str(form, "event_date");
  const weight = decimal(str(form, "ordered_weight_kg"));
  const price = decimal(str(form, "unit_price_thb_per_kg"));
  const brinePct = decimal(str(form, "brine_pct_offered"));
  const brineCost = decimal(str(form, "brine_cost_thb"));

  if (!UUID.test(key)) {
    failPo(form, "", "คำสั่งบันทึกไม่สมบูรณ์ กรุณาเปิดหน้านี้ใหม่แล้วลองอีกครั้ง");
  }
  if (!supplierId) failPo(form, key, "เลือกผู้ขายก่อน");
  if (!eventDate) failPo(form, key, "ต้องระบุวันที่สั่งซื้อ");
  if (!weight) {
    failPo(form, key, `น้ำหนักที่สั่งต้องมากกว่า 0 — ${NOT_A_DECIMAL}`);
  }
  // F4 clause 1 computes a total from it, and v0.2 OW 01 lists it as an input.
  if (price === null || price === undefined) {
    failPo(form, key, `กรอกราคาต่อกิโลกรัม — ${NOT_A_DECIMAL}`);
  }
  // Brine is optional: blank is "no brine on this PO", which 0 would misstate as free.
  if (brinePct === undefined || brineCost === undefined) {
    failPo(form, key, `น้ำดอง: ${NOT_A_DECIMAL} หรือเว้นว่าง`);
  }

  const result = await createPo({
    idempotencyKey: key,
    supplierId,
    eventDate,
    orderedWeightKg: weight,
    unitPriceThbPerKg: price,
    brinePctOffered: brinePct,
    brineCostThb: brineCost,
    note: str(form, "note") || null,
  });
  if (!result.ok) failPo(form, key, result.message);

  go({ po: result.data, saved: "po" });
}

const ROUND_FIELDS = [
  "event_date",
  "foodiva_sent_weight_kg",
  "chef_house_location_id",
  "note",
] as const;

function failRound(
  form: FormData,
  poId: string,
  key: string,
  message: string,
): never {
  const echo: Record<string, string> = {};
  for (const f of ROUND_FIELDS) echo[f] = str(form, f);
  go({ po: poId, err: message, k: key, ...echo });
}

export async function submitRound(form: FormData) {
  const key = str(form, "idempotency_key");
  const poId = str(form, "po_id");
  const eventDate = str(form, "event_date");
  const chefHouse = str(form, "chef_house_location_id");
  const weight = decimal(str(form, "foodiva_sent_weight_kg"));

  if (!UUID.test(poId)) go({ err: "ไม่พบ PO นี้" });
  if (!UUID.test(key)) {
    failRound(form, poId, "", "คำสั่งบันทึกไม่สมบูรณ์ กรุณาเปิดหน้านี้ใหม่แล้วลองอีกครั้ง");
  }
  if (!eventDate) failRound(form, poId, key, "ต้องระบุวันที่ส่งของรอบนี้");
  if (!chefHouse) failRound(form, poId, key, "เลือกโรงรมควันปลายทางก่อน");
  if (!weight) {
    failRound(form, poId, key, `น้ำหนักรอบส่งต้องมากกว่า 0 — ${NOT_A_DECIMAL}`);
  }

  const result = await addPoDelivery({
    idempotencyKey: key,
    poId,
    eventDate,
    foodivaSentWeightKg: weight,
    chefHouseLocationId: chefHouse,
    note: str(form, "note") || null,
  });
  if (!result.ok) failRound(form, poId, key, result.message);

  go({ po: poId, saved: "round", lot: result.data });
}
