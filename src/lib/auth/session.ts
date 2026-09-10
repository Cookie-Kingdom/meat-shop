import { cache } from "react";
import { forbidden, redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";

export type UserRole = "L1_OWNER" | "L2_BRANCH_ADMIN" | "L3_CM_OPERATOR";

export type Viewer = {
  userId: string;
  /** null when the profile is deactivated or has no row — `fn_current_role()` folds
   * `is_active` in, so there is no second place to forget the check (TC-07). */
  role: UserRole | null;
  email: string | null;
};

/** Where each role lands. One place decides, so `/` and every post-login redirect agree. */
export const ROLE_HOME: Record<UserRole, string> = {
  L1_OWNER: "/owner",
  L2_BRANCH_ADMIN: "/branch",
  L3_CM_OPERATOR: "/cm",
};

/** The signed-in caller and their role, or null if there is no session.
 *
 * The role is fetched per request rather than read off the JWT: a claim goes stale the
 * moment the Owner deactivates someone mid-session, and this call cannot. `cache` keeps
 * a layout and the page beneath it to one round trip (ADR-004 — this is the mirror, RLS
 * is the enforcement).
 */
export const getViewer = cache(async (): Promise<Viewer | null> => {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data } = await supabase.rpc("fn_current_role");

  return {
    userId: user.id,
    role: (data as UserRole | null) ?? null,
    email: user.email ?? null,
  };
});

/** Gate a route group. Signed out → `/login`; wrong or missing role → 403.
 *
 * A refusal is a 403 and not a redirect on purpose: bounced to their own home, a user
 * with a broken role sees navigation where the truth is a permissions failure.
 */
export async function requireRole(...allowed: UserRole[]): Promise<Viewer> {
  const viewer = await getViewer();
  if (!viewer) redirect("/login");
  if (!viewer.role || !allowed.includes(viewer.role)) forbidden();
  return viewer;
}
