import Link from "next/link";

import { RoleShell } from "@/components/shared/role-shell";
import { actionLink } from "@/components/ui/controls";
import { requireRole } from "@/lib/auth/session";

/* (branch) — BR 01–09, L2_BRANCH_ADMIN only.
 *
 * The gate is here rather than on each page so a new screen in this group cannot be
 * added without it. It is still only the mirror: RLS decides (ADR-004).
 *
 * The nav holds one line per built screen; each lane that adds a branch screen appends its line
 * (PARALLEL-LANES.md, "Files every lane touches"). */

export default async function BranchLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  await requireRole("L2_BRANCH_ADMIN");
  return (
    <RoleShell title="สาขา">
      <nav aria-label="เมนูสาขา" className="flex flex-wrap gap-x-4">
        <Link href="/branch" className={actionLink}>งานวันนี้</Link>
        <Link href="/branch/receive" className={actionLink}>รับเนื้อเข้าสาขา</Link>
        <Link href="/branch/thaw" className={actionLink}>แบ่งละลายเนื้อ</Link>
      </nav>
      {children}
    </RoleShell>
  );
}
