import { RoleShell } from "@/components/shared/role-shell";
import { requireRole } from "@/lib/auth/session";

/* (owner) — OW 01–11, L1_OWNER only.
 *
 * The gate is here rather than on each page so a new screen in this group cannot be
 * added without it. It is still only the mirror: RLS decides (ADR-004). */

export default async function OwnerLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  await requireRole("L1_OWNER");
  return <RoleShell title="เจ้าของกิจการ">{children}</RoleShell>;
}
