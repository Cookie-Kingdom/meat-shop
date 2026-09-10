import Link from "next/link";

import { FifoAllocator } from "@/features/movement/components/fifo-allocator";
import type { Branch, CentralAvailableRow } from "@/features/movement/types";
import { todayBangkok } from "@/lib/format/date";
import { newFormKey } from "@/lib/rpc/movement";
import { createClient } from "@/lib/supabase/server";

/* OW 07 — จัดสรรสู่สาขา (card ^ref-37), skeleton S2. v0.2:108: the inputs are the lot, the
 * branch, the weight and the bag count, with the FIFO proposal first; the result appears on
 * the branch's receiving screen.
 *
 * ACCEPTANCE — "nothing can reach a branch without passing through central stock first".
 * On this screen that holds because the picker IS v_central_available (FROZEN at a CENTRAL
 * location) and the one write is fn_allocate_to_branch, which re-reads the same view and takes
 * its origin from it (BR11). Below this screen it holds because fn_dispatch_transport_line
 * refuses a branch leg that does not leave central (fix/dispatch-branch-leg-guard,
 * PLAN-movement.md Finding 11). The screen is the mirror of both (ADR-004).
 *
 * The explicit order repeats the view's own `order by` (smoke date, then lot code), because
 * PostgREST does not promise to keep a view's order through its wrapper. It is the same rule,
 * not a re-sort.
 *
 * Branches come from v_config_catalogue: L1 only, like this screen (Finding 12). */

export default async function AllocatePage() {
  const supabase = await createClient();
  const [centralRes, branchRes] = await Promise.all([
    supabase
      .from("v_central_available")
      .select("*")
      .order("smoke_date")
      .order("lot_code"),
    supabase
      .from("v_config_catalogue")
      .select("id, name_th, code")
      .eq("kind", "LOCATION")
      .eq("unit", "BRANCH")
      .order("name_th"),
  ]);
  const error = centralRes.error ?? branchRes.error;
  const rows = (centralRes.data ?? []) as CentralAvailableRow[];
  const branches = (branchRes.data ?? []) as Branch[];

  return (
    <div className="mx-auto flex w-full max-w-[720px] flex-col gap-4">
      <h1 className="text-h1 text-text-primary">OW 07 · จัดสรรสู่สาขา</h1>
      <p className="text-body-sm text-text-secondary">
        ส่งได้เฉพาะของแช่แข็งที่รับเข้าคลังกลางแล้ว (BR11) ระบบเสนอวันรมควันที่เก่าที่สุดก่อน
        ข้ามได้แต่ต้องมีเหตุผล (BR07) รอบรถส่งสาขาไม่มีค่าขนส่ง
      </p>

      {error ? (
        <p className="rounded-lg border border-danger bg-danger-subtle p-4 text-body text-danger">
          อ่านข้อมูลไม่สำเร็จ — {error.message}
        </p>
      ) : rows.length === 0 ? (
        <p className="rounded-lg border border-border bg-surface p-6 text-body text-text-secondary">
          ยังไม่มีของแช่แข็งในคลังกลาง — รับของขากลับเข้าคลังที่{" "}
          <Link href="/owner/central" className="text-accent underline">
            OW 06 · สต็อกกลาง
          </Link>{" "}
          ก่อน ของที่ยังอยู่บนรถจัดสรรไม่ได้
        </p>
      ) : branches.length === 0 ? (
        <p className="rounded-lg border border-border bg-surface p-6 text-body text-text-secondary">
          ยังไม่มีสาขาในระบบ จึงยังจัดสรรไม่ได้
        </p>
      ) : (
        <FifoAllocator
          rows={rows}
          branches={branches}
          idempotencyKey={newFormKey()}
          today={todayBangkok()}
        />
      )}
    </div>
  );
}
