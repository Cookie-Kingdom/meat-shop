/* The config key catalogue — OW 10 (card ^ref-12).
 *
 * Built from `API_DATA_MODEL.md` → Config keys. Every key that is not marked *Removed*
 * appears here exactly once, with the Thai label, the group from the `ConfigTable`
 * contract, its value type and its unit.
 *
 * IT IS A CONSTANT, NOT A TABLE AND NOT FREE TEXT. Free-text key entry means the Owner can
 * type `avg_pack_wieght_kg`, create a key nothing reads, and see a screen that says the
 * value is set while `fn_record_sales` still raises `CONFIG_NOT_SET`. The screen offers the
 * catalogue and nothing else.
 *
 * ponytail: hand-kept, and it duplicates part of ^ref-61's requirement list. Ceiling: two
 * lists that can disagree about which keys exist. ^ref-61 builds `v_config_readiness`,
 * which is the single source of truth for the *required* subset — fold this list's
 * `severity` into that view when it lands, and keep only the labels here.
 *
 * ponytail: nothing constrains which keys may be branch-scoped except `scopable` below,
 * which is TypeScript. The database will still store a branch row for a global-only key and
 * `fn_config_value` will resolve it. Ceiling: a wrong-scoped row resolving ahead of the
 * global one for one branch. Upgrade path is a `config_key_registry` table — a table for a
 * problem nobody has had yet, so not now (carried from TDD-config-layer.md open questions).
 */

/** The `ConfigTable` contract's key groups, in the order the screen lists them. */
export const GROUPS = [
  "SMOKE_FEE",
  "TRANSPORT",
  "PRODUCTS",
  "MATERIALS",
  "RECEIVING",
  "ASSIGNMENT",
  "FINANCE",
] as const;

export type Group = (typeof GROUPS)[number];

export const GROUP_LABEL: Record<Group, string> = {
  SMOKE_FEE: "ค่ารมควัน",
  TRANSPORT: "ค่าขนส่ง",
  PRODUCTS: "สินค้าและราคา",
  MATERIALS: "วัสดุและสต๊อก",
  RECEIVING: "การรับของ",
  ASSIGNMENT: "ผู้รับผิดชอบและแจ้งเตือน",
  FINANCE: "การเงิน",
};

/** Which of the four dated sources an item is written to. Mirrors `v_config_history.source`. */
export type Source =
  "CONFIG" | "PRODUCT_PRICE" | "FULL_STOCK" | "SMOKE_FEE_TIER";

/** A boolean is stored in `value_json` (`true` / `false`), never `value_text`.
 * `config_settings` has no boolean column, and `'true'` in a text column becomes `'TRUE'`,
 * `'1'`, `'yes'` inside a year. jsonb has the type. */
export type ValueType = "numeric" | "text" | "boolean" | "json" | "date";

export type ConfigKey = {
  key: string;
  label_th: string;
  group: Group;
  type: ValueType;
  /** Rendered after the input and in the table. "" where the value is not a quantity. */
  unit: string;
  /** Whether `API_DATA_MODEL.md` allows a branch-scoped row for this key. */
  scopable: boolean;
  /** Round one does not read it (D04). The row exists; absent is not the same as deferred. */
  deferred?: boolean;
  /** Shown under the input where the key's meaning is not obvious from its label. */
  hint_th?: string;
};

export const CONFIG_KEYS: ConfigKey[] = [
  // ── Smoke fee ───────────────────────────────────────────────────────────────────────
  {
    key: "smoke_fee_tier_basis",
    label_th: "น้ำหนักที่ใช้เลือกขั้นค่ารมควัน",
    group: "SMOKE_FEE",
    type: "text",
    unit: "",
    scopable: false,
    hint_th:
      "FOODIVA_DISPATCH — น้ำหนักที่ส่งออกจากฟู้ดดีว่า ไม่ใช่น้ำหนักที่เชียงใหม่รับ (BR10)",
  },

  // ── Transport ───────────────────────────────────────────────────────────────────────
  {
    key: "freight_thb_by_vehicle_type",
    label_th: "ค่าขนส่งตามประเภทรถ",
    group: "TRANSPORT",
    type: "json",
    unit: "บาท",
    scopable: false,
    hint_th: "ตารางค่าเที่ยว แยกตามประเภทรถ และเที่ยวเดียว/ไป-กลับ",
  },
  {
    key: "freight_alloc_method",
    label_th: "วิธีเฉลี่ยค่าขนส่งหลายล็อต",
    group: "TRANSPORT",
    type: "text",
    unit: "",
    scopable: false,
    hint_th:
      "BY_LOT_WEIGHT / EQUAL_SPLIT / MANUAL — บันทึกติดไปกับรอบขนส่งแต่ละรอบ",
  },
  {
    key: "vehicle_schedule",
    label_th: "ตารางรถเข้า",
    group: "TRANSPORT",
    type: "json",
    unit: "",
    scopable: false,
    hint_th: "ใส่ได้มากกว่าหนึ่งวันต่อสัปดาห์",
  },

  // ── Products ────────────────────────────────────────────────────────────────────────
  {
    key: "box_sale_price_thb",
    label_th: "ราคาขายกล่องปกติ",
    group: "PRODUCTS",
    type: "numeric",
    unit: "บาท/กล่อง",
    scopable: true,
  },
  {
    key: "addon_sealed_meat_price_thb",
    label_th: "ราคา Add-on เนื้อซีล",
    group: "PRODUCTS",
    type: "numeric",
    unit: "บาท/ถุง",
    scopable: true,
    hint_th: "เป็นรายการขายแยกจากกล่อง ไม่ใช่ส่วนหนึ่งของกล่อง",
  },
  {
    key: "chilli_paste_sale_price_thb_per_tube",
    label_th: "ราคาขายน้ำพริก",
    group: "PRODUCTS",
    type: "numeric",
    unit: "บาท/หลอด",
    scopable: false,
  },
  {
    key: "chilli_paste_cost_thb_per_tube",
    label_th: "ต้นทุนน้ำพริก",
    group: "PRODUCTS",
    type: "numeric",
    unit: "บาท/หลอด",
    scopable: false,
  },
  {
    key: "chilli_paste_tube_weight_g",
    label_th: "น้ำหนักน้ำพริกต่อหลอด",
    group: "PRODUCTS",
    type: "numeric",
    unit: "กรัม",
    scopable: false,
  },
  {
    key: "rice_serving_weight_kg",
    label_th: "น้ำหนักข้าวเหนียวต่อที่",
    group: "PRODUCTS",
    type: "numeric",
    unit: "กก.",
    scopable: false,
  },
  {
    key: "rice_sale_price_thb_per_kg",
    label_th: "ราคาขายข้าวเหนียว",
    group: "PRODUCTS",
    type: "numeric",
    unit: "บาท/กก.",
    scopable: true,
  },
  {
    key: "avg_pack_weight_kg",
    label_th: "น้ำหนักเฉลี่ยต่อซอง",
    group: "PRODUCTS",
    type: "numeric",
    unit: "กก./ซอง",
    scopable: false,
    hint_th: "ใช้แปลงซอง↔กก. และใช้ตรวจ Diff — ระบบไม่เดาค่านี้ให้ (BR04)",
  },
  {
    key: "brine_pct_of_meat",
    label_th: "สัดส่วนน้ำเกลือต่อเนื้อ",
    group: "PRODUCTS",
    type: "numeric",
    unit: "%",
    scopable: false,
    hint_th: "กรอก 10.00 หมายถึง 10%",
  },
  {
    key: "brine_cost_thb_per_kg",
    label_th: "ต้นทุนน้ำเกลือ",
    group: "PRODUCTS",
    type: "numeric",
    unit: "บาท/กก.",
    scopable: false,
  },

  // ── Materials ───────────────────────────────────────────────────────────────────────
  {
    key: "material_alert_ratio",
    label_th: "สัดส่วนแจ้งเตือนวัสดุใกล้หมด",
    group: "MATERIALS",
    type: "numeric",
    unit: "",
    scopable: false,
    hint_th: "0.20 = เตือนเมื่อเหลือ 20% ของสต๊อกเต็ม",
  },
  {
    key: "material_reorder_point_qty",
    label_th: "จุดสั่งซื้อวัสดุ",
    group: "MATERIALS",
    type: "numeric",
    unit: "ชิ้น",
    scopable: false,
    hint_th: "จำนวนสัมบูรณ์ ใช้คู่กับสัดส่วนข้างบน",
  },
  {
    key: "material_days_of_cover_target",
    label_th: "จำนวนวันที่ต้องมีของสำรอง",
    group: "MATERIALS",
    type: "numeric",
    unit: "วัน",
    scopable: false,
  },
  {
    key: "yield_alert_threshold_pct",
    label_th: "เกณฑ์เตือนการสูญเสียน้ำหนัก",
    group: "MATERIALS",
    type: "numeric",
    unit: "%",
    scopable: false,
    hint_th: "กรอก 20.00 หมายถึง 20%",
  },

  // ── Receiving ───────────────────────────────────────────────────────────────────────
  {
    key: "receipt_variance_threshold_pct",
    label_th: "เกณฑ์ส่วนต่างตอนรับของ",
    group: "RECEIVING",
    type: "numeric",
    unit: "%",
    scopable: false,
    hint_th: "กรอก 20.00 หมายถึง 20%",
  },
  {
    key: "receipt_variance_requires_reason",
    label_th: "บังคับใส่เหตุผลเมื่อเกินเกณฑ์",
    group: "RECEIVING",
    type: "boolean",
    unit: "",
    scopable: false,
  },
  {
    key: "receipt_variance_settlement_method",
    label_th: "วิธีปิดส่วนต่างที่ขาด",
    group: "RECEIVING",
    type: "text",
    unit: "",
    scopable: false,
    hint_th: "ยังไม่มีรายการค่าที่กำหนดไว้ — ระบบเก็บตามที่กรอก",
  },
  {
    key: "partial_receipt_allowed",
    label_th: "อนุญาตให้รับของไม่ครบ",
    group: "RECEIVING",
    type: "boolean",
    unit: "",
    scopable: true,
    hint_th: "เปิดไว้ = ส่งและรับแบ่งรอบได้ โดยมียอดค้างรับ",
  },
  {
    key: "business_day_close_earliest",
    label_th: "เวลาที่เร็วที่สุดที่ปิดวันได้",
    group: "RECEIVING",
    type: "text",
    unit: "",
    scopable: false,
    hint_th: "เช่น 21:00",
  },
  {
    key: "business_day_shift_rule",
    label_th: "กติกาวันทำการ",
    group: "RECEIVING",
    type: "text",
    unit: "",
    scopable: false,
    hint_th: "วันทำการนับจากเปิดกะถึงเปิดกะถัดไป ตี 1 จึงยังเป็นของวันก่อนหน้า",
  },
  {
    key: "unlock_max_days_back",
    label_th: "ย้อนแก้ได้กี่วัน",
    group: "RECEIVING",
    type: "numeric",
    unit: "วัน",
    scopable: false,
    hint_th: "นับรวมวันสุดท้าย · 0 = วันนี้เท่านั้น · ติดลบไม่ได้",
  },
  {
    key: "unlock_window_hours",
    label_th: "ปลดล็อกแล้วใช้ได้กี่ชั่วโมง",
    group: "RECEIVING",
    type: "numeric",
    unit: "ชั่วโมง",
    scopable: false,
  },
  {
    key: "opening_cutoff_date",
    label_th: "วันที่ยอดยกมาเป็นจริง",
    group: "RECEIVING",
    type: "date",
    unit: "",
    scopable: false,
    hint_th: "ทุกรายการยอดยกมาต้องไม่เกินวันนี้",
  },

  // ── Assignment ──────────────────────────────────────────────────────────────────────
  {
    key: "central_warehouse_keeper_ids",
    label_th: "ผู้รับของเข้าคลังกลาง",
    group: "ASSIGNMENT",
    type: "json",
    unit: "",
    scopable: false,
  },
  {
    key: "alert_enabled",
    label_th: "เปิด/ปิดการแจ้งเตือนแต่ละประเภท",
    group: "ASSIGNMENT",
    type: "json",
    unit: "",
    scopable: false,
  },
  {
    key: "alert_recipients",
    label_th: "ผู้รับการแจ้งเตือนและช่องทาง",
    group: "ASSIGNMENT",
    type: "json",
    unit: "",
    scopable: false,
  },

  // ── Finance ─────────────────────────────────────────────────────────────────────────
  // D04 puts these outside round one. The row exists and a value may be entered; nothing
  // reads it. Deferred is not the same as missing, and the screen must not conflate them.
  {
    key: "line_man_gp_pct",
    label_th: "GP ของ LINE MAN",
    group: "FINANCE",
    type: "numeric",
    unit: "%",
    scopable: true,
    deferred: true,
  },
  {
    key: "corporate_tax_pct",
    label_th: "อัตราภาษีนิติบุคคล",
    group: "FINANCE",
    type: "numeric",
    unit: "%",
    scopable: false,
    deferred: true,
  },
];

const BY_KEY = new Map(CONFIG_KEYS.map((k) => [k.key, k]));

export function configKey(key: string): ConfigKey | undefined {
  return BY_KEY.get(key);
}

/** The Thai label for a `v_config_history` row. The view's `item_label_th` already carries
 * a real name for the three table-backed sources; only `CONFIG` needs the catalogue, whose
 * `item_label_th` is the raw key. A key not in the catalogue falls back to itself rather
 * than to a blank cell — an unknown key is a fact worth seeing on the screen. */
export function labelFor(
  source: string,
  itemKey: string,
  fallback: string,
): string {
  return source === "CONFIG"
    ? (BY_KEY.get(itemKey)?.label_th ?? itemKey)
    : fallback;
}

/** Which group a `v_config_history` row belongs to. The three table-backed sources have a
 * fixed group each; `CONFIG` asks the catalogue. */
export function groupFor(source: string, itemKey: string): Group | null {
  if (source === "SMOKE_FEE_TIER") return "SMOKE_FEE";
  if (source === "PRODUCT_PRICE") return "PRODUCTS";
  if (source === "FULL_STOCK") return "MATERIALS";
  return BY_KEY.get(itemKey)?.group ?? null;
}
