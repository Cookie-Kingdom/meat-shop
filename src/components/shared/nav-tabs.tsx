"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  Boxes,
  ClipboardList,
  House,
  LayoutDashboard,
  Lock,
  Package,
  PackageCheck,
  Snowflake,
  Truck,
  Wallet,
} from "lucide-react";

import { cn } from "@/lib/utils";

/* AppShell's nav (design/DESIGN-CONTRACTS.md): a 56px bottom tab bar below `lg:`, an inline
 * row from `lg:` up. Each role group passes its own set — there is no shared nav with hidden
 * items; the set is the visible edge of the RLS boundary (ADR-004). Icons are named rather than
 * passed because a Server Component layout cannot hand a function to a Client Component.
 *
 * ponytail: the `lg:` sidebar the contract draws is an inline row here — a sidebar when OW 08
 * needs the width. */

const ICONS = {
  home: House,
  dashboard: LayoutDashboard,
  lots: Boxes,
  allocate: Truck,
  expenses: Wallet,
  today: ClipboardList,
  receive: PackageCheck,
  thaw: Snowflake,
  close: Lock,
  materials: Package,
} as const;

export type NavTab = { href: string; label: string; icon: keyof typeof ICONS };

export function NavTabs({ tabs }: { tabs: NavTab[] }) {
  const pathname = usePathname();
  /* Longest matching prefix wins, so /owner/lots/results lights ล็อต and not หน้าหลัก. */
  const current = tabs
    .filter((t) => pathname === t.href || pathname.startsWith(`${t.href}/`))
    .sort((a, b) => b.href.length - a.href.length)[0];

  return (
    <nav
      aria-label="เมนูหลัก"
      /* The safe-area inset has no token: it is the device's, not ours (REVIEW 1). */
      className="fixed inset-x-0 bottom-0 z-20 flex border-t border-border bg-surface pb-[env(safe-area-inset-bottom)] lg:static lg:gap-1 lg:border-t-0 lg:border-b lg:px-4 lg:pb-0"
    >
      {tabs.map((t) => {
        const Icon = ICONS[t.icon];
        const active = t === current;
        return (
          <Link
            key={t.href}
            href={t.href}
            aria-current={active ? "page" : undefined}
            className={cn(
              "flex h-14 min-w-0 flex-1 flex-col items-center justify-center gap-0.5 px-1 text-caption lg:h-11 lg:flex-none lg:flex-row lg:gap-2 lg:px-3 lg:text-label",
              active
                ? "text-accent"
                : "text-text-secondary hover:text-text-primary",
            )}
          >
            <Icon aria-hidden className="size-5 shrink-0" />
            <span className="truncate">{t.label}</span>
          </Link>
        );
      })}
    </nav>
  );
}
