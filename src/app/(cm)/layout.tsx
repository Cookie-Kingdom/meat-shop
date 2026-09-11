import { RoleShell } from "@/components/shared/role-shell";
import { requireRole } from "@/lib/auth/session";

/* (cm) — CM 01–05, L3_CM_OPERATOR only.
 *
 * The gate is here rather than on each page so a new screen in this group cannot be
 * added without it. It is still only the mirror: RLS decides (ADR-004).
 *
 * No tab set: the operator's nav is งานของฉัน → the lot hub → one step, and every step screen
 * carries its back link (LotHeader). A one-tab bar would be 56px of nothing. */

export default async function CmLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  await requireRole("L3_CM_OPERATOR");
  return <RoleShell title="โรงรมเชียงใหม่">{children}</RoleShell>;
}
