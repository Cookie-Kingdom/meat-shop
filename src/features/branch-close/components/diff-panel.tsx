import { cva } from "class-variance-authority";

import { formatKg } from "@/features/branch/format";
import { largestFirst, type DiffRow, type ReadyLot } from "../queries";

/* DiffPanel — BR 07's pinned Diff (S2, R23; PLAN-close-screens.md Findings 1, 3, 9).
 *
 * A MIRROR OF THE SAVED FIGURES, NOT A DECISION. It renders v_branch_diff's row for the day,
 * re-read after every save. It does not recompute from what is on screen: that needs
 * avg_pack_weight_kg, which an L2 cannot read (R20). fn_close_daily_report decides (ADR-004).
 *
 * null ≠ 0: a day with no READY meat movement has no Diff row, and says so. The lots named are
 * the ones still holding READY, largest first — where the unexplained weight sits (Finding 3).
 * The copy stays neutral on Open Question 6: it never suggests writing the remainder off to
 * make the number fit. */

const panel = cva("sticky top-0 z-10 flex flex-col gap-2 rounded-lg border p-3 text-body-sm", {
  variants: {
    tone: {
      danger: "border-danger bg-danger-subtle",
      warning: "border-warning bg-warning-subtle",
      success: "border-success bg-success-subtle",
      neutral: "border-border bg-surface",
    },
  },
});

export function DiffPanel({
  diff,
  readyLots,
}: {
  diff: DiffRow | null;
  readyLots: ReadyLot[];
}) {
  if (!diff) {
    return (
      <section aria-live="polite" className={panel({ tone: "neutral" })}>
        <h2 className="text-label text-text-primary">Diff วันนี้</h2>
        <p className="text-text-secondary">
          วันนี้ยังไม่มีเนื้อพร้อมขายเข้าหรือออก — ยังไม่มี Diff ให้ตรวจ
        </p>
      </section>
    );
  }

  const lots = largestFirst(readyLots)
    .map((l) => `ล็อต ${l.lot_code} ${formatKg(l.available_qty)} กก.`)
    .join(", ");
  const left = Number(diff.diff_kg) !== 0;
  const tone =
    diff.verdict === "OVER_THRESHOLD"
      ? "danger"
      : diff.verdict === "REASON_REQUIRED" || left
        ? "warning"
        : "success";

  const message =
    diff.verdict === "OVER_THRESHOLD"
      ? `เกินเกณฑ์ — ปิดวันไม่ได้จนกว่ายอดขายและ Waste จะตรงกัน ตรวจยอดขายที่ยังไม่ได้บันทึกของ${lots ? ` ${lots}` : "ล็อตที่ยังมีเนื้อพร้อมขาย"} ถ้าตัวเลขถูกแล้วแต่ยังเกิน ให้โทรหาเจ้าของร้าน`
      : diff.verdict === "REASON_REQUIRED"
        ? "วันนี้ไม่มีเนื้อละลายเข้า แต่มียอดออก — ต้องเขียนหมายเหตุตอนยืนยันปิดวัน"
        : left
          ? `ยังเหลือเนื้อพร้อมขาย${lots ? ` (${lots})` : ""} — ถ้าขายแล้วให้บันทึกยอดขาย ถ้าเหลือจริงให้ชั่งแล้วบันทึก Waste ก่อนปิดวัน`
          : "Diff เป็นศูนย์ — เนื้อที่ละลายวันนี้มียอดขายหรือ Waste รองรับครบแล้ว";

  return (
    <section aria-live="polite" aria-labelledby="diff-title" className={panel({ tone })}>
      <h2 id="diff-title" className="text-label text-text-primary">
        Diff วันนี้ (จากยอดที่บันทึกแล้ว)
      </h2>
      <dl className="grid grid-cols-2 gap-x-4 gap-y-1 tabular-nums text-text-primary">
        <dt className="text-text-secondary">ละลายพร้อมขาย</dt>
        <dd className="text-right font-mono">{formatKg(diff.ready_in_kg)} กก.</dd>
        <dt className="text-text-secondary">ขาย {Number(diff.sold_pack_qty)} ซอง</dt>
        <dd className="text-right font-mono">{formatKg(diff.sold_kg)} กก.</dd>
        <dt className="text-text-secondary">Waste</dt>
        <dd className="text-right font-mono">{formatKg(diff.wasted_kg)} กก.</dd>
        <dt className="text-label">Diff</dt>
        <dd className="text-right font-mono text-label">
          {formatKg(diff.diff_kg)} กก.
          {diff.variance_pct === null ? "" : ` · ${formatKg(diff.variance_pct)}%`}
        </dd>
      </dl>
      <p className="text-text-primary">{message}</p>
      <p className="text-caption text-text-muted">
        ระบบตรวจอีกครั้งตอนกดปิดวัน — ตัวเลขนี้ไม่ได้ตัดสินแทน
      </p>
    </section>
  );
}
