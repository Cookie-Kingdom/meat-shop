import { control, Field } from "@/components/ui/controls";
import { SubmitBar } from "@/components/shared/submit-bar";
import { Sheet } from "@/features/config/components/sheet";
import { submitPo } from "../actions";
import type { SupplierOption } from "../types";
import { PoFigures } from "./po-figures";

/* `?new=1` — the create-PO sheet (OW 01, card ^ref-20; `PurchaseOrderForm` contract).
 *
 * Server-rendered around one small client island (PoFigures, for the live total). The
 * idempotency key is minted by the page for this render and posted in a hidden input (P5).
 *
 * The PO number is not a field. fn_create_po generates it (F4 clause 4), so the form says
 * it will appear, rather than inviting a typed one that would collide.
 */

export function NewPoSheet({
  suppliers,
  idempotencyKey,
  today,
  brinePctDefault,
  echo,
  closeHref,
}: {
  suppliers: SupplierOption[];
  idempotencyKey: string;
  today: string;
  /** brine_pct_of_meat at today, or null when the Owner has not set it (ADR-023). */
  brinePctDefault: string | null;
  /** What the Owner typed before a refusal, from the URL. */
  echo: Record<string, string>;
  closeHref: string;
}) {
  if (suppliers.length === 0) {
    return (
      <Sheet title="สร้าง PO ใหม่" closeHref={closeHref}>
        <p className="rounded-md border border-border bg-surface-sunken p-4 text-body text-text-secondary">
          ยังไม่มีผู้ขาย (Supplier) ที่เปิดใช้งานในระบบ จึงยังสร้าง PO ไม่ได้ —
          รอบนี้ยังไม่มีหน้าจอเพิ่มผู้ขาย ต้องให้ผู้ดูแลระบบเพิ่มให้ก่อน
        </p>
      </Sheet>
    );
  }

  const brinePctHint =
    brinePctDefault !== null
      ? `ค่าตั้งต้นจากการตั้งค่าระบบ ${brinePctDefault}% — แก้ตามที่ผู้ขายเสนอได้`
      : "ยังไม่ได้ตั้งสัดส่วนน้ำดองในการตั้งค่าระบบ — กรอกตามที่ผู้ขายเสนอ หรือเว้นว่าง";

  return (
    <Sheet
      title="สร้าง PO ใหม่"
      subtitle="เลข PO ออกให้อัตโนมัติเมื่อบันทึก · ราคาและน้ำดองไม่แสดงให้ผู้กรอกเชียงใหม่เห็น (F4)"
      closeHref={closeHref}
    >
      <form action={submitPo} className="flex flex-col gap-4">
        <input type="hidden" name="idempotency_key" value={idempotencyKey} />

        <Field label="ผู้ขาย (Supplier)">
          <select
            name="supplier_id"
            required
            defaultValue={echo.supplier_id ?? ""}
            className={control}
          >
            <option value="" disabled>
              — เลือก —
            </option>
            {suppliers.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        </Field>

        <Field label="วันที่สั่งซื้อ">
          <input
            type="date"
            name="event_date"
            required
            defaultValue={echo.event_date || today}
            className={control}
          />
        </Field>

        <PoFigures
          defaults={{
            weight: echo.ordered_weight_kg ?? "",
            price: echo.unit_price_thb_per_kg ?? "",
            brinePct: echo.brine_pct_offered || brinePctDefault || "",
            brineCost: echo.brine_cost_thb ?? "",
          }}
          brinePctHint={brinePctHint}
        />

        <Field label="หมายเหตุ">
          <input
            type="text"
            name="note"
            defaultValue={echo.note ?? ""}
            className={control}
          />
        </Field>

        <SubmitBar
          label="บันทึก PO"
          note="หลังบันทึก บันทึกรอบส่งได้ทันที — แต่ละรอบส่งจะสร้างล็อตใหม่หนึ่งล็อต"
        />
      </form>
    </Sheet>
  );
}
