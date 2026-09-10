import { cva } from "class-variance-authority";
import { Lock } from "lucide-react";

import type { LotState } from "@/features/production/types";

/* LotStateBadge (DESIGN-CONTRACTS). One state, one tone, one Thai label, defined once so no
 * two screens disagree. It maps the `lot_state` enum as the database has it: the contract's
 * AUTO_CALCULATED and RETURN_PENDING are derived states nothing stores, and RETURN_SCHEDULED
 * is a real value the contract does not list — see the PLAN's Doc deltas.
 *
 * An unrecognised value renders neutral with the raw identifier visible, so schema drift is
 * caught in review instead of rendering as an empty chip. */

const badge = cva(
  "inline-flex h-7 shrink-0 items-center gap-1 rounded-full border px-2.5 text-caption font-medium whitespace-nowrap",
  {
    variants: {
      tone: {
        neutral: "border-border bg-surface-sunken text-text-secondary",
        accent: "border-accent bg-accent-subtle text-accent",
        locked: "border-locked bg-locked-subtle text-locked",
        warning: "border-warning bg-warning-subtle text-warning",
        success: "border-success bg-success-subtle text-success",
      },
    },
    defaultVariants: { tone: "neutral" },
  },
);

type Tone = "neutral" | "accent" | "locked" | "warning" | "success";

const STATE: Record<LotState, { label: string; tone: Tone }> = {
  PO_CREATED: { label: "สร้าง PO แล้ว", tone: "neutral" },
  IN_TRANSIT: { label: "กำลังขนส่ง", tone: "accent" },
  CM_RECEIVED: { label: "เชียงใหม่รับแล้ว", tone: "accent" },
  SMOKING: { label: "กำลังรมควัน", tone: "accent" },
  LOT_CLOSED: { label: "ปิด Lot แล้ว", tone: "locked" },
  RETURN_SCHEDULED: { label: "นัดรับขากลับแล้ว", tone: "locked" },
  CENTRAL_STOCK: { label: "เข้าคลังกลาง", tone: "success" },
  ALLOCATED: { label: "จัดสรรแล้ว", tone: "success" },
  AT_BRANCH: { label: "อยู่ที่สาขา", tone: "success" },
  CONSUMED: { label: "ใช้หมดแล้ว", tone: "neutral" },
};

export function LotStateBadge({ state }: { state: string }) {
  const known = STATE[state as LotState];
  const tone = known?.tone ?? "neutral";
  return (
    <span className={badge({ tone })}>
      {/* Shape, not only colour (REVIEW 16): a locked state carries the lock. */}
      {tone === "locked" ? <Lock aria-hidden className="size-3.5" /> : null}
      {known ? known.label : state}
    </span>
  );
}
