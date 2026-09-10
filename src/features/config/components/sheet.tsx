import Link from "next/link";
import type { ReactNode } from "react";
import { cva } from "class-variance-authority";

import { actionLink } from "@/components/ui/controls";

/* The panel every OW 10 sheet renders in: a title, an optional subtitle, a close link, then
 * the body. Opened and closed through the URL, so closing is a link and costs no client
 * JavaScript. */

const sheet = cva("flex flex-col rounded-lg border p-4", {
  variants: {
    tone: {
      /** A create form. The accent border says this appends a row. */
      create: "gap-4 border-accent bg-surface",
      /** Read-only history. */
      history: "gap-3 border-border bg-surface-sunken",
    },
  },
  defaultVariants: { tone: "create" },
});

export function Sheet({
  title,
  subtitle,
  closeHref,
  closeLabel = "ยกเลิก",
  tone,
  children,
}: {
  title: string;
  subtitle?: string;
  closeHref: string;
  closeLabel?: string;
  tone?: "create" | "history";
  children: ReactNode;
}) {
  return (
    <section className={sheet({ tone })}>
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-h2 text-text-primary">{title}</h2>
          {subtitle ? (
            <p className="text-caption text-text-muted">{subtitle}</p>
          ) : null}
        </div>
        <Link href={closeHref} className={actionLink}>
          {closeLabel}
        </Link>
      </div>
      {children}
    </section>
  );
}
