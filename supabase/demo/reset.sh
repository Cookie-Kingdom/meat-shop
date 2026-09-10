#!/usr/bin/env bash
# Card ^ref-65 — build or rebuild the demo database (meat-shop-demo) and reseed it. The first
# setup and every later reset are this one run.
#
#   bash supabase/demo/reset.sh
#
# Reads .env.demo.local (gitignored). Refuses Meat Shop outright. ADR-003 forbids deleting a
# ledger row, so a reset never deletes rows: it drops the whole schema and replays it.

set -euo pipefail
cd "$(dirname "$0")/../.."

DEMO_REF=liscfwtgkmxugzygjfaz
PROD_REF=enjbvehfsyhekutjtvce

# ------------------------------------------------------------------------------ 1. guard
[ -f .env.demo.local ] || { echo "FAIL  .env.demo.local is missing"; exit 2; }
set -a; . ./.env.demo.local; set +a

for v in SUPABASE_DB_URL NEXT_PUBLIC_SUPABASE_URL SUPABASE_SECRET_KEY DEMO_USER_PASSWORD; do
  [ -n "${!v:-}" ] || { echo "FAIL  $v is empty in .env.demo.local"; exit 2; }
done
case "$SUPABASE_DB_URL $NEXT_PUBLIC_SUPABASE_URL" in
  *"$PROD_REF"*) echo "FAIL  refusing: that is the Meat Shop project, not the demo"; exit 2 ;;
esac
for v in SUPABASE_DB_URL NEXT_PUBLIC_SUPABASE_URL; do
  case "${!v}" in *"$DEMO_REF"*) ;; *) echo "FAIL  $v does not name meat-shop-demo ($DEMO_REF)"; exit 2 ;; esac
done

PSQL=(docker run --rm -i postgres:17 psql "$SUPABASE_DB_URL" -q -v ON_ERROR_STOP=1)
"${PSQL[@]}" -c 'select 1' >/dev/null || { echo "FAIL  cannot reach the demo database"; exit 1; }

# ---------------------------------------------------------------------- 2. the four users
# New sb_secret_ keys go in `apikey` alone; a legacy service_role JWT also needs the bearer.
AUTH=(-H "apikey: $SUPABASE_SECRET_KEY" -H "Content-Type: application/json")
case "$SUPABASE_SECRET_KEY" in sb_secret_*) ;; *) AUTH+=(-H "Authorization: Bearer $SUPABASE_SECRET_KEY") ;; esac

# ponytail: "already registered" is success and the password is not re-synced. To change
# DEMO_USER_PASSWORD, delete the four users in the dashboard and re-run.
for key in owner chef salaeng minburi; do
  body=$(curl -s -w '\n%{http_code}' -X POST "$NEXT_PUBLIC_SUPABASE_URL/auth/v1/admin/users" "${AUTH[@]}" \
    -d "{\"email\":\"demo-$key@demo.local\",\"password\":\"$DEMO_USER_PASSWORD\",\"email_confirm\":true}")
  code=${body##*$'\n'}
  if [ "$code" = 200 ] || { [ "$code" = 422 ] && grep -q 'email_exists\|already' <<<"$body"; }; then
    echo "PASS  user demo-$key"
  else
    echo "FAIL  user demo-$key: HTTP $code"; echo "${body%$'\n'*}" | head -3; exit 1
  fi
done

# -------------------------------------------------------------------- 3. rebuild `public`
# supabase_migrations goes too, so `db push` below replays every migration instead of
# skipping what the history table remembers. The grants are the pristine project's
# (PLAN Finding 6); 000_revoke_defaults.sql then sweeps them exactly as it does live.
"${PSQL[@]}" <<'SQL'
drop schema if exists supabase_migrations cascade;
drop schema public cascade;
create schema public;
grant usage on schema public to public, postgres, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on tables    to postgres, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on functions to postgres, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to postgres, anon, authenticated, service_role;
SQL
echo "PASS  public rebuilt"

# The order lives in one place (^ref-63); this calls it rather than copying it.
bash supabase/tests/migrations_apply_test.sh --db-url "$SUPABASE_DB_URL"

# ------------------------------------------------------------------------ 4. seed, 5. check
"${PSQL[@]}" < supabase/demo/seed.sql
echo "PASS  seed.sql"

out=$("${PSQL[@]}" < supabase/demo/seed_check.sql 2>&1 || true)
if grep -q "DEMO_SEED_CHECK_PASSED" <<<"$out"; then
  echo "PASS  seed_check.sql"
else
  echo "FAIL  seed_check.sql"; echo "$out" | sed 's/^/      /' | head -8; exit 1
fi
echo "demo reset"
