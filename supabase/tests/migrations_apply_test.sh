#!/usr/bin/env bash
# Card ^ref-04 acceptance: "migration applies clean on an empty database."
# Card ^ref-63: the same order, against a target — local Docker or the live project.
#
#   bash supabase/tests/migrations_apply_test.sh                    # throwaway Docker: apply, then test
#   bash supabase/tests/migrations_apply_test.sh --db-url "<url>"   # a real database: apply, then assert posture
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

# Was a remote target ASKED FOR? Not the same question as "is DB_URL non-empty", and the
# difference is a silent wrong-target run: `SUPABASE_DB_URL="$(cat missing-file)"` sets the
# variable to the empty string, the script sees no target, and applies to a throwaway
# container instead — printing a full green run against the one target that was never
# broken. That is the exact shape of the defect ^ref-64 exists to close, so the script must
# not be able to do it. `${VAR+x}` is set-ness, not emptiness; that is the whole trick.
TARGET_REQUESTED=0
[ -n "${SUPABASE_DB_URL+x}" ] && TARGET_REQUESTED=1

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \?//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --db-url) DB_URL="${2:-}"; TARGET_REQUESTED=1; shift 2 || true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

if [ "$TARGET_REQUESTED" -eq 1 ] && [ -z "$DB_URL" ]; then
  echo "FAIL  a remote target was asked for and the URL came out empty"
  echo "      Nothing was applied, and nothing was tested. Refusing to fall through to the"
  echo "      throwaway container: that would print a full green run against the wrong"
  echo "      database, which is the defect ^ref-64 exists to close."
  echo "      Usual causes: the file behind \$(cat …) does not exist; \$env:VAR PowerShell"
  echo "      syntax in a bash command; or the variable is not set on the same line, since"
  echo "      shell state does not survive between commands."
  exit 2
fi

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

  # Preflight, before `db push` moves anything. The CLI and this psql reach the database by
  # two different routes, and the second one fails where the first does not: Supabase's
  # direct `db.<ref>.supabase.co` host resolves IPv6-only, and Docker's default bridge has
  # no IPv6, so every state file fails identically after the migrations have already landed.
  # Half-applied is the one outcome worth spending a round trip to avoid.
  if ! out=$("${PSQL[@]}" -c 'select 1' 2>&1); then
    echo "FAIL  cannot reach the database from the postgres:17 container"
    echo "$out" | sed 's/^/      /' | head -3
    echo "      Nothing was applied. If that says \"Network is unreachable\" on an IPv6"
    echo "      address, use the pooler connection string instead of the direct one —"
    echo "      Dashboard > Project Settings > Database > Connection string > Session pooler."
    exit 1
  fi

  if ! supabase db push --db-url "$DB_URL"; then
    echo "FAIL  supabase db push"
    echo "      A diverged migration history is repaired by hand (\`supabase migration repair\`),"
    echo "      not by this script — see TICKET-003. Nothing else was applied."
    exit 1
  fi

  apply_state_folders "${PSQL[@]}" || failures=$?

  # ^ref-64: one exception to "supabase/tests/* is never pointed at a real database".
  # rls_deny_all_test.sql is now posture only — read-only catalogue sweeps, no fixture, no
  # write — and it is the one assertion that MUST run here. The defect it exists to catch
  # is a grant that is real in Docker and inert live, so asserting it against Docker alone
  # asserts the half that was never broken. Everything else still writes, and still runs
  # against Docker only.
  out=$("${PSQL[@]}" < supabase/tests/rls_deny_all_test.sql 2>&1)
  if grep -q "RLS_DENY_ALL_TEST_PASSED" <<<"$out"; then
    echo "PASS  rls_deny_all_test.sql (posture, against this database)"
  else
    echo "FAIL  rls_deny_all_test.sql (posture, against this database)"
    echo "$out" | sed 's/^/      /' | head -8
    failures=$((failures + 1))
  fi
  echo "SKIP  the rest of supabase/tests/* — they write, and are run against Docker"

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
# A REAL QUERY, NOT pg_isready, AND `-d meatshop`, NOT THE DEFAULT `postgres` DB.
# The postgres image runs initdb, brings up a TEMPORARY server on a unix socket to run its
# init scripts, and only then restarts the real one. pg_isready answers `yes` against that
# temporary server, so a fast machine gets through this loop and has its connection dropped
# by the restart a moment later — which surfaces as `FAIL local_harness.sql` with no error
# anyone can see. The image also accepts connections on `postgres` a moment before initdb
# has created ours. `select 1` on our own database, over the same path psql will use, is
# the condition that actually matters.
ready=
for _ in $(seq 1 60); do
  docker exec "$CONTAINER" psql -U postgres -d meatshop -Atqc 'select 1' >/dev/null 2>&1     && { ready=1; break; }
  sleep 1
done
[ -n "$ready" ] || { echo "FAIL  postgres:17 never answered a query within 60s"; exit 1; }

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
  union all
  -- ^ref-64: function EXECUTE, which role_table_grants does not cover. Without this row
  -- the snapshot cannot see 000_revoke_defaults.sql revoking and the per-file grants
  -- restoring, so "applying twice changes nothing" would not actually cover the one
  -- ordering the sweep depends on.
  select 'execute ' || p.proname || ' ' || r.rolname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   cross join (select rolname from pg_roles where rolname in ('anon', 'authenticated')) r
   where n.nspname = 'public' and p.prokind = 'f'
     and has_function_privilege(r.rolname, p.oid, 'EXECUTE')
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
