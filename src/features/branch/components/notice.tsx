import type { ReactNode } from "react";
import { cva } from "class-variance-authority";

/* One-line outcome and precondition messages on the branch screens. Tone carries the meaning;
 * `locked` is a closed day, not an error — nothing is wrong, the day is simply settled. */

const notice = cva("rounded-lg border p-3 text-body-sm", {
  variants: {
    tone: {
      success: "border-success bg-success-subtle text-success",
      danger: "border-danger bg-danger-subtle text-danger",
      warning: "border-warning bg-warning-subtle text-text-primary",
      locked: "border-border bg-locked-subtle text-text-secondary",
    },
  },
  defaultVariants: { tone: "warning" },
});

export function Notice({
  tone,
  children,
}: {
  tone?: "success" | "danger" | "warning" | "locked";
  children: ReactNode;
}) {
  return (
    <div role={tone === "danger" ? "alert" : "status"} className={notice({ tone })}>
      {children}
    </div>
  );
}

/** A signed-in L2 with no branch assignment, or a read that failed. */
export function NoBranch({ error }: { error: string | null }) {
  return error ? (
    <Notice tone="danger">อ่านข้อมูลสาขาไม่สำเร็จ — {error}</Notice>
  ) : (
    <Notice tone="warning">
      บัญชีนี้ยังไม่ได้ผูกกับสาขาใด — แจ้งเจ้าของร้านให้กำหนดสาขา
    </Notice>
  );
}
