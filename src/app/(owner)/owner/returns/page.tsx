import Link from "next/link";

import { actionLink } from "@/components/ui/controls";
import { ReturnDateForm } from "@/features/movement/components/return-date-form";
import { ReturnLotList } from "@/features/movement/components/return-lot-list";
import type { ReturnPendingRow } from "@/features/movement/types";
import { todayBangkok } from "@/lib/format/date";
import { one } from "@/lib/params";
import { newFormKey } from "@/lib/rpc/movement";
import { createClient } from "@/lib/supabase/server";
import { ReadError } from "@/components/shared/read-error";

/* OW 05 — ต้นทุนและนัดรับขากลับ (card ^ref-37), skeleton S3: a list of closed lots waiting
 * for a pickup date, and a full-screen detail whose only input is that date (BR17, UAT-23).
 *
 * THE ROLE GATE IS NOT HERE. v_lot_return_pending carries its own role test (R34): L1 and a
 * can_receive_central delegate see every row, and everyone else none. fn_set_return_pickup_date
 * asks fn_require_central_receiver again. The `(owner)` layout's requireRole is the mirror.
 *
 * The lot-cost tile the design contract puts on OW 05 (`IncompleteDataNotice`,
 * DESIGN-CONTRACTS.md) waits on v_lot_cost (^ref-32, lane E). See PLAN-movement.md, Cross-lane
 * gaps. It is not guessed at here.
 *
 * `supabase.from()` is the sanctioned path for a READ through a view. Every write goes through
 * src/lib/rpc/movement.ts. */

export default async function ReturnsPage(props: PageProps<"/owner/returns">) {
  const params = await props.searchParams;
  const lotId = one(params.lot);

  const supabase = await createClient();
  const [queue, onTruckRes] = await Promise.all([
    supabase.from("v_lot_return_pending").select("*"),
    // A dispatched return leg not yet signed for — the lot is on the truck (R29).
    supabase
      .from("v_outstanding_receipts")
      .select("lot_id")
      .eq("route", "CM_TO_FOODIVA"),
  ]);
  const error = queue.error ?? onTruckRes.error;

  // Oldest close first: the lot most likely to be acted on sits above the fold (S3).
  const rows = [...((queue.data ?? []) as ReturnPendingRow[])].sort((a, b) =>
    (a.closed_at ?? "").localeCompare(b.closed_at ?? ""),
  );
  const onTruck = new Set(
    ((onTruckRes.data ?? []) as { lot_id: string }[]).map((r) => r.lot_id),
  );

  if (lotId) {
    const row = rows.find((r) => r.lot_id === lotId);
    if (!row) {
      return (
        <div className="flex flex-col gap-4">
          <Link href="/owner/returns" className={actionLink}>
            ← รายการรอนัดรับ
          </Link>
          <p className="rounded-lg border border-border bg-surface p-6 text-body text-text-secondary">
            Lot นี้ไม่อยู่ในคิวรอนัดรับแล้ว — อาจรับเข้าคลังกลางไปแล้ว
          </p>
        </div>
      );
    }
    return (
      <ReturnDateForm
        row={row}
        onTruck={onTruck.has(row.lot_id)}
        idempotencyKey={newFormKey()}
        today={todayBangkok()}
        saved={one(params.saved) === "1"}
        err={one(params.err)}
      />
    );
  }

  return (
    <div className="mx-auto flex w-full max-w-[720px] flex-col gap-4">
      <h1 className="text-h1 text-text-primary">ต้นทุนและนัดรับขากลับ</h1>
      <p className="text-body-sm text-text-secondary">
        Lot ที่เชียงใหม่ปิดแล้ว รอกำหนดวันที่รถมารับของกลับ — การปิด Lot
        ไม่ได้สร้างงานรถให้เอง รอนานที่สุดอยู่บนสุด
      </p>

      {error ? (
        <ReadError title="อ่านรายการไม่สำเร็จ" raw={error.message} />
      ) : rows.length === 0 ? (
        <p className="rounded-lg border border-border bg-surface p-6 text-center text-body text-text-secondary">
          ไม่มี Lot ที่รอนัดรับขากลับ
        </p>
      ) : (
        <ReturnLotList rows={rows} onTruck={onTruck} />
      )}
    </div>
  );
}
