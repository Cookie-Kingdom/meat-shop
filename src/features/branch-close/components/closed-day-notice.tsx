import { Notice } from "@/features/branch/components/notice";
import type { BranchDay } from "@/features/branch/context";
import { thaiDate, thaiDateTime } from "@/lib/format/date";

/* ClosedDayNotice — a CLOSED day keeps its forms under this notice (PLAN-close-screens.md
 * Finding 8, lane B's BR 05 model). An approved unlock leaves the day CLOSED (ref-08-unlock
 * Finding 1), so the status alone cannot say whether a write will be accepted. The server
 * decides with REPORT_CLOSED; this only tells the operator what v_unlock_requests already shows
 * them (L2 reads its own branch's day rows). The view reports an expired approval as EXPIRED on
 * the same clock the trigger refuses on (R42), so APPROVED here means live. */

export async function ClosedDayNotice({
  db,
  reportId,
  date,
}: {
  db: BranchDay["supabase"];
  reportId: string;
  date: string;
}) {
  const { data } = await db
    .from("v_unlock_requests")
    .select("expires_at")
    .eq("target_type", "DAILY_REPORT")
    .eq("target_id", reportId)
    .eq("status", "APPROVED")
    .order("expires_at", { ascending: false })
    .limit(1);
  const until = (data?.[0]?.expires_at as string | null | undefined) ?? null;

  return (
    <Notice tone="locked">
      {until
        ? `วันที่ ${thaiDate(date)} ปิดแล้ว — เจ้าของร้านอนุมัติให้แก้ไขได้ถึง ${thaiDateTime(until)}`
        : `วันที่ ${thaiDate(date)} ปิดแล้ว — บันทึกได้เฉพาะเมื่อเจ้าของร้านอนุมัติปลดล็อกวันนี้และยังไม่หมดเวลา ถ้ายังไม่ได้อนุมัติ ระบบจะไม่รับรายการ`}
    </Notice>
  );
}
