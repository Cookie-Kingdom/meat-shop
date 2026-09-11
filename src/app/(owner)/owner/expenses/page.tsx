import Link from "next/link";

import { actionButton, actionLink } from "@/components/ui/controls";
import type { CatalogueRow } from "@/features/config/types";
import {
  ChooseKindSheet,
  ExpenseForm,
} from "@/features/expenses/components/expense-form";
import { ExpenseList } from "@/features/expenses/components/expense-list";
import {
  isMonth,
  shiftMonth,
  thaiMonth,
  thb,
} from "@/features/expenses/format";
import { isKind, type ExpenseRow } from "@/features/expenses/types";
import { todayBangkok } from "@/lib/format/date";
import { one } from "@/lib/params";
import { createClient } from "@/lib/supabase/server";

/* OW 09 — owner expenses and investment (card ^ref-54, M11, F12).
 *
 * The Owner records rent, equipment and other central spend without a developer: pick a หมวด,
 * type an amount, a date and a detail written for matching the bank transfer, save.
 *
 * THE ROLE GATE IS NOT HERE. v_owner_expenses returns zero rows to anyone but L1 (R34), and
 * fn_record_owner_expense refuses anyone but L1 by name. The (owner) layout's requireRole 403s
 * the rest first, but that is the mirror (ADR-004; M11 AC "L2/L3 ไม่เข้าถึงข้อมูลบัญชี Owner").
 *
 * ONE MONTH AT A TIME, by pnl_month — the month the P&L books a row in: a monthly cost's own
 * month, otherwise the month it was paid (ADR-020, …0025). The total is the view's
 * month_total_thb, summed in the database, never in TypeScript.
 *
 * The scope sentence is on the page's face because M11's AC is a promise about the profit
 * formula: recording here does not change round one, which leaves out central overhead,
 * labour and tax (D04, UAT-17).
 *
 * Server Component, no client JavaScript: month, the open sheet and the outcome all live in
 * searchParams, and the form posts to a Server Action.
 */

export default async function ExpensesPage(
  props: PageProps<"/owner/expenses">,
) {
  const params = await props.searchParams;
  const rawMonth = one(params.month);
  const month = isMonth(rawMonth) ? rawMonth : todayBangkok().slice(0, 7);
  const opening = one(params.new);
  const saved = one(params.saved);
  const err = one(params.err);

  const supabase = await createClient();
  const [rowsRes, catalogueRes] = await Promise.all([
    supabase
      .from("v_owner_expenses")
      .select("*")
      .eq("pnl_month", month)
      .order("event_date", { ascending: false })
      .order("created_at", { ascending: false }),
    supabase.from("v_config_catalogue").select("*").eq("kind", "LOCATION"),
  ]);

  const rows = (rowsRes.data ?? []) as ExpenseRow[];
  // Central is the empty choice; everything else a row may be charged to.
  const locations = ((catalogueRes.data ?? []) as CatalogueRow[]).filter(
    (l) => l.unit !== "CENTRAL",
  );
  const error = rowsRes.error ?? catalogueRes.error;
  const total = rows[0]?.month_total_thb ?? null;

  const here = (over: Record<string, string>) =>
    `/owner/expenses?${new URLSearchParams({ month, ...over }).toString()}`;
  const closeHref = here({});

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-h1 text-text-primary">ค่าใช้จ่ายและเงินลงทุน</h1>
        <Link href={here({ new: "1" })} className={actionButton}>
          บันทึกรายการ
        </Link>
      </div>

      <p className="text-body-sm text-text-secondary">
        บันทึกไว้เพื่อตรวจกับรายการโอนและดูต้นทุนตามหมวด —
        ไม่เปลี่ยนสูตรกำไรรอบแรก ซึ่งยังไม่รวมค่าใช้จ่ายส่วนกลาง ค่าแรง และภาษี
        · เงินลงทุนลงเต็มจำนวนในเดือนที่ซื้อ ไม่คิดค่าเสื่อม
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

      {opening === "1" ? (
        <ChooseKindSheet
          hrefFor={(kind) => here({ new: kind })}
          closeHref={closeHref}
        />
      ) : isKind(opening) ? (
        <ExpenseForm
          kind={opening}
          locations={locations}
          closeHref={closeHref}
        />
      ) : null}

      <nav
        aria-label="เลือกเดือน"
        className="flex items-center justify-between gap-3 rounded-lg border border-border bg-surface px-4 py-2"
      >
        <Link
          href={here({ month: shiftMonth(month, -1) })}
          className={actionLink}
        >
          ← ก่อนหน้า
        </Link>
        <div className="flex flex-col items-center">
          <span className="text-label text-text-primary">
            {thaiMonth(month)}
          </span>
          <span className="text-caption text-text-secondary tabular-nums">
            รวม {thb(total)} บาท
          </span>
        </div>
        <Link
          href={here({ month: shiftMonth(month, 1) })}
          className={actionLink}
        >
          ถัดไป →
        </Link>
      </nav>

      {error ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-4 text-body text-danger">
          อ่านรายการไม่สำเร็จ — {error.message}
        </p>
      ) : (
        <ExpenseList
          rows={rows}
          emptyState={
            <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
              ยังไม่มีรายการของเดือน{thaiMonth(month)} — กด “บันทึกรายการ”
              เพื่อเริ่ม
            </p>
          }
        />
      )}
    </div>
  );
}
