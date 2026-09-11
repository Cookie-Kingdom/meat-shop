import Link from "next/link";

import { actionButton, actionLink } from "@/components/ui/controls";
import {
  ChooseItemSheet,
  NewValueSheet,
} from "@/features/config/components/new-value-sheet";
import { SmokeFeeTierForm } from "@/features/config/components/smoke-fee-tier-form";
import { configKey, labelFor } from "@/features/config/keys";
import type { CatalogueRow, ConfigRow } from "@/features/config/types";
import { submitPackagingSeed } from "@/features/setup/actions";
import { ReadinessList } from "@/features/setup/components/readiness-list";
import { one } from "@/lib/params";
import { getReadiness } from "@/lib/rpc/setup";
import { createClient } from "@/lib/supabase/server";

/* /owner/setup — the first-run gate (card ^ref-61, ADR-023). "The OW 10 config screen
 * filtered to what is unset": the BLOCK items first, then WARN, then the values v0.2 already
 * confirmed, shown for the Owner to check rather than as empty fields.
 *
 * An L1 with any BLOCK item unset lands here at sign-in (`features/auth/actions.ts`), may
 * skip, and then carries the banner from `(owner)/template.tsx` on every page.
 *
 * NOTHING ON THIS PAGE ENFORCES. Every BLOCK item still raises CONFIG_NOT_SET from its RPC
 * (R35) — this page only says so, and offers the form.
 *
 * THE FORMS ARE OW 10's, NOT COPIES. `?set=` is ^ref-12's URL contract, and NewValueSheet /
 * SmokeFeeTierForm / ChooseItemSheet render here with `back` pointed at /owner/setup, so a
 * saved value returns the Owner to this list with its row cleared. One set of forms, one set
 * of writers, one place a validation rule can live. The smoke fee is entered in บาท/กรัม and
 * stored in บาท/กก. by that form (ADR-024).
 *
 * The role gate is the (owner) layout's `requireRole` plus the views' own WHERE (R34):
 * `v_config_history` and `v_config_catalogue` read zero rows for anyone but L1. */

const BACK = "/owner/setup";

/** `SOURCE:item_key:scope`, split the way OW 10 splits it. */
function parseItemId(raw: string) {
  const first = raw.indexOf(":");
  const last = raw.lastIndexOf(":");
  if (first < 0 || last <= first) return null;
  return {
    source: raw.slice(0, first),
    itemKey: raw.slice(first + 1, last),
    scopeLocationId: raw.slice(last + 1) || null,
  };
}

/** A seeded value as the Owner reads it: a boolean as เปิด / ปิด, anything else with its unit. */
function seededValue(row: ConfigRow): string {
  const meta = configKey(row.item_key);
  if (meta?.type === "boolean") return row.value_json === true ? "เปิด" : "ปิด";
  const unit = meta?.unit ? ` ${meta.unit}` : "";
  return `${row.value_display ?? "—"}${unit}`;
}

export default async function SetupPage(props: PageProps<"/owner/setup">) {
  const params = await props.searchParams;
  const set = one(params.set);
  const saved = one(params.saved);
  const err = one(params.err);

  const supabase = await createClient();
  const [readiness, historyRes, catalogueRes] = await Promise.all([
    getReadiness(),
    supabase.from("v_config_history").select("*").eq("is_current", true),
    supabase.from("v_config_catalogue").select("*"),
  ]);

  const current = (historyRes.data ?? []) as ConfigRow[];
  const catalogue = (catalogueRes.data ?? []) as CatalogueRow[];
  const readError =
    readiness.error ??
    historyRes.error?.message ??
    catalogueRes.error?.message ??
    null;

  const block = readiness.rows.filter((r) => r.severity === "BLOCK");
  const warn = readiness.rows.filter((r) => r.severity === "WARN");
  const missing = block.filter((r) => !r.is_set).length;

  /* A seed row is the only row with no author — …0024's biconditional makes that exact. */
  const seeded = current
    .filter((r) => r.source === "CONFIG" && r.created_by === null)
    .map((r) => ({ row: r, label: labelFor(r.source, r.item_key, r.item_key) }))
    .sort((a, b) => a.label.localeCompare(b.label, "th"));

  const hasPackaging = catalogue.some((c) => c.kind === "PACKAGING_ITEM");
  const target = set && set !== "1" ? parseItemId(set) : null;

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-h1 text-text-primary">ตั้งค่าเริ่มต้น</h1>
        <Link href="/owner" className={actionLink}>
          ข้ามไปก่อน →
        </Link>
      </div>

      <p className="text-body-sm text-text-secondary">
        รายการด้านล่างเป็นตัวเลขที่มีแต่เจ้าของร้านรู้ ระบบไม่เดาค่าให้ —
        งานที่ต้องใช้ค่านั้นจะบันทึกไม่ได้จนกว่าจะตั้ง ข้ามไปก่อนได้
        แถบแจ้งเตือนจะอยู่ด้านบนทุกหน้าจนกว่าจะตั้งครบ
      </p>

      {saved ? (
        <p className="rounded-lg border border-success bg-success-subtle p-3 text-body-sm text-success">
          บันทึกแล้ว
        </p>
      ) : null}
      {err ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-3 text-body-sm text-danger">
          {err}
        </p>
      ) : null}
      {readError ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-3 text-body-sm text-danger">
          อ่านสถานะการตั้งค่าไม่สำเร็จ — {readError}
        </p>
      ) : null}

      {/* OW 10's own sheets, returning here. `?set=1` picks an item; `?set=SOURCE:key:scope`
          sets its value. */}
      {set === "1" ? (
        <ChooseItemSheet catalogue={catalogue} closeHref={BACK} />
      ) : null}
      {target?.source === "SMOKE_FEE_TIER" ? (
        <SmokeFeeTierForm
          current={current.find((r) => r.source === "SMOKE_FEE_TIER") ?? null}
          backHref={BACK}
          closeHref={BACK}
        />
      ) : target ? (
        <NewValueSheet
          source={target.source}
          itemKey={target.itemKey}
          scopeLocationId={target.scopeLocationId}
          catalogue={catalogue}
          backHref={BACK}
          closeHref={BACK}
        />
      ) : null}

      <section className="flex flex-col gap-3">
        <h2 className="text-h2 text-text-primary">
          ต้องตั้งก่อนใช้งาน
          <span className="ml-2 text-body-sm text-text-secondary">
            {missing > 0 ? `ยังขาด ${missing} รายการ` : "ครบแล้ว"}
          </span>
        </h2>
        <ReadinessList
          rows={block}
          emptyText="ไม่มีรายการที่ต้องตั้ง"
          extra={(row) =>
            row.item_key === "full_stock_qty" && !hasPackaging ? (
              /* The seven BR 08 materials, by the Owner's hand — never a migration
                 (PLAN-config-seed.md Finding 10). Shown only while none exists. */
              <form
                action={submitPackagingSeed}
                className="flex flex-col gap-1 pt-1"
              >
                <button type="submit" className={actionButton}>
                  เพิ่มวัสดุ 7 รายการตามข้อกำหนด
                </button>
                <span className="text-caption text-text-muted">
                  กล่องสกรีน กระดาษรอง ถุงซิปเนื้อ ถุงซิปข้าว ถุงหิ้วกระดาษ
                  สติกเกอร์โลโก้ การ์ด/สติกเกอร์วิธีอุ่น —
                  จากนั้นตั้งสต๊อกเต็มทีละรายการ
                </span>
              </form>
            ) : null
          }
        />
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-h2 text-text-primary">ควรตั้ง — ระบบยังทำงานได้</h2>
        <ReadinessList rows={warn} emptyText="ไม่มีรายการที่ควรตั้ง" />
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-h2 text-text-primary">ค่าที่ข้อกำหนดยืนยันแล้ว</h2>
        <p className="text-body-sm text-text-secondary">
          ระบบใส่ค่าเหล่านี้ไว้ให้ตามข้อกำหนดที่ลูกค้ายืนยัน (v0.2) ตรวจดูได้เลย
          ถ้าถูกต้องไม่ต้องทำอะไร ถ้าต้องการเปลี่ยน
          ให้ตั้งค่าใหม่พร้อมวันที่เริ่มใช้ —
          ค่าเดิมยังใช้กับวันก่อนหน้านั้นเสมอ
        </p>
        {seeded.length === 0 ? (
          <p className="rounded-lg border border-border bg-surface p-4 text-body-sm text-text-secondary">
            ไม่มีค่าตั้งต้นที่ยังใช้อยู่ — ทุกค่าถูกตั้งใหม่โดยเจ้าของร้านแล้ว
          </p>
        ) : (
          <ul className="flex flex-col gap-3">
            {seeded.map(({ row, label }) => (
              <li
                key={row.row_id}
                className="flex min-h-[72px] flex-col gap-2 rounded-lg border border-border bg-surface p-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div className="flex flex-col gap-1">
                  <span className="text-label text-text-primary">{label}</span>
                  <span className="text-body-sm text-text-secondary tabular-nums">
                    {seededValue(row)}
                  </span>
                </div>
                <Link
                  href={`${BACK}?${new URLSearchParams({ set: `CONFIG:${row.item_key}:` }).toString()}`}
                  className={actionLink}
                >
                  ตั้งค่าใหม่
                </Link>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
