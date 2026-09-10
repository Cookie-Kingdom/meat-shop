import Link from "next/link";

import { AlertBanner } from "@/features/production/components/alert-banner";
import { EmptyState } from "@/features/production/components/empty-state";
import { LotList } from "@/features/production/components/lot-list";
import { readMyLots } from "@/features/production/queries";
import { isClosed, isOpen } from "@/features/production/types";

/* CM 01 — My Lots (S3). The operator's own assigned lots, the weight the Owner declared, and
 * the status (v0.2 line 78). Tapping a row pushes the lot's full screen.
 *
 * THE SCOPE IS NOT HERE. v_operator_lots carries the R34 role test in its WHERE, so an L3
 * session reads its own assigned lots and nothing else from the database — the (cm) layout's
 * requireRole is the mirror (ADR-004). cm_screens_test.sql proves it as an L3 session.
 *
 * Open work first, oldest first, so the lot most likely to be acted on is above the fold; the
 * last ten closed lots below, for the operator who wants to check what they finished. */

const RECENT_CLOSED = 10;

export default async function MyLots() {
  const { data, error } = await readMyLots();
  const open = data.filter((l) => isOpen(l.state));
  const closed = data
    .filter((l) => isClosed(l.state))
    .sort((a, b) => (b.closed_at ?? "").localeCompare(a.closed_at ?? ""))
    .slice(0, RECENT_CLOSED);

  return (
    <div className="flex flex-col gap-4">
      <h1 className="text-h1 text-text-primary">งานของฉัน</h1>

      {error ? (
        <AlertBanner tone="danger" title="อ่านรายการ Lot ไม่สำเร็จ">
          {error}{" "}
          <Link href="/cm" className="text-accent underline">
            ลองอีกครั้ง
          </Link>
        </AlertBanner>
      ) : open.length === 0 ? (
        <EmptyState
          title="ยังไม่มี Lot ที่ต้องทำ"
          body="Lot จะขึ้นที่นี่เองเมื่อ Owner มอบหมายให้คุณและรถออกจาก Foodiva แล้ว — ไม่ต้องทำอะไรตอนนี้"
        />
      ) : (
        <section className="flex flex-col gap-2" aria-label="Lot ที่กำลังทำ">
          <h2 className="text-h3 text-text-primary">กำลังทำ ({open.length})</h2>
          <LotList lots={open} />
        </section>
      )}

      {closed.length > 0 ? (
        <section className="flex flex-col gap-2" aria-label="Lot ที่ปิดแล้ว">
          <h2 className="text-h3 text-text-secondary">ปิดแล้วล่าสุด</h2>
          <LotList lots={closed} />
        </section>
      ) : null}
    </div>
  );
}
