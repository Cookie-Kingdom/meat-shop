#!/usr/bin/env bash
# Card ^ref-04 acceptance: "migration applies clean on an empty database."
# Card ^ref-63: the same order, against a target — local Docker or the live project.
#
#   bash supabase/tests/migrations_apply_test.sh                    # throwaway Docker: apply, then test
#   bash supabase/tests/migrations_apply_test.sh --db-url "<url>"   # a real database: apply only
#
# There is deliberately no second script. A `deploy.sh` beside this one is exactly how the
# two apply orders drift apart, which is what TICKET-003 closed on. The order is stated once,
# below, and both targets run it.
#
# Docker needs nothing else on the host — no Supabase CLI, no psql. The `--db-url` target
# needs the Supabase CLI (for `db push`) and reuses the same postgres:17 image as its psql
# client. The URL is passed in or read from $SUPABASE_DB_URL; it is never defaulted, never
# echoed, and never stored in this repo.

set -uo pipefail
cd "$(dirname "$0")/../.."

DB_URL="${SUPABASE_DB_URL:-}"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \?//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --db-url) DB_URL="${2:-}"; shift 2 || true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

failures=0

# migrations -> functions -> views -> policies, in that order and for that reason: a policy
# names a view, a view names a helper, and a helper names a table. `migrations/` is numbered
# and applied once; the other three folders are the current statement of the rule and are
# written idempotently (`create or replace function|view`, `drop policy if exists` then
# `create policy`), so re-applying them is a no-op rather than an error. That is why the two
# targets differ only in how `migrations/` is applied — history is replayed once, state is
# restated every time — and never in the order.
#
# `views/` is why a view cannot live in `migrations/`: v_stock_balance calls fn_current_role,
# and the numbered migrations all apply before functions/ does. Its files carry a numeric
# prefix because views form a dependency graph — v_smoke_group_available selects from
# v_stock_balance, and plain alphabetical order would apply it first and fail. (R33)
apply_state_folders() {   # $@ = the psql command to pipe each file into
  local f out rc=0
  for f in supabase/functions/*.sql supabase/views/*.sql supabase/policies/*.sql; do
    [ -e "$f" ] || continue
    if out=$("$@" < "$f" 2>&1); then
      echo "PASS  $(basename "$f")"
    else
      echo "FAIL  $(basename "$f")"
      echo "$out" | sed 's/^/      /' | head -5
      rc=$((rc + 1))
    fi
  done
  return "$rc"
}

# ---------------------------------------------------------------- target: a real database
if [ -n "$DB_URL" ]; then
  PSQL=(docker run --rm -i postgres:17 psql "$DB_URL" -q -v ON_ERROR_STOP=1)

  echo "target: remote database"
  echo "      migrations via \`supabase db push\`; functions/views/policies applied directly"

  if ! supabase db push --db-url "$DB_URL"; then
    echo "FAIL  supabase db push"
    echo "      A diverged migration history is repaired by hand (\`supabase migration repair\`),"
    echo "      not by this script — see TICKET-003. Nothing else was applied."
    exit 1
  fi

  apply_state_folders "${PSQL[@]}" || failures=$?

  # supabase/tests/* is never pointed at a real database: the .sql tests write and roll back
  # by raising, and the .sh tests start their own containers. Run them against Docker.
  echo "SKIP  supabase/tests/* — not run against a remote database"

  if [ "$failures" -eq 0 ]; then echo "applied"; else echo "$failures failing"; fi
  exit "$failures"
fi

# --------------------------------------------------------------- target: throwaway Docker
# The container is removed on exit, pass or fail.
CONTAINER=meatshop-migrations-test
PSQL=(docker exec -i "$CONTAINER" psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1)

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
if ! "${PSQL[@]}" < supabase/tests/local_harness.sql >/dev/null 2>&1; then
  echo "FAIL  local_harness.sql"; exit 1
fi

for f in supabase/migrations/*.sql; do
  [ -e "$f" ] || continue
  if out=$("${PSQL[@]}" < "$f" 2>&1); then
    echo "PASS  $(basename "$f")"
  else
    echo "FAIL  $(basename "$f")"
    echo "$out" | sed 's/^/      /' | head -5
    failures=$((failures + 1))
  fi
done

apply_state_folders "${PSQL[@]}" || failures=$((failures + $?))

# ^ref-63 acceptance: "applying twice changes nothing". The three state folders only claim
# idempotence — a `create policy` that loses its `drop policy if exists` still passes the
# loop above on an empty database and then fails halfway through a live apply. So restate
# them and compare the schema on either side.
schema_snapshot() {
  "${PSQL[@]}" -At <<'SQL'
select line from (
  select 'function ' || p.proname || ' ' || md5(pg_get_functiondef(p.oid)) as line
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
  union all
  select 'view ' || viewname || ' ' || md5(definition)
    from pg_views where schemaname = 'public'
  union all
  select 'policy ' || tablename || ' ' || policyname || ' ' || cmd || ' ' ||
         md5(coalesce(qual, '') || coalesce(with_check, '') ||
             coalesce(array_to_string(roles, ','), ''))
    from pg_policies where schemaname = 'public'
  union all
  select 'grant ' || table_name || ' ' || grantee || ' ' || privilege_type
    from information_schema.role_table_grants where table_schema = 'public'
) t order by line;
SQL
}

before=$(schema_snapshot)
if apply_state_folders "${PSQL[@]}" >/dev/null 2>&1; then
  after=$(schema_snapshot)
  if [ "$before" = "$after" ]; then
    echo "PASS  re-applying functions/views/policies changes nothing"
  else
    echo "FAIL  re-applying functions/views/policies changed the schema"
    diff <(echo "$before") <(echo "$after") | sed 's/^/      /' | head -10
    failures=$((failures + 1))
  fi
else
  echo "FAIL  functions/views/policies are not re-appliable"
  failures=$((failures + 1))
fi

# Each test raises its own <NAME>_PASSED exception to roll back; anything else is a real
# failure. A test that completes without raising has not proved anything, so that fails too.
for f in supabase/tests/*_test.sql; do
  out=$("${PSQL[@]}" < "$f" 2>&1)
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
