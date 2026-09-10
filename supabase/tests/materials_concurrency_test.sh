#!/usr/bin/env bash
# The two-session cases from TDD-materials.md: TC-31 (^ref-48) and TC-32 (^ref-49).
#
#   bash supabase/tests/materials_concurrency_test.sh
#
# Why a separate runner, the same reason as branch_daily_concurrency_test.sh: each bug only
# exists between two transactions. Neither session can see the other's uncommitted row, so a
# one-session test passes whether the function is right or wrong.
#
#   TC-31  fn_record_rice. The morning visit (cooked received) and the evening visit (cooked
#          remaining) arrive on one report at once, under different keys. The evening's
#          `insert … on conflict (daily_report_id) do update` blocks on the morning's uncommitted
#          row, then merges against it. The row must end up holding BOTH halves.
#          MUTATION CHECK: rewrite the DO UPDATE as `coalesce(param, <value read before the
#          insert>)`. The evening's pre-read then sees no row, writes null over the morning's
#          10.00, and this case fails. If it still passes, the merge is not what makes it pass.
#
# The race is made deterministic rather than raced for: session A writes, then sits in pg_sleep
# before committing; session B arrives half a second in, inside that window.
#
# The container is removed on exit, pass or fail.

set -uo pipefail
cd "$(dirname "$0")/../.."

CONTAINER=meatshop-materials-concurrency-test
PSQL="docker exec -i $CONTAINER psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1"
ADMIN=48484848-4848-4848-4848-484848484896
TMP=$(mktemp -d)

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
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

$PSQL < supabase/tests/local_harness.sql >/dev/null 2>&1 || { echo "FAIL  local_harness.sql"; exit 1; }
for f in supabase/migrations/*.sql supabase/functions/*.sql supabase/views/*.sql supabase/policies/*.sql; do
  [ -e "$f" ] || continue
  $PSQL < "$f" >/dev/null 2>&1 || { echo "FAIL  applying $(basename "$f")"; exit 1; }
done

# Fixtures, committed on purpose: both sessions have to see the same open report.
$PSQL <<SQL >/dev/null 2>&1 || { echo "FAIL  fixtures"; exit 1; }
insert into auth.users (id) values ('$ADMIN');
insert into profiles (id, display_name, role, is_active)
     values ('$ADMIN', 'ผู้ดูแลสาขาทดสอบวัสดุพร้อมกัน', 'L2_BRANCH_ADMIN', true);
insert into locations (code, name_th, kind, rice_model)
     values ('MCR', 'สาขาทดสอบวัสดุพร้อมกัน', 'BRANCH', 'EXTERNAL_COOKED');
insert into user_locations (profile_id, location_id)
     values ('$ADMIN', (select id from locations where code = 'MCR'));
insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
     values ((select id from locations where code = 'MCR'), current_date, now(), '$ADMIN');
SQL

failures=0
note() { echo "FAIL  $1"; failures=$((failures + 1)); }
Q() { docker exec -i "$CONTAINER" psql -U postgres -d meatshop -tAq -c "$1"; }

REPORT="(select id from daily_reports where report_date = current_date and location_id = (select id from locations where code = 'MCR'))"

# \$1 is the named rice argument, e.g. "p_cooked_received_kg => 10.00"; \$2 is how long to hold
# the transaction open after the write.
rice_write() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$ADMIN"}', true);
select fn_record_rice(gen_random_uuid(), $REPORT, $1) ->> 'rice_record_id' as id;
select pg_sleep($2);
commit;
SQL
}

############################################################################### TC-31
rice_write "p_cooked_received_kg => 10.00" 2 | $PSQL > "$TMP/rice_a.log" 2>&1 &
pid_a=$!
sleep 0.5
rice_write "p_cooked_remaining_kg => 2.00" 0 | $PSQL > "$TMP/rice_b.log" 2>&1 &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?

rice_rows=$(Q "select count(*)::text from rice_records")
rice_pair=$(Q "select coalesce(cooked_received_kg::text, 'null') || '/' || coalesce(cooked_remaining_kg::text, 'null') from rice_records")

[ "$rc_a" -eq 0 ] || { note "TC-31: the morning session failed"; sed 's/^/      /' "$TMP/rice_a.log" | tail -5; }
[ "$rc_b" -eq 0 ] || { note "TC-31: the evening session failed — a concurrent second visit is normal, not an error"; sed 's/^/      /' "$TMP/rice_b.log" | tail -5; }
[ "$rice_rows" = "1" ] || note "TC-31: $rice_rows rice rows for one report, expected 1"
[ "$rice_pair" = "10.00/2.00" ] || note "TC-31: the row holds [$rice_pair] (received/remaining), expected 10.00/2.00 — one visit erased the other"

############################################################################### summary
if [ "$failures" -eq 0 ]; then
  echo "PASS  materials_concurrency_test.sh  (rice: one row, both visits kept)"
else
  echo "$failures failing"
fi
exit "$failures"
