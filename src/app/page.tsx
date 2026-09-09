import { forbidden, redirect } from "next/navigation";

import { ROLE_HOME, getViewer } from "@/lib/auth/session";

/* `/` is a switchboard, not a screen. One place decides where a role lands, so the
 * proxy, sign-in and any future "go home" link cannot disagree.
 *
 * A signed-in session whose profile is deactivated or missing reaches the second
 * branch — `fn_current_role()` returns null for it — and is refused rather than
 * dropped on a blank page. */

export default async function Root() {
  const viewer = await getViewer();
  if (!viewer) redirect("/login");
  if (!viewer.role) forbidden();
  redirect(ROLE_HOME[viewer.role]);
}
