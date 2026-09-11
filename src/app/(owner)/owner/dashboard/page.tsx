import Link from "next/link";

import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { actionLink } from "@/components/ui/controls";
import {
  ChartPanel,
  type ChartPoint,
} from "@/features/reports/components/chart-panel";
import { ExceptionList } from "@/features/reports/components/exception-list";
import { FilterBar } from "@/features/reports/components/filter-bar";
import { ScopeNote } from "@/features/reports/components/scope-note";
import {
  StatTile,
  type StatTileProps,
} from "@/features/reports/components/stat-tile";
import {
  buckets,
  isoDateOr,
  ratioPctCents,
  signedDp2,
  signOf,
  sumCents,
  toCents,
  unique,
} from "@/features/reports/format";
import {
  CATEGORY_TH,
  LABOUR_SCOPE_TH,
  OWNER_MEMO_SCOPE_TH,
  SCOPE_NOTE_TH,
  missingTh,
} from "@/features/reports/labels";
import type {
  CostCategory,
  CostRow,
  ExceptionKind,
  Num,
  PnlDayRow,
  PnlLotRow,
  PnlMonthRow,
} from "@/features/reports/types";
import { thaiDate, todayBangkok } from "@/lib/format/date";
import { kg } from "@/lib/format/number";
import { one } from "@/lib/params";
import { ReadError } from "@/components/shared/read-error";
import {
  readBranches,
  readCostBreakdown,
  readExceptions,
  readPnlDays,
  readPnlLots,
  readPnlMonths,
  readStockOnHand,
  readYieldDays,
} from "@/lib/rpc/reports";

/* OW 08 — Master dashboard (card ^ref-58; S7, M12, F13; PLAN-reporting K21).
 *
 * Tiles in S7's order — exceptions first, then sales, profit, yield loss, stock on hand — then
 * the two charts, the P&L table (?view=day|month|lot, 31 rows a page), the cost breakdown and the
 * owner-expense memo. Every tile links to the rows behind it (StatTile's `href` is required).
 *
 * THE PROFIT TILE SUMS CLOSED DAYS ONLY (Finding 15), so it carries one note, its ScopeNote, in
 * every state. A closed day with a missing input replaces the number with IncompleteDataNotice.
 * The sales tile counts every keyed sale, open days included: a keyed sale is a fact.
 *
 * NOTHING HERE DECIDES WHO SEES WHAT. Every view read is L1-only in its WHERE; the (owner)
 * layout's requireRole is the mirror (ADR-004). Range totals are exact hundredths (format.ts).
 */

const BASE = "/owner/dashboard";
const PAGE_SIZE = 31;
const CHART_MAX_POINTS = 62;
const ZERO = BigInt(0);

type View = "day" | "month" | "lot";

/** Exceptions that describe the present, shown whatever the range; the rest are dated events. */
const CURRENT_STATE: ExceptionKind[] = [
  "MATERIAL_LOW",
  "COUNT_VARIANCE_OPEN",
  "RECEIPT_OUTSTANDING",
  "LOT_COST_INCOMPLETE",
];

const CATEGORY_ORDER = Object.keys(CATEGORY_TH) as CostCategory[];

function Money({ value }: { value: Num }) {
  const cents = toCents(value);
  if (cents === null) return <>—</>;
  return (
    <span className={cents < ZERO ? "text-danger" : undefined}>
      {signedDp2(cents)} บาท
    </span>
  );
}

function Profit({
  row,
}: {
  row: {
    profit_round_one_thb: Num;
    is_complete: boolean;
    missing_inputs: string[];
  };
}) {
  // IncompleteDataNotice's rule in a table cell: the missing inputs replace the figure.
  return row.is_complete ? (
    <Money value={row.profit_round_one_thb} />
  ) : (
    <span className="text-warning">
      ข้อมูลไม่ครบ: {row.missing_inputs.map(missingTh).join(" · ")}
    </span>
  );
}

function dateRangeLabel(first: string, last: string) {
  return first === last
    ? thaiDate(first)
    : `${thaiDate(first)}–${thaiDate(last)}`;
}

export default async function DashboardPage(
  props: PageProps<"/owner/dashboard">,
) {
  const params = await props.searchParams;
  const today = todayBangkok();
  const from = isoDateOr(one(params.from), `${today.slice(0, 7)}-01`);
  const to = isoDateOr(one(params.to), today);
  const branch = one(params.branch);
  const lot = one(params.lot);
  const viewParam = one(params.view);
  const view: View =
    viewParam === "month" || viewParam === "lot" ? viewParam : "day";
  const page = Math.max(1, Number.parseInt(one(params.page), 10) || 1);
  const range = { from, to, locationId: branch || undefined };

  const [
    branchesR,
    daysR,
    monthsR,
    lotsR,
    costsR,
    yieldsR,
    exceptionsR,
    stockR,
  ] = await Promise.all([
    readBranches(),
    readPnlDays(range),
    readPnlMonths(range),
    readPnlLots(),
    readCostBreakdown({ ...range, lotId: lot || undefined }),
    readYieldDays(range),
    readExceptions(),
    readStockOnHand(branch || undefined),
  ]);
  const errors = [
    branchesR,
    daysR,
    monthsR,
    lotsR,
    costsR,
    yieldsR,
    exceptionsR,
    stockR,
  ]
    .map((r) => r.error)
    .filter((e): e is string => e !== null);

  const link = (over: Record<string, string>) => {
    const q = new URLSearchParams({ from, to, branch, lot, view, ...over });
    for (const [k, v] of [...q.entries()]) if (!v) q.delete(k);
    return `${BASE}?${q.toString()}`;
  };

  // ── tiles ────────────────────────────────────────────────────────────────────────────
  const days = daysR.rows;
  const exceptions = exceptionsR.rows.filter(
    (e) =>
      (CURRENT_STATE.includes(e.exception_kind) ||
        (e.occurred_on !== null &&
          e.occurred_on >= from &&
          e.occurred_on <= to)) &&
      (!branch || e.location_id === branch),
  );

  const revenue = sumCents(days.map((d) => d.revenue_thb));

  const closed = days.filter((d) => d.report_status === "CLOSED");
  const closedIncomplete = closed.filter((d) => !d.is_complete);
  const profit = sumCents(closed.map((d) => d.profit_round_one_thb));

  const yields = yieldsR.rows;
  const lossPct = ratioPctCents(
    sumCents(yields.map((y) => y.loss_weight_kg)),
    sumCents(yields.map((y) => y.foodiva_sent_weight_kg)),
  );
  const lotsClosed = yields.reduce((s, y) => s + Number(y.lots_closed), 0);
  const alerts = yields.reduce(
    (s, y) => s + Number(y.yield_alert_lot_count),
    0,
  );

  const stock = sumCents(stockR.rows.map((s) => s.balance_qty));

  const tiles: StatTileProps[] = [
    {
      label: "รายการที่ต้องจัดการ",
      value: String(exceptions.length),
      unit: "รายการ",
      tone: exceptions.length > 0 ? "danger" : "success",
      href: "#exceptions",
    },
    {
      label: "ยอดขาย",
      value: signedDp2(revenue),
      unit: "บาท",
      sign: signOf(revenue),
      href: `${link({ view: "day", page: "1" })}#pnl`,
      note: (
        <p className="text-caption text-text-secondary">
          รวมวันที่ยังไม่ปิดยอด · LINE MAN เท่านั้น
        </p>
      ),
    },
    {
      label: "กำไรสุทธิรอบแรก · วันที่ปิดยอดแล้ว",
      value: closed.length > 0 ? signedDp2(profit) : "—",
      unit: closed.length > 0 ? "บาท" : undefined,
      sign: closed.length > 0 ? signOf(profit) : "zero",
      href: `${link({ view: "day", page: "1" })}#pnl`,
      note: <ScopeNote>{SCOPE_NOTE_TH}</ScopeNote>,
      incomplete:
        closedIncomplete.length > 0
          ? {
              figure: "กำไรสุทธิรอบแรก",
              missing: unique(
                closedIncomplete.flatMap((d) => d.missing_inputs),
              ),
            }
          : undefined,
    },
    {
      label: "Loss หลัก (ฐานน้ำหนักส่งจาก Foodiva)",
      value: lossPct === null ? "—" : signedDp2(lossPct),
      unit: lossPct === null ? undefined : "%",
      tone: alerts > 0 ? "warning" : "neutral",
      href: alerts > 0 ? "/owner/lots/results?alert=1" : "/owner/lots/results",
      note: (
        <p className="text-caption text-text-secondary">
          ปิด {lotsClosed} ล็อต · แจ้งเตือน {alerts} ล็อต
        </p>
      ),
    },
    {
      label: "เนื้อรมควันคงเหลือ (แช่แข็ง + พร้อมขาย)",
      value: signedDp2(stock),
      unit: "กก.",
      sign: signOf(stock),
      href: "/owner/central",
    },
  ];

  // ── charts ───────────────────────────────────────────────────────────────────────────
  const revenueByDate = new Map<string, bigint>();
  for (const d of days) {
    revenueByDate.set(
      d.business_date,
      (revenueByDate.get(d.business_date) ?? ZERO) +
        (toCents(d.revenue_thb) ?? ZERO),
    );
  }
  const revenuePoints: ChartPoint[] = buckets(
    [...revenueByDate.entries()].sort(([a], [b]) => a.localeCompare(b)),
    CHART_MAX_POINTS,
  ).map((b) => ({
    label: dateRangeLabel(b[0][0], b[b.length - 1][0]),
    value: Number(b.reduce((s, [, c]) => s + c, ZERO)) / 100,
  }));

  const lossPoints: ChartPoint[] = buckets(yields, CHART_MAX_POINTS).map(
    (b) => {
      const pctCents = ratioPctCents(
        sumCents(b.map((y) => y.loss_weight_kg)),
        sumCents(b.map((y) => y.foodiva_sent_weight_kg)),
      );
      return {
        label: dateRangeLabel(b[0].close_date, b[b.length - 1].close_date),
        value: pctCents === null ? null : Number(pctCents) / 100,
      };
    },
  );

  // ── P&L table ────────────────────────────────────────────────────────────────────────
  const lotRows = lot ? lotsR.rows.filter((l) => l.lot_id === lot) : lotsR.rows;
  const total =
    view === "day"
      ? days.length
      : view === "month"
        ? monthsR.rows.length
        : lotRows.length;
  const pages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const at = Math.min(page, pages);
  const slice = <T,>(rows: T[]) =>
    rows.slice((at - 1) * PAGE_SIZE, at * PAGE_SIZE);

  const dayColumns: Column<PnlDayRow>[] = [
    {
      id: "date",
      header: "วันที่",
      priority: 1,
      cell: (r) => (
        <Link
          href={`${BASE}/trace?date=${r.business_date}&branch=${r.location_id}`}
          className="text-accent hover:underline"
        >
          {thaiDate(r.business_date)}
        </Link>
      ),
    },
    {
      id: "branch",
      header: "สาขา",
      priority: 1,
      cell: (r) => r.location_name_th,
    },
    {
      id: "status",
      header: "สถานะวัน",
      cell: (r) =>
        r.report_status === "CLOSED"
          ? "ปิดยอดแล้ว"
          : r.report_status
            ? "ยังไม่ปิดยอด"
            : "ไม่มีรายงาน",
    },
    {
      id: "revenue",
      header: "ยอดขาย",
      numeric: true,
      cell: (r) => <Money value={r.revenue_thb} />,
    },
    {
      id: "cost",
      header: "ต้นทุนที่ทราบ",
      numeric: true,
      cell: (r) => <Money value={r.total_cost_thb} />,
    },
    {
      id: "profit",
      header: "กำไรรอบแรก",
      numeric: true,
      cell: (r) => <Profit row={r} />,
    },
  ];

  const monthColumns: Column<PnlMonthRow>[] = [
    { id: "month", header: "เดือน", priority: 1, cell: (r) => r.pnl_month },
    {
      id: "branch",
      header: "สาขา",
      priority: 1,
      cell: (r) => r.location_name_th,
    },
    {
      id: "days",
      header: "วันที่ปิดยอด",
      cell: (r) => `${r.days_closed} / ${r.days_reported}`,
    },
    {
      id: "revenue",
      header: "ยอดขาย",
      numeric: true,
      cell: (r) => <Money value={r.revenue_thb} />,
    },
    {
      id: "cost",
      header: "ต้นทุนที่ทราบ",
      numeric: true,
      cell: (r) => <Money value={r.total_cost_thb} />,
    },
    {
      id: "profit",
      header: "กำไรรอบแรก",
      numeric: true,
      cell: (r) => <Profit row={r} />,
    },
  ];

  const lotColumns: Column<PnlLotRow>[] = [
    {
      id: "lot",
      header: "ล็อต",
      priority: 1,
      cell: (r) =>
        r.is_opening ? (
          `${r.lot_code} (สต็อกตั้งต้น)`
        ) : (
          <Link
            href={`/owner/lots/results?lot=${r.lot_id}`}
            className="text-accent hover:underline"
          >
            {r.lot_code}
          </Link>
        ),
    },
    {
      id: "sold",
      header: "ขาย / ทิ้ง",
      cell: (r) => `${kg(r.sold_kg)} / ${kg(r.wasted_kg)}`,
    },
    {
      id: "left",
      header: "คงเหลือ",
      numeric: true,
      cell: (r) => kg(r.remaining_kg),
    },
    {
      id: "revenue",
      header: "ยอดขายเนื้อ",
      numeric: true,
      cell: (r) => <Money value={r.meat_revenue_thb} />,
    },
    {
      id: "attr",
      header: "ต้นทุนของที่ขายออก",
      numeric: true,
      cell: (r) => <Money value={r.attributed_cost_thb} />,
    },
    {
      id: "unattr",
      header: "ต้นทุนที่ยังอยู่ในสต็อก",
      numeric: true,
      cell: (r) => <Money value={r.unattributed_cost_thb} />,
    },
    {
      id: "profit",
      header: "กำไรรอบแรก",
      numeric: true,
      cell: (r) => <Profit row={r} />,
    },
  ];

  const empty = (
    <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
      ไม่มีข้อมูลในช่วงนี้
    </p>
  );

  // ── cost breakdown and the owner-expense memo ────────────────────────────────────────
  const grouped = (rows: CostRow[]) =>
    CATEGORY_ORDER.flatMap((category) => {
      const inCat = rows.filter((r) => r.category === category);
      if (inCat.length === 0) return [];
      const unknown = inCat.filter((r) => toCents(r.amount_thb) === null);
      return [
        {
          category,
          cents: sumCents(inCat.map((r) => r.amount_thb)),
          missing: unique(unknown.flatMap((r) => r.missing_inputs)),
        },
      ];
    });
  const costLines = grouped(costsR.rows.filter((r) => r.in_pnl_round_one));
  const memoLines = grouped(costsR.rows.filter((r) => !r.in_pnl_round_one));

  const lotOptions = lotsR.rows.map((l) => ({
    id: l.lot_id,
    label: l.lot_code,
  }));
  const branchOptions = branchesR.rows.map((b) => ({
    id: b.id,
    label: b.name_th,
  }));

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-h1 text-text-primary">แดชบอร์ด</h1>
        <Link href="/owner" className={actionLink}>
          ← เมนูเจ้าของ
        </Link>
      </div>

      <FilterBar
        action={BASE}
        from={from}
        to={to}
        branch={branch}
        lot={lot}
        view={view}
        branches={branchOptions}
        lots={lotOptions}
      />

      {errors.length > 0 ? (
        <ReadError title="อ่านรายงานไม่สำเร็จ" raw={errors} />
      ) : null}

      <div className="grid grid-cols-1 gap-3 md:grid-cols-2 lg:grid-cols-4 xl:grid-cols-5">
        {tiles.map((t) => (
          <StatTile key={t.label} {...t} />
        ))}
      </div>

      <div className="grid grid-cols-1 gap-3 lg:grid-cols-2">
        <ChartPanel
          title="ยอดขายรายวัน"
          type="bar"
          unit="บาท"
          points={revenuePoints}
          scopeNote={<ScopeNote>{SCOPE_NOTE_TH}</ScopeNote>}
          empty="ยังไม่มียอดขายในช่วงนี้"
        />
        <ChartPanel
          title="Loss หลักรายวัน (ล็อตที่ปิดในวันนั้น)"
          type="line"
          unit="%"
          points={lossPoints}
          empty="ไม่มีล็อตที่ปิดในช่วงนี้"
        />
      </div>

      <section id="pnl" className="flex flex-col gap-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-h2 text-text-primary">กำไรขาดทุนรอบแรก</h2>
          <nav className="flex flex-wrap gap-3">
            {(
              [
                ["day", "รายวัน"],
                ["month", "รายเดือน"],
                ["lot", "รายล็อต"],
              ] as const
            ).map(([v, label]) => (
              <Link
                key={v}
                href={`${link({ view: v, page: "1" })}#pnl`}
                className={view === v ? `${actionLink} underline` : actionLink}
              >
                {label}
              </Link>
            ))}
          </nav>
        </div>
        <ScopeNote>
          {SCOPE_NOTE_TH}
          {view === "lot"
            ? " · รายล็อตนับเฉพาะเนื้อ ไม่รวมน้ำพริกและสินค้าอื่น"
            : ""}
        </ScopeNote>
        {view === "day" ? (
          <ResponsiveTable
            columns={dayColumns}
            rows={slice(days)}
            keyField={(r) => `${r.business_date}:${r.location_id}`}
            emptyState={empty}
          />
        ) : view === "month" ? (
          <ResponsiveTable
            columns={monthColumns}
            rows={slice(monthsR.rows)}
            keyField={(r) => `${r.pnl_month}:${r.location_id}`}
            emptyState={empty}
          />
        ) : (
          <ResponsiveTable
            columns={lotColumns}
            rows={slice(lotRows)}
            keyField={(r) => r.lot_id}
            emptyState={empty}
          />
        )}
        {pages > 1 ? (
          <nav className="flex items-center justify-center gap-4">
            {at > 1 ? (
              <Link
                href={`${link({ page: String(at - 1) })}#pnl`}
                className={actionLink}
              >
                ก่อนหน้า
              </Link>
            ) : null}
            <span className="text-label text-text-secondary">
              {at} / {pages}
            </span>
            {at < pages ? (
              <Link
                href={`${link({ page: String(at + 1) })}#pnl`}
                className={actionLink}
              >
                ถัดไป
              </Link>
            ) : null}
          </nav>
        ) : null}
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-h2 text-text-primary">ต้นทุนแยกตามหมวด</h2>
        <dl className="flex flex-col divide-y divide-border rounded-lg border border-border bg-surface">
          {costLines.map((c) => (
            <div
              key={c.category}
              className="flex flex-wrap justify-between gap-2 p-3 text-body-sm"
            >
              <dt className="text-text-secondary">{CATEGORY_TH[c.category]}</dt>
              <dd className="text-right text-text-primary tabular-nums">
                {c.missing.length > 0 ? (
                  <span className="text-warning">
                    ข้อมูลไม่ครบ: {c.missing.map(missingTh).join(" · ")}
                  </span>
                ) : (
                  `${signedDp2(c.cents)} บาท`
                )}
              </dd>
            </div>
          ))}
          <div className="flex flex-col gap-1 p-3 text-body-sm">
            <dt className="text-text-secondary">ค่าแรง</dt>
            <dd>
              <ScopeNote>{LABOUR_SCOPE_TH}</ScopeNote>
            </dd>
          </div>
        </dl>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-h2 text-text-primary">ค่าใช้จ่ายของเจ้าของ</h2>
        <ScopeNote>{OWNER_MEMO_SCOPE_TH}</ScopeNote>
        {memoLines.length === 0 ? (
          <p className="text-body-sm text-text-secondary">
            ไม่มีค่าใช้จ่ายของเจ้าของในช่วงนี้
          </p>
        ) : (
          <dl className="flex flex-col divide-y divide-border rounded-lg border border-border bg-surface">
            {memoLines.map((c) => (
              <div
                key={c.category}
                className="flex flex-wrap justify-between gap-2 p-3 text-body-sm"
              >
                <dt className="text-text-secondary">
                  {CATEGORY_TH[c.category]}
                </dt>
                <dd className="text-right text-text-primary tabular-nums">
                  {signedDp2(c.cents)} บาท
                </dd>
              </div>
            ))}
          </dl>
        )}
        <Link href="/owner/expenses" className={actionLink}>
          ดูรายการค่าใช้จ่าย →
        </Link>
      </section>

      <section id="exceptions" className="flex flex-col gap-3">
        <h2 className="text-h2 text-text-primary">รายการที่ต้องจัดการ</h2>
        <ExceptionList rows={exceptions} />
      </section>
    </div>
  );
}
