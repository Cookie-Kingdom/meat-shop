import { actionButton, control, Field } from "@/components/ui/controls";
import { todayBangkok } from "@/lib/format/date";
import { cn } from "@/lib/utils";
import {
  submitConfigValue,
  submitFullStock,
  submitProductPrice,
} from "../actions";
import { CONFIG_KEYS, configKey, GROUP_LABEL } from "../keys";
import type { CatalogueRow } from "../types";
import { Sheet } from "./sheet";

/* The `ตั้งค่าใหม่ตั้งแต่วันที่…` sheet — OW 10 (card ^ref-12).
 *
 * A CREATE FORM, NOT AN EDIT FORM. It appends a new dated row and never touches an existing
 * one (ADR-006, BR23). The date field is the point of the whole screen: the Owner is not
 * changing a number, they are saying what the number becomes from a date.
 *
 * SERVER-RENDERED, ZERO CLIENT JAVASCRIPT. Which item is being set lives in `?set=`, so the
 * form knows the value's type before it renders and can pick the right input — a numeric
 * keypad for a rate, a select for a boolean, a textarea for jsonb — without any client-side
 * switching. PLAN-config-screen.md expected this to be the one client component on the
 * screen; putting the item in the URL made it unnecessary, and the whole route now ships no
 * client bundle at all. It also means a half-filled form survives a back button.
 *
 * The `min` on the date input is deliberately absent: back-dating a rate is legitimate (the
 * Owner is recording what was already true), and `fn_set_config` refuses only a same-day
 * change of an existing value.
 *
 * Screens are entered one-handed, sometimes with wet or gloved hands: every control is
 * `h-11` (--tap-min) and every numeric field carries `inputMode="decimal"`.
 */

function DateField() {
  return (
    <Field
      label="เริ่มใช้ตั้งแต่วันที่"
      hint="ค่าเดิมยังใช้กับวันก่อนหน้านี้เสมอ — รายงานที่ปิดไปแล้วไม่เปลี่ยน"
    >
      <input
        type="date"
        name="effective_from"
        required
        defaultValue={todayBangkok()}
        className={control}
      />
    </Field>
  );
}

function Submit() {
  return (
    <button type="submit" className={actionButton}>
      บันทึกค่าใหม่
    </button>
  );
}

/* ── The picker, when no item has been chosen yet ──────────────────────────────────────
 * A plain GET form: submitting rewrites the URL to `?set=<item>`, which is what the row
 * action links to directly. Two ways in, one destination. */
export function ChooseItemSheet({
  catalogue,
  closeHref,
}: {
  catalogue: CatalogueRow[];
  closeHref: string;
}) {
  const products = catalogue.filter((c) => c.kind === "PRODUCT");
  const items = catalogue.filter((c) => c.kind === "PACKAGING_ITEM");

  return (
    <Sheet title="ตั้งค่าใหม่" closeHref={closeHref}>
      <form
        method="get"
        className="flex flex-col gap-3 sm:flex-row sm:items-end"
      >
        <div className="flex-1">
          <Field label="เลือกรายการที่จะตั้งค่า">
            <select name="set" required defaultValue="" className={control}>
              <option value="" disabled>
                — เลือก —
              </option>
              <optgroup label="ค่ารมควัน">
                <option value="SMOKE_FEE_TIER:smoke_fee_tiers:">
                  ขั้นค่ารมควันตามน้ำหนัก (ทั้งชุด)
                </option>
              </optgroup>
              {products.length > 0 ? (
                <optgroup label="ราคาสินค้า">
                  {products.map((p) => (
                    <option key={p.id} value={`PRODUCT_PRICE:${p.id}:`}>
                      {p.name_th}
                    </option>
                  ))}
                </optgroup>
              ) : null}
              {items.length > 0 ? (
                <optgroup label="สต๊อกเต็มของวัสดุ">
                  {items.map((i) => (
                    <option key={i.id} value={`FULL_STOCK:${i.id}:`}>
                      {i.name_th}
                    </option>
                  ))}
                </optgroup>
              ) : null}
              {Object.entries(GROUP_LABEL).map(([group, label]) => {
                const keys = CONFIG_KEYS.filter((k) => k.group === group);
                if (keys.length === 0) return null;
                return (
                  <optgroup key={group} label={label}>
                    {keys.map((k) => (
                      <option key={k.key} value={`CONFIG:${k.key}:`}>
                        {k.label_th}
                        {k.deferred ? " (ยังไม่ใช้ในรอบนี้)" : ""}
                      </option>
                    ))}
                  </optgroup>
                );
              })}
            </select>
          </Field>
        </div>
        <button type="submit" className={cn(actionButton, "shrink-0")}>
          ต่อไป
        </button>
      </form>
      {products.length === 0 && items.length === 0 ? (
        <p className="text-caption text-text-muted">
          ยังไม่มีสินค้าหรือวัสดุในระบบ จึงตั้งราคาและสต๊อกเต็มยังไม่ได้
        </p>
      ) : null}
    </Sheet>
  );
}

/* ── The value form, once an item is chosen ─────────────────────────────────────────── */
export function NewValueSheet({
  source,
  itemKey,
  scopeLocationId,
  catalogue,
  backHref,
  closeHref,
}: {
  source: string;
  itemKey: string;
  scopeLocationId: string | null;
  catalogue: CatalogueRow[];
  /** Where the action returns to, carrying `?saved` or `?err`. */
  backHref: string;
  closeHref: string;
}) {
  const branches = catalogue.filter((c) => c.kind === "LOCATION");
  const named = (id: string) =>
    catalogue.find((c) => c.id === id)?.name_th ?? id;

  if (source === "PRODUCT_PRICE") {
    return (
      <Sheet
        title={`ตั้งราคาใหม่ · ${named(itemKey)}`}
        subtitle="ราคาขายบังคับ ต้นทุนเว้นว่างได้เมื่อต้นทุนมาจากล็อต (R30)"
        closeHref={closeHref}
      >
        <form action={submitProductPrice} className="grid gap-3 sm:grid-cols-2">
          <input type="hidden" name="back" value={backHref} />
          <input type="hidden" name="product_id" value={itemKey} />
          <DateField />
          <Field label="ราคาขาย (บาท)">
            <input
              type="text"
              inputMode="decimal"
              name="price_thb"
              required
              className={control}
            />
          </Field>
          <Field
            label="ต้นทุน (บาท)"
            hint="เว้นว่าง = ต้นทุนมาจากล็อต ไม่ใช่ 0"
          >
            <input
              type="text"
              inputMode="decimal"
              name="cost_thb"
              className={control}
            />
          </Field>
          <div className="sm:col-span-2">
            <Submit />
          </div>
        </form>
      </Sheet>
    );
  }

  if (source === "FULL_STOCK") {
    return (
      <Sheet
        title={`ตั้งสต๊อกเต็มใหม่ · ${named(itemKey)}`}
        subtitle="ต้องมากกว่า 0 — “ยังไม่กำหนด” คือไม่มีแถว ไม่ใช่ 0 (R9)"
        closeHref={closeHref}
      >
        <form action={submitFullStock} className="grid gap-3 sm:grid-cols-2">
          <input type="hidden" name="back" value={backHref} />
          <input type="hidden" name="packaging_item_id" value={itemKey} />
          <DateField />
          <Field label="จำนวนเมื่อสต๊อกเต็ม">
            <input
              type="text"
              inputMode="decimal"
              name="full_stock_qty"
              required
              className={control}
            />
          </Field>
          <Field label="ใช้กับสาขา" hint="เว้นว่าง = ใช้กับทุกที่">
            <select
              name="location_id"
              defaultValue={scopeLocationId ?? ""}
              className={control}
            >
              <option value="">ทุกที่</option>
              {branches.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name_th}
                </option>
              ))}
            </select>
          </Field>
          <div className="sm:col-span-2">
            <Submit />
          </div>
        </form>
      </Sheet>
    );
  }

  const meta = configKey(itemKey);
  if (!meta) {
    return (
      <Sheet title="ไม่รู้จักรายการนี้" closeHref={closeHref}>
        <p className="text-body text-text-secondary">
          รายการ <code>{itemKey}</code> ไม่อยู่ในรายการค่าตั้งต้นที่ระบบรู้จัก
        </p>
      </Sheet>
    );
  }

  return (
    <Sheet
      title={`ตั้งค่าใหม่ · ${meta.label_th}`}
      subtitle={meta.hint_th}
      closeHref={closeHref}
    >
      {meta.deferred ? (
        <p className="rounded-md border border-border bg-surface-sunken p-3 text-caption text-text-secondary">
          รอบนี้ยังไม่มีรายงานไหนอ่านค่านี้ (D04) กรอกไว้ได้
          แต่ยังไม่มีผลกับตัวเลขใด
        </p>
      ) : null}

      <form action={submitConfigValue} className="grid gap-3 sm:grid-cols-2">
        <input type="hidden" name="back" value={backHref} />
        <input type="hidden" name="key" value={meta.key} />
        <DateField />

        <Field
          label={meta.unit ? `ค่า (${meta.unit})` : "ค่า"}
          hint={meta.type === "json" ? "กรอกเป็น JSON" : undefined}
        >
          {meta.type === "boolean" ? (
            <select name="value" required defaultValue="" className={control}>
              <option value="" disabled>
                — เลือก —
              </option>
              <option value="true">เปิด</option>
              <option value="false">ปิด</option>
            </select>
          ) : meta.type === "json" ? (
            <textarea
              name="value"
              required
              rows={5}
              className={cn(control, "h-auto py-2 font-mono text-body-sm")}
            />
          ) : meta.type === "date" ? (
            <input type="date" name="value" required className={control} />
          ) : (
            <input
              type="text"
              name="value"
              required
              inputMode={meta.type === "numeric" ? "decimal" : "text"}
              className={control}
            />
          )}
        </Field>

        {meta.scopable ? (
          <Field label="ใช้กับสาขา" hint="เว้นว่าง = ใช้กับทุกสาขา">
            <select
              name="scope_location_id"
              defaultValue={scopeLocationId ?? ""}
              className={control}
            >
              <option value="">ทุกสาขา</option>
              {branches.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name_th}
                </option>
              ))}
            </select>
          </Field>
        ) : null}

        <Field label="หมายเหตุ">
          <input type="text" name="note" className={control} />
        </Field>

        <div className="sm:col-span-2">
          <Submit />
        </div>
      </form>
    </Sheet>
  );
}
