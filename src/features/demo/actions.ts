"use server";

import { notFound, redirect } from "next/navigation";

import { ROLE_HOME, type UserRole } from "@/lib/auth/session";
import { str } from "@/lib/params";
import { createClient } from "@/lib/supabase/server";

import { DEMO_PERSONAS, isDemoMode, isPersonaKey } from "./personas";

/** Sign in as a demo persona: the real auth user, so RLS stays the enforcement (D2, ADR-004).
 * Outside demo mode the action does not exist. */
export async function enterAsPersona(form: FormData) {
  if (!isDemoMode()) notFound();

  const key = str(form, "persona");
  const password = process.env.DEMO_USER_PASSWORD;
  if (!isPersonaKey(key) || !password) redirect("/login?error=demo_unavailable");

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({
    email: DEMO_PERSONAS[key].email,
    password,
  });
  if (error) redirect("/login?error=demo_unavailable");

  // The landing page comes from the role in the database, not from the persona key. The
  // client that just signed in asks, as signIn does — getViewer() is cached per request
  // (PLAN Finding 7).
  const { data: role } = await supabase.rpc("fn_current_role");
  redirect(role ? ROLE_HOME[role as UserRole] : "/");
}
