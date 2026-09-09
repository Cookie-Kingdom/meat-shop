"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import {
  newIdempotencyKey,
  setConfig,
  setPackagingFullStock,
  setProductPrice,
  setSmokeFeeTier,
  type RpcResult,
  type TierBand,
} from "@/lib/rpc/config";
import { configKey } from "./keys";

/* OW 10 write path (card ^ref-12).
 *
 * THE IDEMPOTENCY KEY IS MINTED HERE, once per submit, and never during render (R38,
 * ADR-005). A key generated in a component is a new key on every re-render, so the retry it
 * exists to make safe becomes a second row.
 *
 * The refusal comes back as a Thai sentence in the URL, not as a thrown error: a config
 * write that is refused has to be readable by the Owner, who is the person who decides what
 * to do about it. CONFIG_DUPLICATE_DATE is the one that will actually happen — the same-day
 * correction append-only has no answer for.
 */

const str = (form: FormData, name: string) =>
  (form.get(name) ?? "").toString().trim();

/** Back to the screen, carrying the outcome. `err` is already Thai. */
function finish(result: RpcResult, back: string): never {
  const q = new URLSearchParams();
  if (result.ok) q.set("saved", "1");
  else q.set("err", result.message);
  revalidatePath("/owner/config");
  redirect(`${back}${back.includes("?") ? "&" : "?"}${q.toString()}`);
}

/** Parse a decimal the Owner typed. Returns null for anything that is not a finite number,
 * so a typo lands on the "กรอกตัวเลข" branch instead of being sent as NaN. */
function num(value: string): number | null {
  if (value === "") return null;
  const n = Number(value.replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

export async function submitConfigValue(form: FormData) {
  const back = str(form, "back") || "/owner/config";
  const key = str(form, "key");
  const effectiveFrom = str(form, "effective_from");
  const raw = str(form, "value");
  const scope = str(form, "scope_location_id");
  const note = str(form, "note");

  const meta = configKey(key);
  if (!meta) {
    finish(
      { ok: false, code: "UNKNOWN_KEY", message: "ไม่รู้จักรายการนี้" },
      back,
    );
  }

  /* The catalogue decides which column the value goes in, not the form. A boolean typed
   * into value_text becomes 'TRUE' / '1' / 'yes' inside a year; jsonb has the type. */
  const args = {
    idempotencyKey: newIdempotencyKey(),
    key,
    effectiveFrom,
    scopeLocationId: scope || null,
    note: note || null,
  };

  switch (meta.type) {
    case "numeric": {
      const n = num(raw);
      if (n === null) {
        finish(
          { ok: false, code: "NOT_A_NUMBER", message: "กรอกเป็นตัวเลข" },
          back,
        );
      }
      finish(await setConfig({ ...args, valueNumeric: n }), back);
      break;
    }
    case "boolean":
      finish(await setConfig({ ...args, valueJson: raw === "true" }), back);
      break;
    case "json": {
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch {
        finish(
          { ok: false, code: "BAD_JSON", message: "รูปแบบ JSON ไม่ถูกต้อง" },
          back,
        );
      }
      finish(await setConfig({ ...args, valueJson: parsed }), back);
      break;
    }
    /* A date key is stored as text on purpose: config_settings has numeric, text and jsonb
     * and no date column, and `opening_cutoff_date` is read by a function that casts it. A
     * fourth column for one key is a migration this card does not need. */
    default:
      if (raw === "") {
        finish({ ok: false, code: "EMPTY", message: "กรอกค่าก่อน" }, back);
      }
      finish(await setConfig({ ...args, valueText: raw }), back);
  }
}

export async function submitProductPrice(form: FormData) {
  const back = str(form, "back") || "/owner/config";
  const price = num(str(form, "price_thb"));
  const costRaw = str(form, "cost_thb");

  if (price === null) {
    finish(
      { ok: false, code: "NOT_A_NUMBER", message: "กรอกราคาเป็นตัวเลข" },
      back,
    );
  }
  /* cost_thb null is deliberate, not missing (R30) — the cost comes from the lot for a
   * meat line. An empty field means null; it must not become 0. */
  const cost = costRaw === "" ? null : num(costRaw);
  if (costRaw !== "" && cost === null) {
    finish(
      { ok: false, code: "NOT_A_NUMBER", message: "กรอกต้นทุนเป็นตัวเลข" },
      back,
    );
  }

  finish(
    await setProductPrice({
      idempotencyKey: newIdempotencyKey(),
      productId: str(form, "product_id"),
      effectiveFrom: str(form, "effective_from"),
      priceThb: price,
      costThb: cost,
    }),
    back,
  );
}

export async function submitFullStock(form: FormData) {
  const back = str(form, "back") || "/owner/config";
  const qty = num(str(form, "full_stock_qty"));

  if (qty === null) {
    finish(
      { ok: false, code: "NOT_A_NUMBER", message: "กรอกจำนวนเป็นตัวเลข" },
      back,
    );
  }

  finish(
    await setPackagingFullStock({
      idempotencyKey: newIdempotencyKey(),
      packagingItemId: str(form, "packaging_item_id"),
      effectiveFrom: str(form, "effective_from"),
      fullStockQty: qty,
      locationId: str(form, "location_id") || null,
    }),
    back,
  );
}

export async function submitSmokeFeeTier(form: FormData) {
  const back = str(form, "back") || "/owner/config";

  /* The whole band set at one date, never one band (D02, R37). A gap is a property of the
   * set, so the form posts every band and the function validates them together — it refuses
   * a partial write, and a per-band editor could not see a gap anyway.
   *
   * ADR-024: the Owner quotes the fee in บาท/กรัม and the table stores บาท/กก. The ×1000
   * happens here, once, on the way in. */
  const mins = form.getAll("min_weight_kg").map((v) => v.toString().trim());
  const maxes = form.getAll("max_weight_kg").map((v) => v.toString().trim());
  const rates = form.getAll("rate_thb_per_g").map((v) => v.toString().trim());
  const bases = form.getAll("rate_basis").map((v) => v.toString().trim());

  const tiers: TierBand[] = [];
  for (let i = 0; i < mins.length; i++) {
    if (mins[i] === "" && rates[i] === "") continue; // a blank row the Owner left alone
    const min = num(mins[i]);
    const perGram = num(rates[i]);
    if (min === null || perGram === null) {
      finish(
        {
          ok: false,
          code: "NOT_A_NUMBER",
          message: `ขั้นที่ ${i + 1}: กรอกน้ำหนักและค่ารมควันเป็นตัวเลข`,
        },
        back,
      );
    }
    const basis = bases[i] === "FLAT" ? "FLAT" : "PER_KG";
    tiers.push({
      min_weight_kg: min,
      max_weight_kg: maxes[i] === "" ? null : num(maxes[i]),
      rate_thb: basis === "PER_KG" ? perGram * 1000 : perGram,
      rate_basis: basis,
    });
  }

  finish(
    await setSmokeFeeTier({
      idempotencyKey: newIdempotencyKey(),
      effectiveFrom: str(form, "effective_from"),
      tiers,
    }),
    back,
  );
}
