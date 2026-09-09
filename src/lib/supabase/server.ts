import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";

import { SUPABASE_PUBLISHABLE_KEY, SUPABASE_URL } from "./env";

/** Supabase client for Server Components, Server Actions and Route Handlers.
 *
 * A new client per render — never hoist this to a module-level singleton, or one
 * request's session leaks into another's, and RLS decides on that session (ADR-002).
 */
export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, options);
          }
        } catch {
          // A Server Component cannot write cookies. Harmless here: `src/proxy.ts`
          // refreshes the session and writes it back on every request instead.
        }
      },
    },
  });
}
