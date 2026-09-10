import Link from "next/link";

import { actionButton, actionLink } from "@/components/ui/controls";
import { configAt } from "@/features/config/resolve";
import { NewPoSheet } from "@/features/purchasing/components/new-po-sheet";
import { PoList } from "@/features/purchasing/components/po-list";
import { PoSheet } from "@/features/purchasing/components/po-sheet";
import {
  listChefHouses,
  listPoRegister,
  listRounds,
  listSuppliers,
} from "@/features/purchasing/queries";
import { todayBangkok } from "@/lib/format/date";
import { one } from "@/lib/params";
import { createClient } from "@/lib/supabase/server";

/* OW 01 — สั่งซื้อเนื้อ (card ^ref-20, F4 / M1). Skeleton: the S8 list with S1 sheets over
 * it, opened through the URL like OW 10's. `?new=1` is the create sheet and `?po=<id>` is one
 * PO with its rounds. Server Components throughout, with one client island for the live total.
 *
 * THE ROLE GATE IS NOT HERE. Every read is a view whose WHERE is `fn_current_role() =
 * 'L1_OWNER'` (R34), and both writes are fn_* that call fn_require_owner. The (owner)
 * layout's requireRole 403s other roles first, but that is the mirror (ADR-004). Delete it
 * and an L3 still reads zero rows — purchasing_screen_test.sql TC-S02.
 *
 * THE IDEMPOTENCY KEY IS MINTED HERE, ONCE PER RENDER (PLAN-purchasing.md P5). A Server
 * Component renders once per request, so the key is stable for the page the Owner is
 * looking at. A double tap posts it twice and the function replays. After a refusal the
 * action hands the same key back in `?k=`, so a retry of a write that may have landed
 * replays instead of duplicating.
 */

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const ECHO_FIELDS = [
  "supplier_id",
  "event_date",
  "ordered_weight_kg",
  "unit_price_thb_per_kg",
  "brine_pct_offered",
  "brine_cost_thb",
  "foodiva_sent_weight_kg",
  "chef_house_location_id",
  "note",
];

export default async function PurchasingPage(
  props: PageProps<"/owner/purchasing">,
) {
  const params = await props.searchParams;
  const isNew = one(params.new) === "1";
  const poId = UUID.test(one(params.po)) ? one(params.po) : "";
  const saved = one(params.saved);
  const err = one(params.err);
  const returnedKey = one(params.k);
  const idempotencyKey = UUID.test(returnedKey)
    ? returnedKey
    : crypto.randomUUID();
  const echo = Object.fromEntries(ECHO_FIELDS.map((f) => [f, one(params[f])]));
  const today = todayBangkok();

  const db = await createClient();
  const [register, suppliers, rounds, chefHouses, brinePct] = await Promise.all([
    listPoRegister(db),
    isNew ? listSuppliers(db) : null,
    poId ? listRounds(db, poId) : null,
    poId ? listChefHouses(db) : null,
    // Resolved at today, the order date the form defaults to. It is a prefill the Owner can
    // change, not a value the write depends on.
    isNew ? configAt(db, "brine_pct_of_meat", today) : null,
  ]);

  const readError =
    register.error ?? suppliers?.error ?? rounds?.error ?? chefHouses?.error;
  const po = poId ? (register.rows.find((r) => r.po_id === poId) ?? null) : null;
  const closeHref = "/owner/purchasing";

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-h1 text-text-primary">สั่งซื้อเนื้อ (PO)</h1>
        <div className="flex flex-wrap items-center gap-3">
          <Link href="/owner/transport?new=1" className={actionLink}>
            ส่งรถขาไป (OW 02) →
          </Link>
          <Link href="/owner/purchasing?new=1" className={actionButton}>
            สร้าง PO ใหม่
          </Link>
        </div>
      </div>

      <p className="text-body-sm text-text-secondary">
        PO หนึ่งใบแบ่งส่งได้หลายรอบ ทุกหนึ่งรอบส่งสร้างล็อตใหม่ผูกกับ PO เดิม
        ยอดส่งสะสมและยอดค้างส่งคำนวณจากรอบส่งจริงเท่านั้น (D01)
      </p>

      {saved === "po" ? (
        <p className="rounded-lg border border-success bg-success-subtle p-3 text-body-sm text-success">
          บันทึก PO แล้ว — บันทึกรอบส่งแรกได้ด้านล่าง
        </p>
      ) : null}
      {err ? (
        <p
          role="alert"
          className="rounded-lg border border-danger bg-danger-subtle p-3 text-body-sm text-danger"
        >
          {err}
        </p>
      ) : null}
      {readError ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-4 text-body text-danger">
          อ่านข้อมูลการสั่งซื้อไม่สำเร็จ — {readError}
        </p>
      ) : null}

      {isNew && suppliers ? (
        <NewPoSheet
          suppliers={suppliers.rows}
          idempotencyKey={idempotencyKey}
          today={today}
          brinePctDefault={
            brinePct?.value_numeric != null
              ? Number(brinePct.value_numeric).toFixed(2)
              : null
          }
          echo={echo}
          closeHref={closeHref}
        />
      ) : null}

      {poId ? (
        <PoSheet
          po={po}
          rounds={rounds?.rows ?? []}
          chefHouses={chefHouses?.rows ?? []}
          idempotencyKey={idempotencyKey}
          today={today}
          savedLotId={saved === "round" ? one(params.lot) : ""}
          echo={echo}
          closeHref={closeHref}
        />
      ) : null}

      <PoList
        rows={register.rows}
        hrefFor={(id) => `/owner/purchasing?po=${id}`}
      />
    </div>
  );
}
