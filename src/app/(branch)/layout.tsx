import { RoleShell } from "@/components/shared/role-shell";
import type { NavTab } from "@/components/shared/nav-tabs";
import { requireRole } from "@/lib/auth/session";

/* (branch) — BR 01–09, L2_BRANCH_ADMIN only.
 *
 * The gate is here rather than on each page so a new screen in this group cannot be
 * added without it. It is still only the mirror: RLS decides (ADR-004). */

/* AppShell's L2 set (DESIGN-CONTRACTS.md), scoped to one branch by the views' WHERE. ข้าวเหนียว
 * and ยืนยันปิดวัน are reached from งานวันนี้; five tabs is the cap at 320px. */
const TABS: NavTab[] = [
  { href: "/branch", label: "งานวันนี้", icon: "today" },
  { href: "/branch/receive", label: "รับของ", icon: "receive" },
  { href: "/branch/thaw", label: "ละลาย", icon: "thaw" },
  { href: "/branch/close", label: "ปิดวัน", icon: "close" },
  { href: "/branch/count", label: "วัสดุ", icon: "materials" },
];

export default async function BranchLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  await requireRole("L2_BRANCH_ADMIN");
  return (
    <RoleShell title="สาขา" tabs={TABS}>
      {children}
    </RoleShell>
  );
}
