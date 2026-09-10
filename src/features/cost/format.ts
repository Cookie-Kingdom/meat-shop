/* kg / THB / % for the F7 screens (card ^ref-33).
 *
 * DISPLAY ONLY. Every figure arrives already computed and rounded by the database
 * (v_lot_yield, v_lot_cost, v_lot_daily_yield) — numeric(12,2) there, two decimals here. No
 * sum, product or percentage is worked out in TypeScript (CLAUDE.md: never a JS number doing
 * money arithmetic the DB should do).
 *
 * NULL IS SHOWN AS A DASH, NEVER AS 0.00. A null cost part means an input has not landed
 * (ADR-023) and a null yield means a weight was never entered (v0.2 line 349). Rendering
 * either as zero is exactly the settled-looking number those rules exist to prevent.
 *
 * ponytail: lives in the feature, not in `src/lib/format/`, because several lanes are adding
 * screens today and a second `lib/format/number.ts` would collide. Promote after merge.
 */

/** A PostgREST numeric: a JSON number, or a string for a value too wide for a double. */
export type Num = number | string | null | undefined;

const TWO_DP = new Intl.NumberFormat("th-TH", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

export const DASH = "—";

function two(v: Num): string | null {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? TWO_DP.format(n) : null;
}

export function kg(v: Num): string {
  const s = two(v);
  return s === null ? DASH : `${s} กก.`;
}

export function thb(v: Num): string {
  const s = two(v);
  return s === null ? DASH : `${s} บาท`;
}

export function pct(v: Num): string {
  const s = two(v);
  return s === null ? DASH : `${s}%`;
}

/** v_lot_cost.missing_inputs, in the Owner's words. The code names the input; the sentence
 * names who supplies it, because missing data is not the Owner's mistake (ADR-023). */
export const MISSING_INPUT_TH: Record<string, string> = {
  LOT_OPEN: "ล็อตยังไม่ปิด — ตัวเลขทั้งหมดเป็นค่าชั่วคราว",
  MEAT_PRICE: "ใบสั่งซื้อ (PO) ยังไม่มีราคาเนื้อต่อ กก.",
  BRINE_PCT: "ยังไม่ได้ตั้งสัดส่วนน้ำดอง (% ของน้ำหนักเนื้อ) ในหน้าตั้งค่า",
  BRINE_RATE: "ยังไม่ได้ตั้งต้นทุนน้ำดองต่อ กก. ในหน้าตั้งค่า",
  SMOKE_FEE_RATE: "ยังไม่ได้ตั้งอัตราค่ารมควันในหน้าตั้งค่า",
  OUTBOUND_FREIGHT: "ค่าขนส่งขาไป (Foodiva → เชียงใหม่) ยังไม่ได้ปันส่วน",
  RETURN_FREIGHT: "ยังไม่มีรถขากลับ หรือยังไม่ได้ปันส่วนค่าขนส่งขากลับ",
  RETURN_RECEIPT: "ของขากลับยังไม่ได้รับเข้าคลังกลาง",
  CHEF_HOUSE_STOCK: "ยังมีเนื้อของล็อตนี้ค้างอยู่ที่โรงรม",
};

export function missingInputTh(code: string): string {
  return MISSING_INPUT_TH[code] ?? code;
}
