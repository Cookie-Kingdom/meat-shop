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
#   TC-32  fn_record_physical_count. One batch replayed on ONE key by two sessions at once (a
#          dropped connection that retried while the first call was still running). The replay
#          cannot see the first batch's uncommitted rows, so it passes the key pre-check. Its
#          first insert blocks on physical_counts_batch_key and fails with unique_violation once
#          the first batch commits; the handler returns the committed batch. Both calls must
#          exit 0 with the same ids, and the key must hold one batch, not two.
#          MUTATION CHECK: delete the `when unique_violation` handler. Session B then fails with
#          a raw constraint name — a retry that reads as an error, which R4 forbids.
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
# Wait for the FINAL server over TCP, not the init server on the socket (^fix-startup-race).
. supabase/tests/wait_for_postgres.sh
wait_for_postgres "$CONTAINER" || exit 1

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

############################################################################### TC-32
$PSQL -c "insert into packaging_items (code, name_th, unit) values ('MCPK', 'กล่องสกรีนทดสอบ', 'ใบ')" >/dev/null 2>&1 \
  || { echo "FAIL  TC-32 fixtures"; exit 1; }
PACK_ID=$(Q "select id from packaging_items where code = 'MCPK'")
COUNT_KEY=48484848-4848-4848-4848-4848484848c2

# \$1 is how long to hold the transaction open after the count. Same key, same payload.
count_write() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$ADMIN"}', true);
select fn_record_physical_count('$COUNT_KEY'::uuid, $REPORT,
  '[{"item_type":"PACKAGING","packaging_item_id":"$PACK_ID","counted_qty":40},
    {"item_type":"CHILLI_PASTE","counted_qty":12}]'::jsonb) ->> 'physical_count_ids' as ids;
select pg_sleep($1);
commit;
SQL
}

count_write 2 | $PSQL > "$TMP/count_a.log" 2>&1 &
pid_a=$!
sleep 0.5
count_write 0 | $PSQL > "$TMP/count_b.log" 2>&1 &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?

count_rows=$(Q "select count(*)::text from physical_counts where idempotency_key = '$COUNT_KEY'")
ids_a=$(grep -o '\[.*\]' "$TMP/count_a.log" | head -1)
ids_b=$(grep -o '\[.*\]' "$TMP/count_b.log" | head -1)

[ "$rc_a" -eq 0 ] || { note "TC-32: the first count session failed"; sed 's/^/      /' "$TMP/count_a.log" | tail -5; }
[ "$rc_b" -eq 0 ] || { note "TC-32: the concurrent replay errored — a retry is a return, not a raise (R4)"; sed 's/^/      /' "$TMP/count_b.log" | tail -5; }
[ "$count_rows" = "2" ] || note "TC-32: the key holds $count_rows rows, expected one batch of 2"
if [ -z "$ids_a" ] || [ "$ids_a" != "$ids_b" ]; then
  note "TC-32: the two calls returned different batches ([$ids_a] vs [$ids_b])"
fi

############################################################################### summary
if [ "$failures" -eq 0 ]; then
  echo "PASS  materials_concurrency_test.sh  (rice: one row, both visits kept; count: one batch per key)"
else
  echo "$failures failing"
fi
exit "$failures"
