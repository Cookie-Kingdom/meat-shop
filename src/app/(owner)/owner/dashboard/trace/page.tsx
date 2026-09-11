import Link from "next/link";

import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { actionLink } from "@/components/ui/controls";
import { isoDateOr } from "@/features/reports/format";
import type { TraceRow } from "@/features/reports/types";
import { thaiDate, todayBangkok } from "@/lib/format/date";
import { dp2, kg } from "@/lib/format/number";
import { one } from "@/lib/params";
import { readTrace } from "@/lib/rpc/reports";
import { ReadError } from "@/components/shared/read-error";

/* OW 08 trace — sale date → smoke-date group → lot → PO → supplier (F13, BR18; PLAN K22). One
 * row per meat sales line from 232. `?date=` narrows to one day (the P&L table and the Diff
 * exception link here); otherwise `?from=&to=` as on the dashboard. An opening lot stops at the
 * lot: it has no PO and no supplier (ADR-021). The lot links to OW 04 for its cost.
 * L1 only in the view's WHERE; the (owner) layout is the mirror (ADR-004). */

export default async function TracePage(
  props: PageProps<"/owner/dashboard/trace">,
) {
  const params = await props.searchParams;
  const today = todayBangkok();
  const date = isoDateOr(one(params.date), "");
  const from = date || isoDateOr(one(params.from), today);
  const to = date || isoDateOr(one(params.to), today);
  const branch = one(params.branch);
  const lot = one(params.lot);

  const res = await readTrace({
    from,
    to,
    locationId: branch || undefined,
    lotId: lot || undefined,
  });

  const columns: Column<TraceRow>[] = [
    {
      id: "date",
      header: "วันที่ขาย",
      priority: 1,
      cell: (r) => thaiDate(r.business_date),
    },
    {
      id: "branch",
      header: "สาขา",
      priority: 1,
      cell: (r) => r.location_name_th,
    },
    { id: "product", header: "สินค้า", cell: (r) => r.product_name_th },
    {
      id: "qty",
      header: "จำนวน",
      numeric: true,
      cell: (r) =>
        `${dp2(r.sold_qty).replace(".00", "")} × ${kg(r.pack_weight_kg)}`,
    },
    {
      id: "smoke",
      header: "วันรมควัน",
      cell: (r) => (r.smoke_date ? thaiDate(r.smoke_date) : "—"),
    },
    {
      id: "lot",
      header: "ล็อต",
      cell: (r) =>
        r.is_opening ? (
          r.lot_code
        ) : (
          <Link
            href={`/owner/lots/results?lot=${r.lot_id}`}
            className="text-accent hover:underline"
          >
            {r.lot_code}
          </Link>
        ),
    },
    { id: "po", header: "PO", cell: (r) => r.po_number ?? "—" },
    {
      id: "supplier",
      header: "ผู้ขาย",
      cell: (r) => (r.is_opening ? "สต็อกตั้งต้น" : (r.supplier_name ?? "—")),
    },
  ];

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-h1 text-text-primary">ที่มาของยอดขาย</h1>
        <Link
          href={`/owner/dashboard?from=${from}&to=${to}`}
          className={actionLink}
        >
          ← แดชบอร์ด
        </Link>
      </div>
      <p className="text-body-sm text-text-secondary">
        {from === to ? thaiDate(from) : `${thaiDate(from)} – ${thaiDate(to)}`} ·
        ขาย → วันรมควัน → ล็อต → PO → ผู้ขาย
      </p>
      {res.error ? (
        <ReadError title="อ่านข้อมูลไม่สำเร็จ" raw={res.error} />
      ) : (
        <ResponsiveTable
          columns={columns}
          rows={res.rows}
          keyField={(r) => r.sales_line_id}
          emptyState={
            <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
              ไม่มียอดขายเนื้อในช่วงนี้
            </p>
          }
        />
      )}
    </div>
  );
}
