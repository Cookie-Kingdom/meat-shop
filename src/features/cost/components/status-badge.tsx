import type { ReactNode } from "react";
import { cva } from "class-variance-authority";

/* A small state marker for the F7 screens: complete vs provisional cost (R30), an alerting
 * lot (R16), a lot's state. Text always carries the meaning; the tone only reinforces it. */

const badge = cva(
  "inline-flex items-center rounded-md border px-2 py-0.5 text-caption whitespace-nowrap",
  {
    variants: {
      tone: {
        success: "border-success bg-success-subtle text-success",
        warning: "border-warning bg-warning-subtle text-warning",
        danger: "border-danger bg-danger-subtle text-danger",
        neutral: "border-border bg-surface-sunken text-text-secondary",
      },
    },
    defaultVariants: { tone: "neutral" },
  },
);

export function StatusBadge({
  tone,
  children,
}: {
  tone?: "success" | "warning" | "danger" | "neutral";
  children: ReactNode;
}) {
  return <span className={badge({ tone })}>{children}</span>;
}
