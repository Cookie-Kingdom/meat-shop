import type { ReactNode } from "react";
import { cva } from "class-variance-authority";
import { CircleCheck, Info, TriangleAlert } from "lucide-react";

/* AlertBanner (DESIGN-CONTRACTS), the CM screens' copy. Colour is never the only carrier: a
 * left edge bar and an icon go with every tone, because this is read in a dim chef house
 * with wet hands (REVIEW 5, 16). Not dismissible — nothing on a CM screen is.
 *
 * `role="alert"` only on danger, so a screen reader announces a refused write and not every
 * informational line. */

const banner = cva("flex gap-3 rounded-lg border border-l-4 p-3 text-body-sm", {
  variants: {
    tone: {
      danger: "border-danger bg-danger-subtle text-danger",
      warning: "border-warning bg-warning-subtle text-warning",
      success: "border-success bg-success-subtle text-success",
      info: "border-border bg-surface text-text-secondary",
    },
  },
  defaultVariants: { tone: "info" },
});

const ICON = {
  danger: TriangleAlert,
  warning: TriangleAlert,
  success: CircleCheck,
  info: Info,
} as const;

export function AlertBanner({
  tone,
  title,
  children,
}: {
  tone: "danger" | "warning" | "success" | "info";
  title?: string;
  children?: ReactNode;
}) {
  const Icon = ICON[tone];
  return (
    <div
      role={tone === "danger" ? "alert" : undefined}
      className={banner({ tone })}
    >
      <Icon aria-hidden className="mt-0.5 size-5 shrink-0" />
      <div className="flex min-w-0 flex-col gap-1">
        {title ? <p className="text-label">{title}</p> : null}
        {children ? <div className="text-text-primary">{children}</div> : null}
      </div>
    </div>
  );
}
