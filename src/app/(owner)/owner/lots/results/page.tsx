import Link from "next/link";

import { actionLink } from "@/components/ui/controls";
import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { CostBreakdown } from "@/features/cost/components/cost-breakdown";
import { SmokeFeeOverrideForm } from "@/features/cost/components/smoke-fee-override-form";
import { StatusBadge } from "@/features/cost/components/status-badge";
import { YieldFigures } from "@/features/cost/components/yield-figures";
import { DASH, pct, thb } from "@/features/cost/format";
import {
  LOT_STATE_TH,
  type FreightLineRow,
  type LotCostRow,
  type LotYieldRow,
} from "@/features/cost/types";
import { thaiDate } from "@/lib/format/date";
import { one } from "@/lib/params";
import { createClient } from "@/lib/supabase/server";

/* OW 04 — ผล Lot และ Alert (card ^ref-33). v0.2: "ไม่ต้องกรอก ดูผลและเปิดรายละเอียดเมื่อมี
 * Alert — สรุป Yield, Loss เทียบเกณฑ์". PRODUCT F7: the Owner opens detail only when there is
 * an alert, so alerting lots sort first and carry the danger badge.
 *
 * Every figure traces to a source record (F13, the card's acceptance): the yield block names
 * the four weights and the PO; the cost block names each part's inputs and every freight line.
 *
 * The one write is the smoke-fee override (ADR-024, R41), through fn_set_smoke_fee_override
 * via `src/lib/rpc/cost.ts` — never `supabase.from()`. `?override=1` opens its sheet.
 *
 * THE ROLE GATE IS NOT HERE. v_lot_yield, v_lot_cost and v_freight_allocation are L1-only in
 * their WHERE; the (owner) layout's requireRole is the mirror (ADR-004).
 *
 * ponytail: every closed lot in one read, newest first, with its cost row fetched by id. A
 * closed-lot count is in the hundreds per year. Ceiling: a few hundred; upgrade path is a
 * `.range()` page plus a date filter.
 */

const BASE = "/owner/lots/results";

export default async function LotResultsPage(
  props: PageProps<"/owner/lots/results">,
) {
  const params = await props.searchParams;
  const lotId = one(params.lot);
  const override = one(params.override) === "1";
  const alertsOnly = one(params.alert) === "1";
  const saved = one(params.saved);
  const err = one(params.err);

  const supabase = await createClient();

  const yieldRes = await supabase
    .from("v_lot_yield")
    .select("*")
    .order("closed_at", { ascending: false });
  const yields = (yieldRes.data ?? []) as LotYieldRow[];

  const ids = yields.map((y) => y.lot_id);
  const costRes =
    ids.length > 0
      ? await supabase.from("v_lot_cost").select("*").in("lot_id", ids)
      : { data: [], error: null };
  const costs = new Map(
    ((costRes.data ?? []) as LotCostRow[]).map((c) => [c.lot_id, c]),
  );
  const listError = yieldRes.error ?? costRes.error;

  // Alerts first, newest first within each — the rows the Owner has to look at on top.
  const rows = [...yields]
    .filter((y) => !alertsOnly || y.yield_alert)
    .sort((a, b) => Number(b.yield_alert) - Number(a.yield_alert));

  const selected = yields.find((y) => y.lot_id === lotId) ?? null;
  const selectedCost = selected ? (costs.get(selected.lot_id) ?? null) : null;

  const freightRes = selected
    ? await supabase
        .from("v_freight_allocation")
        .select("*")
        .eq("lot_id", selected.lot_id)
        .order("event_date")
    : null;
  const freight = (freightRes?.data ?? []) as FreightLineRow[];

  const detailHref = (id: string) =>
    `${BASE}?lot=${id}${alertsOnly ? "&alert=1" : ""}`;
  const listHref = alertsOnly ? `${BASE}?alert=1` : BASE;

  const columns: Column<LotYieldRow>[] = [
    {
      id: "lot",
      header: "ล็อต",
      priority: 1,
      cell: (r) => (
        <Link
          href={detailHref(r.lot_id)}
          className="text-accent hover:underline"
        >
          {r.lot_code}
        </Link>
      ),
    },
    {
      id: "alert",
      header: "",
      priority: 1,
      cell: (r) =>
        r.yield_alert ? (
          <StatusBadge tone="danger">Loss เกินเกณฑ์</StatusBadge>
        ) : (
          <StatusBadge>ปกติ</StatusBadge>
        ),
    },
    {
      id: "closed",
      header: "ปิดเมื่อ",
      cell: (r) => (r.closed_at ? thaiDate(r.closed_at) : DASH),
    },
    {
      id: "loss",
      header: "Loss หลัก",
      numeric: true,
      cell: (r) => pct(r.loss_pct),
    },
    {
      id: "smoke",
      header: "Smoke Yield",
      numeric: true,
      cell: (r) =>
        r.smoke_yield_pct === null ? "ข้อมูลไม่ครบ" : pct(r.smoke_yield_pct),
    },
    {
      id: "cost",
      header: "ต้นทุนรวม",
      numeric: true,
      cell: (r) => {
        const c = costs.get(r.lot_id);
        if (!c) return DASH;
        return c.is_complete
          ? thb(c.total_cost_thb)
          : `${thb(c.total_cost_thb)} (ชั่วคราว)`;
      },
    },
  ];

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-h1 text-text-primary">ผลล็อตและต้นทุน</h1>
        <Link href="/owner/lots" className={actionLink}>
          ← ล็อตที่กำลังผลิต
        </Link>
      </div>

      {saved ? (
        <p className="rounded-lg border border-success bg-success-subtle p-3 text-body-sm text-success">
          บันทึกค่ารมควันของล็อตนี้แล้ว
        </p>
      ) : null}
      {err ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-3 text-body-sm text-danger">
          {err}
        </p>
      ) : null}

      <nav className="flex flex-wrap gap-2">
        <Link
          href={BASE}
          className={alertsOnly ? actionLink : `${actionLink} underline`}
        >
          ทุกล็อต
        </Link>
        <Link
          href={`${BASE}?alert=1`}
          className={alertsOnly ? `${actionLink} underline` : actionLink}
        >
          เฉพาะที่มีแจ้งเตือน
        </Link>
      </nav>

      {listError ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-4 text-body text-danger">
          อ่านผลล็อตไม่สำเร็จ — {listError.message}
        </p>
      ) : (
        <ResponsiveTable
          columns={columns}
          rows={rows}
          keyField={(r) => r.lot_id}
          isMuted={(r) => r.lot_id === selected?.lot_id}
          emptyState={
            <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
              {alertsOnly
                ? "ไม่มีล็อตที่ Loss เกินเกณฑ์"
                : "ยังไม่มีล็อตที่ปิดแล้ว"}
            </p>
          }
        />
      )}

      {selected ? (
        <div className="flex flex-col gap-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex flex-wrap items-center gap-2">
              <h2 className="text-h2 text-text-primary">
                ล็อต {selected.lot_code}
              </h2>
              <StatusBadge>
                {LOT_STATE_TH[selected.state] ?? selected.state}
              </StatusBadge>
            </div>
            <Link href={listHref} className={actionLink}>
              ปิดรายละเอียด
            </Link>
          </div>

          {override && selectedCost ? (
            <SmokeFeeOverrideForm
              row={selectedCost}
              backHref={detailHref(selected.lot_id)}
              closeHref={detailHref(selected.lot_id)}
            />
          ) : null}

          <YieldFigures row={selected} />

          {selectedCost ? (
            <CostBreakdown
              row={selectedCost}
              freight={freight}
              overrideHref={`${detailHref(selected.lot_id)}&override=1`}
            />
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
