import { NextResponse, type NextRequest } from "next/server";

import { createClient } from "@/lib/supabase/server";

/* The middle step of password reset. The emailed link lands here with a one-time code;
 * this exchanges it for a session and forwards to /update-password.
 *
 * A Route Handler and not a page because it has to write the session cookies and return
 * a redirect, and a Server Component can do neither. */

export async function GET(request: NextRequest) {
  const { searchParams, origin } = request.nextUrl;
  const code = searchParams.get("code");
  const next = searchParams.get("next");
  const target = next?.startsWith("/") && !next.startsWith("//") ? next : "/";

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(new URL(target, origin));
  }

  // Expired, already spent, or opened without a code at all.
  return NextResponse.redirect(
    new URL("/forgot-password?error=link_invalid", origin),
  );
}
