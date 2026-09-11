import { RoleShell } from "@/components/shared/role-shell";
import type { NavTab } from "@/components/shared/nav-tabs";
import { requireRole } from "@/lib/auth/session";

/* (owner) — OW 01–11, L1_OWNER only.
 *
 * The gate is here rather than on each page so a new screen in this group cannot be
 * added without it. It is still only the mirror: RLS decides (ADR-004). */

/* AppShell's L1 set (DESIGN-CONTRACTS.md): the daily four, and the home list as "เพิ่มเติม". */
const TABS: NavTab[] = [
  { href: "/owner", label: "หน้าหลัก", icon: "home" },
  { href: "/owner/dashboard", label: "แดชบอร์ด", icon: "dashboard" },
  { href: "/owner/lots", label: "ล็อต", icon: "lots" },
  { href: "/owner/allocate", label: "จัดสรร", icon: "allocate" },
  { href: "/owner/expenses", label: "ค่าใช้จ่าย", icon: "expenses" },
];

export default async function OwnerLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  await requireRole("L1_OWNER");
  return (
    <RoleShell title="เจ้าของกิจการ" tabs={TABS}>
      {children}
    </RoleShell>
  );
}
