#!/usr/bin/env bash
# Card ^ref-72 — `pnpm test:e2e [playwright args]`.
#
# Mints a JWT secret and the stack's two keys, brings up and seeds the local stack
# (supabase/tests/stack/up.sh), then runs Playwright. Its webServer builds and starts Next against
# the stack with DEMO_MODE=true. The stack goes down on exit, pass or fail.
#
# Never Meat Shop or meat-shop-demo: every Supabase setting the build reads is set here, to
# 127.0.0.1, and a process variable beats .env.local. playwright.config.ts refuses to run without.

set -uo pipefail
cd "$(dirname "$0")/.."

jwt() {   # $1 = the role claim
  node -e '
    const c = require("crypto"), b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
    const now = Math.floor(Date.now() / 1000);
    const h = b({ alg: "HS256", typ: "JWT" });
    const p = b({ role: process.argv[1], iss: "supabase", iat: now, exp: now + 86400 });
    process.stdout.write(h + "." + p + "." + c.createHmac("sha256", process.env.JWT_SECRET).update(h + "." + p).digest("base64url"));
  ' "$1"
}
rand() { node -e 'process.stdout.write(require("crypto").randomBytes(24).toString("hex"))'; }

export JWT_SECRET; JWT_SECRET=$(rand)
export DEMO_USER_PASSWORD; DEMO_USER_PASSWORD=$(rand)
export E2E_API_PORT=${E2E_API_PORT:-54380} E2E_APP_PORT=${E2E_APP_PORT:-3100}
export NEXT_PUBLIC_SUPABASE_URL="http://127.0.0.1:$E2E_API_PORT"
export NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY; NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=$(jwt anon)
export DEMO_MODE=true

trap 'docker compose -f supabase/tests/stack/compose.yml down -v >/dev/null 2>&1' EXIT

# The service key creates the four users and is not needed after; Next never sees it.
SERVICE_ROLE_KEY=$(jwt service_role) bash supabase/tests/stack/up.sh || exit 1

pnpm exec playwright test "$@"
