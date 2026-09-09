import { RoleShell } from "@/components/shared/role-shell";
import { requireRole } from "@/lib/auth/session";

/* (branch) — BR 01–09, L2_BRANCH_ADMIN only.
 *
 * The gate is here rather than on each page so a new screen in this group cannot be
 * added without it. It is still only the mirror: RLS decides (ADR-004). */

export default async function BranchLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  await requireRole("L2_BRANCH_ADMIN");
  return <RoleShell title="สาขา">{children}</RoleShell>;
}
