import { NextResponse, type NextRequest } from "next/server";

import { createProxyClient } from "@/lib/supabase/proxy";

/* Next.js 16 renamed `middleware.ts` to `proxy.ts` and `middleware` to `proxy`
 * (`node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/middleware.md`).
 * Every @supabase/ssr example in circulation still uses the old names. */

/** Routes reachable with no session. Everything else needs one. */
const PUBLIC_PREFIXES = ["/login", "/forgot-password", "/auth/callback"];

/** Where a signed-in session has no business being. */
const AUTH_ONLY_PREFIXES = ["/login", "/forgot-password"];

const isUnder = (pathname: string, prefixes: string[]) =>
  prefixes.some((p) => pathname === p || pathname.startsWith(`${p}/`));

export async function proxy(request: NextRequest) {
  const { supabase, getResponse } = createProxyClient(request);

  // Refreshing the token is the reason this runs at all. Nothing between the client
  // and this call — @supabase/ssr writes the new cookies from inside getUser().
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { pathname } = request.nextUrl;

  // Optimistic only. The role check is in the route-group layout and the enforcement
  // is RLS (ADR-004); the proxy is skipped entirely for a Server Action posted to a
  // path this matcher excludes, so it can never be the thing that decides.
  if (!user && !isUnder(pathname, PUBLIC_PREFIXES)) {
    const login = new URL("/login", request.url);
    if (pathname !== "/") login.searchParams.set("next", pathname);
    return NextResponse.redirect(login);
  }

  if (user && isUnder(pathname, AUTH_ONLY_PREFIXES)) {
    return NextResponse.redirect(new URL("/", request.url));
  }

  return getResponse();
}

export const config = {
  // Without a matcher the proxy also runs on _next/static, _next/image and public/,
  // and the redirect above would then withhold the CSS and JS of the login page itself.
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
