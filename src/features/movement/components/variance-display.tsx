import { TriangleAlert } from "lucide-react";

import { kg } from "@/lib/format/weight";
import { cn } from "@/lib/utils";

/* VarianceDisplay (DESIGN-CONTRACTS.md). This is the one place on these screens the tolerance rule is
 * rendered, and the one place it is computed for the mirror.
 *
 * THE MIRROR, NOT THE RULE. fn_check_variance decides, inside fn_confirm_transport_receipt
 * (ADR-019, ADR-004). This reproduces it exactly, so the reason field appears on the same
 * keystroke on which the function would demand one:
 *
 *   variance_pct = round(abs(actual - expected) / abs(expected) * 100, 2)
 *   WITHIN when variance_pct <= threshold; expected = 0 is REASON_REQUIRED, never a division
 *
 * It works in integer hundredths of a kilogram and of a percent, never in floats: 20.004% is
 * 20.00% and inside the band, as the function rounds before it compares.
 *
 * `onOverThreshold` is required, because every call site states whether it warns or blocks
 * (ADR-019). OW 06 warns: BR12 is ALERT, the reason is required, and submit stays enabled. */

export type Verdict = {
  /** actual − expected, in hundredths of a kg. */
  diffH: number;
  /** variance in hundredths of a percent; null when expected is zero. */
  pctH: number | null;
  /** true = over (or expected zero); false = within; null = no threshold configured. */
  over: boolean | null;
};

export function varianceVerdict(
  expectedH: number,
  actualH: number,
  thresholdH: number | null,
): Verdict {
  const diffH = actualH - expectedH;
  if (expectedH === 0) return { diffH, pctH: null, over: true };
  const base = Math.abs(expectedH);
  // round(|diff| / expected × 100, 2), half away from zero, in integers.
  const pctH = Math.floor((2 * Math.abs(diffH) * 10000 + base) / (2 * base));
  return {
    diffH,
    pctH,
    over: thresholdH === null ? null : pctH > thresholdH,
  };
}

const pct = (h: number) =>
  `${Math.floor(h / 100)}.${String(h % 100).padStart(2, "0")}`;

export function VarianceDisplay({
  expectedKg,
  verdict,
  actualKg,
  thresholdPct,
  comparison,
  onOverThreshold,
}: {
  expectedKg: number;
  actualKg: string;
  verdict: Verdict;
  thresholdPct: number | null;
  /** Thai — what the actual is compared against. */
  comparison: string;
  onOverThreshold: "warn" | "block";
}) {
  const { diffH, pctH, over } = verdict;
  const sign = diffH < 0 ? "−" : diffH > 0 ? "+" : "";
  const tone =
    over === true
      ? "border-danger bg-danger-subtle text-danger"
      : over === false && diffH !== 0
        ? "border-warning bg-warning-subtle text-warning"
        : "border-border bg-surface-sunken text-text-secondary";

  return (
    <div
      aria-live="polite"
      className={cn(
        "flex flex-col gap-1 rounded-lg border p-3 text-body-sm",
        tone,
      )}
    >
      <span className="text-text-secondary tabular-nums">
        {comparison} {kg(expectedKg)} กก. · รับจริง {kg(actualKg)} กก.
      </span>
      <span className="text-label tabular-nums">
        ต่าง {sign}
        {kg(Math.abs(diffH) / 100)} กก.
        {pctH === null ? "" : ` · ${pct(pctH)}%`}
      </span>
      <span className="flex items-start gap-2">
        {over === true ? (
          <TriangleAlert aria-hidden className="mt-0.5 size-4 shrink-0" />
        ) : null}
        {pctH === null
          ? "ไม่มีตัวเลขฝั่งส่งออกให้เทียบ — ต้องมีเหตุผล"
          : over === null
            ? "ยังไม่ได้ตั้งเกณฑ์ส่วนต่างตอนรับของ จึงบอกไม่ได้ว่าเกินหรือไม่"
            : over
              ? onOverThreshold === "warn"
                ? `เกินเกณฑ์ ${thresholdPct}% — ต้องกรอกเหตุผล แล้วบันทึกต่อได้`
                : `เกินเกณฑ์ ${thresholdPct}% — บันทึกไม่ได้`
              : `อยู่ในเกณฑ์ ${thresholdPct}%`}
      </span>
    </div>
  );
}
