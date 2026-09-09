#!/usr/bin/env bash
# Card ^ref-04 acceptance: "migration applies clean on an empty database."
#
# Applies the whole chain to a throwaway Postgres, then runs every .sql test file in
# this directory against the result. Needs Docker and nothing else — no Supabase CLI,
# no psql on the host, no connection to the live project.
#
#   bash supabase/tests/migrations_apply_test.sh
#
# The container is removed on exit, pass or fail.

set -uo pipefail
cd "$(dirname "$0")/../.."

CONTAINER=meatshop-migrations-test
PSQL="docker exec -i $CONTAINER psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1"
failures=0

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=meatshop \
  postgres:17 >/dev/null || { echo "FAIL  could not start postgres:17"; exit 1; }
# -d meatshop, not the default `postgres` db: the image accepts connections on `postgres`
# a moment before the initdb script has created ours, and the harness then fails for no
# reason anyone can see.
until docker exec "$CONTAINER" pg_isready -U postgres -d meatshop -q 2>/dev/null; do sleep 1; done

# The auth schema and the anon/authenticated roles that Supabase supplies for free.
if ! $PSQL < supabase/tests/local_harness.sql >/dev/null 2>&1; then
  echo "FAIL  local_harness.sql"; exit 1
fi

# migrations -> functions -> views -> policies, in that order and for that reason: a policy
# names a view, a view names a helper, and a helper names a table. `migrations/` is numbered
# and applied once; the other three folders are the current statement of the rule and are
# written idempotently (`create or replace function|view`, `drop policy if exists` then
# `create policy`), so re-applying them is a no-op rather than an error.
#
# `views/` is why a view cannot live in `migrations/`: v_stock_balance calls fn_current_role,
# and the numbered migrations all apply before functions/ does. Its files carry a numeric
# prefix because views form a dependency graph — v_smoke_group_available selects from
# v_stock_balance, and plain alphabetical order would apply it first and fail.
for f in supabase/migrations/*.sql supabase/functions/*.sql supabase/views/*.sql supabase/policies/*.sql; do
  [ -e "$f" ] || continue
  if out=$($PSQL < "$f" 2>&1); then
    echo "PASS  $(basename "$f")"
  else
    echo "FAIL  $(basename "$f")"
    echo "$out" | sed 's/^/      /' | head -5
    failures=$((failures + 1))
  fi
done

# Each test raises its own <NAME>_PASSED exception to roll back; anything else is a real
# failure. A test that completes without raising has not proved anything, so that fails too.
for f in supabase/tests/*_test.sql; do
  out=$($PSQL < "$f" 2>&1)
  if grep -q "_PASSED" <<<"$out"; then
    echo "PASS  $(basename "$f")"
  else
    echo "FAIL  $(basename "$f")"
    echo "$out" | sed 's/^/      /' | head -8
    failures=$((failures + 1))
  fi
done

# Sibling .sh tests. A test that needs two sessions cannot run inside this container's
# single psql pipeline, so it starts its own throwaway Postgres — and would never be run
# at all if this loop did not call it. Skip this file, or it recurses forever.
for f in supabase/tests/*_test.sh; do
  [ -e "$f" ] || continue
  [ "$(basename "$f")" = "$(basename "$0")" ] && continue
  if out=$(bash "$f" 2>&1); then
    echo "$out" | tail -1
  else
    echo "FAIL  $(basename "$f")"
    echo "$out" | sed 's/^/      /' | tail -8
    failures=$((failures + 1))
  fi
done

if [ "$failures" -eq 0 ]; then echo "all green"; else echo "$failures failing"; fi
exit "$failures"
