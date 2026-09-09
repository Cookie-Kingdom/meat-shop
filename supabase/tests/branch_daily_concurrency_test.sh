#!/usr/bin/env bash
# TC-33 and TC-34 from TDD-branch-daily-open.md — the two-session cases, which are the only
# ones that can catch a missing daily_reports_one_open.
#
#   bash supabase/tests/branch_daily_concurrency_test.sh
#
# Why a separate runner, same reason as ledger_concurrency_test.sh and
# purchasing_concurrency_test.sh: the bug only exists between two transactions. Opening
# Monday and opening Tuesday each succeed alone. Neither session can see the other's
# uncommitted row, so both find no OPEN report and both believe they may insert. A
# one-session test passes either way, which is exactly what makes it useless here.
#
# WHAT THIS IS PROTECTING. ADR-014 says a 01:00 entry belongs to the previous day. There is
# no shift-boundary time anywhere in the schema and business_day_shift_rule is a `text` key
# with no number in it. The rule is true ONLY because a child row attaches to the branch's
# one OPEN report — sales_lines, thaw_records and the rest all carry daily_report_id NOT
# NULL. Two open reports at one branch and a 01:00 sale has two rows to choose from and
# ADR-014 has no implementation left. That is a silent wrong number in every daily close
# and every Diff downstream, not a crash.
#
# MUTATION CHECK, and it is the point of this file. Drop the index and re-run:
#
#   docker exec … psql -c 'drop index daily_reports_one_open'
#
# TC-34 must then fail — both sessions commit and the branch has Monday and Tuesday open at
# once. If it still passes, the invariant is being enforced by the fixture rather than by
# the database, and Finding 4 is not actually implemented. TC-15 in branch_daily_test.sql
# must fail with it, for the same reason.
#
# The race is made deterministic rather than raced for. Session A opens its day and then
# sits in pg_sleep before committing, so it holds the uncommitted row for a known window.
# Session B arrives half a second in, well inside that window:
#
#   TC-33  same date   B's `on conflict (location_id, report_date) do nothing` blocks on
#                      A's uncommitted row, then returns no row; B re-selects and answers
#                      with A's id. One row, both callers get the same id, no error.
#   TC-34  other date  B blocks on daily_reports_one_open — a unique index makes a waiter
#                      out of the second inserter — then fails it when A commits, and the
#                      handler turns that into REPORT_STILL_OPEN naming A's date.
#
# The container is removed on exit, pass or fail.

set -uo pipefail
cd "$(dirname "$0")/../.."

CONTAINER=meatshop-branch-daily-concurrency-test
PSQL="docker exec -i $CONTAINER psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1"
ADMIN=77777777-7777-7777-7777-777777777796
TMP=$(mktemp -d)

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=meatshop \
  postgres:17 >/dev/null || { echo "FAIL  could not start postgres:17"; exit 1; }
until docker exec "$CONTAINER" pg_isready -U postgres -d meatshop -q 2>/dev/null; do sleep 1; done

$PSQL < supabase/tests/local_harness.sql >/dev/null 2>&1 || { echo "FAIL  local_harness.sql"; exit 1; }
for f in supabase/migrations/*.sql supabase/functions/*.sql supabase/views/*.sql supabase/policies/*.sql; do
  [ -e "$f" ] || continue
  $PSQL < "$f" >/dev/null 2>&1 || { echo "FAIL  applying $(basename "$f")"; exit 1; }
done

# Fixtures, committed on purpose: two sessions have to see the same branch with no open day.
$PSQL <<SQL >/dev/null 2>&1 || { echo "FAIL  fixtures"; exit 1; }
insert into auth.users (id) values ('$ADMIN');
insert into profiles (id, display_name, role, is_active)
     values ('$ADMIN', 'ผู้ดูแลสาขาทดสอบพร้อมกัน', 'L2_BRANCH_ADMIN', true);
insert into locations (code, name_th, kind, rice_model)
     values ('BRC', 'สาขาทดสอบพร้อมกัน', 'BRANCH', 'EXTERNAL_COOKED');
insert into user_locations (profile_id, location_id)
     values ('$ADMIN', (select id from locations where code = 'BRC'));
SQL

failures=0
note() { echo "FAIL  $1"; failures=$((failures + 1)); }
Q() { docker exec -i "$CONTAINER" psql -U postgres -d meatshop -tAq -c "$1"; }

# \$1 is the report date, \$2 is how long to hold the transaction open after opening.
open_day() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$ADMIN"}', true);
select fn_open_daily_report(
  gen_random_uuid(),
  (select id from locations where code = 'BRC'),
  $1) ->> 'daily_report_id' as id;
select pg_sleep($2);
commit;
SQL
}

############################################################################### TC-33
# Same date, two sessions. R5's unique (location_id, report_date) is the natural key that
# carries idempotency (Finding 5) — this asserts it survives the concurrent case, where the
# in-body retry check cannot see the other transaction's row.
open_day "current_date" 2 | $PSQL > "$TMP/a.log" 2>&1 &
pid_a=$!
sleep 0.5
open_day "current_date" 0 | $PSQL > "$TMP/b.log" 2>&1 &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?

rows=$(Q "select count(*)::text from daily_reports where report_date = current_date")
id_a=$(grep -Eo '[0-9a-f-]{36}' "$TMP/a.log" | head -1)
id_b=$(grep -Eo '[0-9a-f-]{36}' "$TMP/b.log" | head -1)

[ "$rc_a" -eq 0 ] || note "TC-33: session A failed opening the day it should have won"
[ "$rc_b" -eq 0 ] || note "TC-33: session B errored on a replay of the same branch-day — a retry is a return, not a raise (R4)"
[ "$rows" = "1" ] || note "TC-33: $rows rows for one branch-day, expected 1 (R5)"
if [ -n "$id_a" ] && [ -n "$id_b" ] && [ "$id_a" != "$id_b" ]; then
  note "TC-33: the two sessions got different ids ($id_a vs $id_b) for one branch-day"
fi

############################################################################### TC-34
# Different dates. This is the assert daily_reports_one_open owns, and the one that flips
# when the index is dropped.
$PSQL -c "update daily_reports set status = 'CLOSED', closed_at = now() where report_date = current_date" >/dev/null 2>&1

open_day "current_date - 1" 2 | $PSQL > "$TMP/c.log" 2>&1 &
pid_c=$!
sleep 0.5
open_day "current_date - 2" 0 | $PSQL > "$TMP/d.log" 2>&1 &
pid_d=$!
wait $pid_c; rc_c=$?
wait $pid_d; rc_d=$?

open_rows=$(Q "select count(*)::text from daily_reports where status = 'OPEN'")

if [ "$rc_c" -eq 0 ] && [ "$rc_d" -eq 0 ]; then
  note "TC-34: both dates opened — the branch has two OPEN days and ADR-014 has no implementation left"
elif [ "$rc_c" -ne 0 ] && [ "$rc_d" -ne 0 ]; then
  note "TC-34: both sessions failed — the first date should have opened"
fi

[ "$open_rows" = "1" ] || note "TC-34: $open_rows OPEN reports at one branch, expected exactly 1 (Finding 4)"

# The refusal has to be legible. A raw `duplicate key value violates unique constraint
# "daily_reports_one_open"` reaching a branch admin is a support ticket — the index is the
# backstop, not the message — and it does not tell them WHICH day to go and close.
if ! grep -qs REPORT_STILL_OPEN "$TMP/c.log" "$TMP/d.log"; then
  note "TC-34: neither session reported REPORT_STILL_OPEN; the loser got a constraint name instead"
  sed 's/^/      /' "$TMP/c.log" "$TMP/d.log" | tail -10
fi

if [ "$failures" -eq 0 ]; then
  echo "PASS  branch_daily_concurrency_test.sh  ($open_rows OPEN report after two concurrent opens of different dates)"
else
  echo "$failures failing"
fi
exit "$failures"
