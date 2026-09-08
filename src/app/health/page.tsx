/* ponytail: scaffolding, not a feature. It exists so card ^ref-03's acceptance
 * ("a smoke query from a Server Component returns without error") stays re-runnable
 * instead of being a one-off someone claims to have done. Delete it when ^ref-07
 * lands the real route groups. */

import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

/** Postgres `insufficient_privilege`. Migration 05 revokes all on every table from
 * anon and authenticated, so this is the *expected* answer until `^ref-05` creates the
 * views and functions that grant anything (ADR-002, ADR-004). Reaching this error still
 * proves what the card asks: the URL resolved, the publishable key was accepted, and
 * PostgREST answered. A wrong key returns "Invalid API key" with no code, a wrong URL
 * fails to connect — neither reaches here. */
const DENIED_BY_DESIGN = "42501";

export default async function Health() {
  const supabase = await createClient();
  const { error } = await supabase.from("locations").select("id").limit(1);

  const reached = !error || error.code === DENIED_BY_DESIGN;

  return (
    <main className="text-body text-text-primary bg-surface min-h-svh p-6">
      <p>supabase: {reached ? "ok" : `error — ${error.message}`}</p>
      {error ? (
        <p className="text-caption text-text-secondary mt-2">
          deny-all in force, no policies yet (^ref-05)
        </p>
      ) : null}
    </main>
  );
}
