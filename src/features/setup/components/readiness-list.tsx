import Link from "next/link";
import type { ReactNode } from "react";

import { actionLink } from "@/components/ui/controls";
import type { ReadinessRow } from "@/lib/rpc/setup";
import { cn } from "@/lib/utils";

/* The /owner/setup list (card ^ref-61). One card per readiness row: what it is, what it stops,
 * whether it is set, and where to set it. ADR-023's marker at the point of entry is the dot
 * and the tinted card on an unset row; it clears per item as each one is set.
 *
 * Cards at every width, 72px minimum — a list of nine items is read on a phone, one-handed,
 * and a table would ask for a sideways scroll to reach the action. */

/** Where "ตั้งค่า" goes. `?set=` is OW 10's own URL contract (^ref-12) — `SOURCE:item_key:scope`,
 * or `1` for the item picker — opened on /owner/setup itself so the Owner returns to this
 * list. `null` for the opening switch, which is closed by its own function, not by a form. */
export function setHref(row: ReadinessRow): string | null {
  const to = (set: string) =>
    `/owner/setup?${new URLSearchParams({ set }).toString()}`;
  switch (row.source) {
    case "config_settings":
      return to(`CONFIG:${row.item_key}:`);
    case "smoke_fee_tiers":
      return to("SMOKE_FEE_TIER:smoke_fee_tiers:");
    case "product_prices":
    case "packaging_full_stock":
      return to("1");
    default:
      return null;
  }
}

function statusLine(row: ReadinessRow): string {
  if (row.is_set) return "เรียบร้อยแล้ว";
  return row.severity === "BLOCK"
    ? `ยังไม่ได้ตั้ง — ยังใช้ไม่ได้: ${row.gates_th}`
    : `ควรตั้ง — ${row.gates_th}`;
}

export function ReadinessList({
  rows,
  emptyText,
  extra,
}: {
  rows: ReadinessRow[];
  emptyText: string;
  /** Anything one row needs beyond its link — the packaging seed button, for one. */
  extra?: (row: ReadinessRow) => ReactNode;
}) {
  if (rows.length === 0) {
    return (
      <p className="rounded-lg border border-border bg-surface p-4 text-body-sm text-text-secondary">
        {emptyText}
      </p>
    );
  }

  return (
    <ul className="flex flex-col gap-3">
      {rows.map((row) => {
        const href = setHref(row);
        return (
          <li
            key={row.item_key}
            className={cn(
              "flex min-h-[72px] flex-col gap-2 rounded-lg border p-4 sm:flex-row sm:items-center sm:justify-between",
              row.is_set
                ? "border-border bg-surface"
                : "border-warning bg-warning-subtle",
            )}
          >
            <div className="flex flex-col gap-1">
              <span className="flex items-center gap-2 text-label text-text-primary">
                {row.is_set ? null : (
                  <span
                    aria-hidden
                    className="size-2 shrink-0 rounded-full bg-warning"
                  />
                )}
                {row.label_th}
              </span>
              <span className="text-caption text-text-secondary">
                {statusLine(row)}
              </span>
              {extra?.(row)}
            </div>
            {href ? (
              <Link href={href} className={cn(actionLink, "shrink-0")}>
                {row.is_set ? "ตั้งค่าใหม่" : "ตั้งค่า"}
              </Link>
            ) : null}
          </li>
        );
      })}
    </ul>
  );
}
