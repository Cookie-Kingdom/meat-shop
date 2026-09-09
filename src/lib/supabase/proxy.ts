import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

import { SUPABASE_PUBLISHABLE_KEY, SUPABASE_URL } from "./env";

/** Supabase client for `src/proxy.ts`.
 *
 * A Server Component cannot write cookies, so the refreshed access token has to be
 * written here or the session expires mid-visit. The client is bound to both the
 * incoming request (so the render downstream sees the new token) and the outgoing
 * response (so the browser does).
 *
 * Returns the response it wrote the cookies onto — the caller must return *that*
 * object, or copy its `Set-Cookie` headers onto whatever it returns instead.
 */
export function createProxyClient(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        for (const { name, value } of cookiesToSet) {
          request.cookies.set(name, value);
        }
        response = NextResponse.next({ request });
        for (const { name, value, options } of cookiesToSet) {
          response.cookies.set(name, value, options);
        }
      },
    },
  });

  return { supabase, getResponse: () => response };
}
