import Link from "next/link";

import { actionLink } from "@/components/ui/controls";
import {
  ResponsiveTable,
  type Column,
} from "@/components/shared/responsive-table";
import { CostBreakdown } from "@/features/cost/components/cost-breakdown";
import { DailyYieldTable } from "@/features/cost/components/daily-yield-table";
import { StatusBadge } from "@/features/cost/components/status-badge";
import { SummaryRow } from "@/features/cost/components/summary-row";
import { DASH, kg } from "@/features/cost/format";
import {
  LOT_STATE_TH,
  OPEN_STATES,
  type FreightLineRow,
  type LotCostRow,
  type LotDailyYieldRow,
  type LotProgressRow,
  type PendingWorkRow,
} from "@/features/cost/types";
import { thaiDate } from "@/lib/format/date";
import { one } from "@/lib/params";
import { createClient } from "@/lib/supabase/server";
import { ReadError } from "@/components/shared/read-error";

/* OW 03 — ติดตาม Lot (card ^ref-33). Skeleton S3, List → Detail, one column; `?lot=` opens
 * the detail. v0.2 OW 03: "รวม Daily Log ยอดรอทำ Yield และสถานะ". PRODUCT F7: daily progress,
 * remaining weight and yield trend while the lot is still running.
 *
 * R17 ON SCREEN: a running lot shows progress, the per-day trend and its provisional cost —
 * and no Loss. Loss is computed once, at close, and is OW 04's.
 *
 * THE ROLE GATE IS NOT HERE. Every view read below is L1-only in its WHERE (v_lot_progress and
 * v_lot_pending_work scope L3 to their own lots; v_lot_daily_yield, v_lot_cost and
 * v_freight_allocation return nothing to anyone but L1). The (owner) layout's requireRole is
 * the mirror (ADR-004).
 *
 * Reads only. `supabase.from()` is the sanctioned path for a view read; there is no write on
 * this screen.
 *
 * ponytail: one read of every open lot per render, joined in TypeScript. A running lot count
 * is in the tens. Ceiling: a few hundred open lots; upgrade path is a `.range()` page.
 */

type Client = Awaited<ReturnType<typeof createClient>>;

async function loadDetail(supabase: Client, lotId: string) {
  const [days, cost, freight] = await Promise.all([
    supabase
      .from("v_lot_daily_yield")
      .select("*")
      .eq("lot_id", lotId)
      .order("event_date"),
    supabase.from("v_lot_cost").select("*").eq("lot_id", lotId).maybeSingle(),
    supabase
      .from("v_freight_allocation")
      .select("*")
      .eq("lot_id", lotId)
      .order("event_date"),
  ]);
  return {
    days: (days.data ?? []) as LotDailyYieldRow[],
    cost: (cost.data ?? null) as LotCostRow | null,
    freight: (freight.data ?? []) as FreightLineRow[],
    error: days.error ?? cost.error ?? freight.error,
  };
}

export default async function LotTrackingPage(props: PageProps<"/owner/lots">) {
  const params = await props.searchParams;
  const lotId = one(params.lot);

  const supabase = await createClient();
  const [progressRes, pendingRes] = await Promise.all([
    supabase
      .from("v_lot_progress")
      .select("*")
      .in("state", OPEN_STATES)
      .order("lot_code"),
    supabase.from("v_lot_pending_work").select("*").in("state", OPEN_STATES),
  ]);

  const lots = (progressRes.data ?? []) as LotProgressRow[];
  const pending = new Map(
    ((pendingRes.data ?? []) as PendingWorkRow[]).map((r) => [r.lot_id, r]),
  );
  const listError = progressRes.error ?? pendingRes.error;

  const selected = lots.find((l) => l.lot_id === lotId) ?? null;
  const detail = selected ? await loadDetail(supabase, selected.lot_id) : null;
  const selectedPending = selected ? pending.get(selected.lot_id) : undefined;

  const columns: Column<LotProgressRow>[] = [
    {
      id: "lot",
      header: "ล็อต",
      priority: 1,
      cell: (r) => (
        <Link
          href={`/owner/lots?lot=${r.lot_id}`}
          className="text-accent hover:underline"
        >
          {r.lot_code}
        </Link>
      ),
    },
    {
      id: "state",
      header: "สถานะ",
      priority: 1,
      cell: (r) => (
        <StatusBadge>{LOT_STATE_TH[r.state] ?? r.state}</StatusBadge>
      ),
    },
    {
      id: "days",
      header: "วันที่บันทึกแล้ว",
      numeric: true,
      cell: (r) => `${r.days_logged} วัน`,
    },
    {
      id: "pending",
      header: "ยอดรอทำ",
      numeric: true,
      cell: (r) => kg(pending.get(r.lot_id)?.pending_weight_kg ?? null),
    },
    {
      id: "packed",
      header: "แพ็คแล้ว",
      numeric: true,
      cell: (r) => `${kg(r.packed_weight_kg)} · ${r.bag_count} ถุง`,
    },
    {
      id: "last",
      header: "บันทึกล่าสุด",
      cell: (r) => (r.last_log_date ? thaiDate(r.last_log_date) : DASH),
    },
  ];

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-h1 text-text-primary">ติดตามล็อต</h1>
        <Link href="/owner/lots/results" className={actionLink}>
          ผลล็อตที่ปิดแล้ว →
        </Link>
      </div>

      <p className="text-body-sm text-text-secondary">
        ล็อตที่ยังไม่ปิด — ความคืบหน้ารายวัน ยอดรอทำ และต้นทุนชั่วคราว Loss
        หลักจะคำนวณเมื่อเชียงใหม่ปิดล็อตเท่านั้น
      </p>

      {listError ? (
        <ReadError title="อ่านข้อมูลล็อตไม่สำเร็จ" raw={listError.message} />
      ) : (
        <ResponsiveTable
          columns={columns}
          rows={lots}
          keyField={(r) => r.lot_id}
          isMuted={(r) => r.lot_id === selected?.lot_id}
          emptyState={
            <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
              ไม่มีล็อตที่กำลังผลิตอยู่
            </p>
          }
        />
      )}

      {lotId && !selected ? (
        <p className="rounded-lg border border-border bg-surface p-4 text-body-sm text-text-secondary">
          ล็อตนี้ปิดแล้วหรือไม่พบ — ดูผลล็อตที่ปิดแล้วที่{" "}
          <Link
            href={`/owner/lots/results?lot=${lotId}`}
            className="text-accent hover:underline"
          >
            หน้าผลล็อต
          </Link>
        </p>
      ) : null}

      {selected && detail ? (
        <div className="flex flex-col gap-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 className="text-h2 text-text-primary">
              ล็อต {selected.lot_code}
            </h2>
            <Link href="/owner/lots" className={actionLink}>
              ปิดรายละเอียด
            </Link>
          </div>

          {detail.error ? (
            <ReadError
              title="อ่านรายละเอียดล็อตไม่สำเร็จ"
              raw={detail.error.message}
            />
          ) : null}

          <section className="rounded-lg border border-border bg-surface p-4">
            <h2 className="text-h2 text-text-primary">ความคืบหน้า</h2>
            <SummaryRow
              label="สถานะ"
              value={LOT_STATE_TH[selected.state] ?? selected.state}
            />
            <SummaryRow
              label="เชียงใหม่รับจริง"
              value={kg(selectedPending?.received_weight_kg ?? null)}
              trace={
                selectedPending
                  ? `รับเมื่อ ${thaiDate(selectedPending.receipt_date)} · ใช้ตรวจสอบเท่านั้น`
                  : "ยังไม่ได้รับเนื้อ"
              }
            />
            <SummaryRow
              label="ก่อนรมควัน (หลังซับเลือด)"
              value={kg(selectedPending?.post_drain_weight_kg ?? null)}
            />
            <SummaryRow
              label="นำเข้ารมควันแล้ว"
              value={kg(selected.input_consumed_kg)}
              trace="ผลรวมน้ำหนักที่ดึงจากล็อตนี้ใน Daily Smoke Log"
            />
            <SummaryRow
              label="ยอดรอทำ"
              value={kg(selectedPending?.pending_weight_kg ?? null)}
              trace="น้ำหนักก่อนรมควัน − ที่นำเข้ารมควันแล้ว"
              emphasis
            />
            <SummaryRow
              label="แพ็คแล้ว"
              value={`${kg(selected.packed_weight_kg)} · ${selected.bag_count} ถุง`}
            />
          </section>

          <DailyYieldTable rows={detail.days} />

          {detail.cost ? (
            <CostBreakdown row={detail.cost} freight={detail.freight} />
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
