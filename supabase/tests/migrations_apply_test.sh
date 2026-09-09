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

# migrations -> functions -> policies, in that order and for that reason: a policy names a
# helper, and a helper names a table. `migrations/` is numbered and applied once; the other
# two folders are the current statement of the rule and are written idempotently
# (`create or replace function`, `drop policy if exists` then `create policy`), so
# re-applying them is a no-op rather than an error.
for f in supabase/migrations/*.sql supabase/functions/*.sql supabase/policies/*.sql; do
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

if [ "$failures" -eq 0 ]; then echo "all green"; else echo "$failures failing"; fi
exit "$failures"
