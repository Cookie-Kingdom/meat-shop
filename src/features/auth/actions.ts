"use server";

import { headers } from "next/headers";
import { redirect } from "next/navigation";

import { ROLE_HOME } from "@/lib/auth/session";
import { str } from "@/lib/params";
import { hasUnsetBlocking } from "@/lib/rpc/setup";
import { createClient } from "@/lib/supabase/server";

const MIN_PASSWORD_LENGTH = 8;

/** Only same-origin relative paths, so `?next=` cannot become an open redirect. */
function safeNext(value: string): string {
  return value.startsWith("/") && !value.startsWith("//") ? value : "/";
}

async function origin(): Promise<string> {
  const h = await headers();
  return h.get("origin") ?? `https://${h.get("host")}`;
}

export async function signIn(form: FormData) {
  const email = str(form, "email");
  const password = str(form, "password");
  const next = safeNext(str(form, "next"));

  if (!email || !password) {
    redirect(`/login?error=missing_fields&next=${encodeURIComponent(next)}`);
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    redirect(
      `/login?error=invalid_credentials&next=${encodeURIComponent(next)}`,
    );
  }

  /* ADR-023 (card ^ref-61): an Owner with any BLOCK item unset lands on /owner/setup AT
   * LOGIN — here, once, and not in the (owner) layout, which would drag them back on every
   * navigation and make "may skip it" untrue. Only when no deep link was asked for: a
   * `?next=` from an expired session is honoured, and the banner still names what is unset.
   * The client that just signed in asks, because its session is already in memory. */
  if (next === "/" || next === ROLE_HOME.L1_OWNER) {
    const { data: role } = await supabase.rpc("fn_current_role");
    if (role === "L1_OWNER" && (await hasUnsetBlocking(supabase))) {
      redirect("/owner/setup");
    }
  }

  redirect(next);
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}

export async function requestPasswordReset(form: FormData) {
  const email = str(form, "email");
  if (!email) redirect("/forgot-password?error=missing_fields");

  const supabase = await createClient();
  await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: `${await origin()}/auth/callback?next=/update-password`,
  });

  // Reported as sent whether or not the address has an account — same reason as above.
  redirect("/forgot-password?sent=1");
}

export async function updatePassword(form: FormData) {
  const password = str(form, "password");
  const confirm = str(form, "confirm");

  if (!password || !confirm) redirect("/update-password?error=missing_fields");
  if (password !== confirm)
    redirect("/update-password?error=password_mismatch");
  if (password.length < MIN_PASSWORD_LENGTH) {
    redirect("/update-password?error=password_too_short");
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.updateUser({ password });

  // No live session means the emailed link was already spent or has expired.
  if (error) redirect("/update-password?error=reset_failed");

  redirect("/");
}
