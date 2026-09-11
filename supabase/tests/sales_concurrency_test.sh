#!/usr/bin/env bash
# TC-53 and TC-54 from TDD-sales.md: the two F10 races. Only two sessions can show them,
# because each lives between two transactions.
#
# TC-54 (^ref-45): two sessions close one day under two different keys. fn_close_daily_report
# locks the report row (for update) before it reads any gate. The loser waits on that lock,
# then reads the winner's CLOSED row and raises REPORT_ALREADY_CLOSED. The day ends with one
# closed_at and one UPDATE audit row. Without the lock, both read OPEN, both write, and the
# audit trail shows the day closed twice by two people.
#
# TC-53 (^ref-43), below, is the sale race.
#
#   bash supabase/tests/sales_concurrency_test.sh
#
# READY on one tuple holds 1.00 kg. Each session sells 5 boxes at 0.20 kg, which is 1.00 kg.
# fn_post_ledger's transaction advisory lock on the tuple is the guard: the loser waits for the
# winner's commit, reads 0.00 and is refused with INSUFFICIENT_READY_STOCK, which fn_record_sales
# re-raises from R3's INSUFFICIENT_STOCK. Without the lock, both read 1.00, both commit, and the
# tuple reads -1.00 (BR24, R3).
#
# The fixtures are committed, so both sessions see them. The READY stock is posted through
# fn_post_ledger directly as THAW_IN, not through lane B's fn_record_thaw, so this race does not
# depend on the thaw. thaw_test.sql is where the thaw is exercised. No leg dispatches anything
# to a branch, so lane A's branch-leg guard cannot reach these fixtures either.
#
# Session A sells and then sits in pg_sleep holding its locks. Session B arrives half a second
# later, well inside that window. The container is removed on exit, pass or fail.

set -uo pipefail
cd "$(dirname "$0")/../.."

CONTAINER=meatshop-sales-concurrency-test
PSQL="docker exec -i $CONTAINER psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1"
OWNER=77777777-7777-7777-7777-7777777777d1
ADMIN=77777777-7777-7777-7777-7777777777d2
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

# Fixtures, committed. Branch A holds 1.00 kg READY on one lot's tuple. The day is yesterday
# and OPEN, and the opening window is open, so R28 lets it through.
$PSQL <<SQL >/dev/null 2>&1 || { echo "FAIL  fixtures"; exit 1; }
insert into auth.users (id) values ('$OWNER'), ('$ADMIN');
insert into profiles (id, display_name, role, is_active) values
  ('$OWNER', 'เจ้าของทดสอบพร้อมกัน', 'L1_OWNER',        true),
  ('$ADMIN', 'แอดมินทดสอบพร้อมกัน',  'L2_BRANCH_ADMIN', true);
insert into locations (code, name_th, kind) values ('BRA53', 'สาขาทดสอบขาย', 'BRANCH');
insert into user_locations (profile_id, location_id)
     values ('$ADMIN', (select id from locations where code = 'BRA53'));
insert into lots (lot_code, is_opening, state, event_date)
     values ('LOT-53', true, 'LOT_CLOSED', current_date - 5);
insert into smoke_date_groups (lot_id, smoke_date)
     values ((select id from lots where lot_code = 'LOT-53'), current_date - 5);
insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
     values ((select id from locations where code = 'BRA53'), current_date - 1, now(), '$ADMIN');
select set_config('request.jwt.claims', '{"sub":"$OWNER"}', false);
select fn_set_config(gen_random_uuid(), 'avg_pack_weight_kg', current_date - 30, p_value_numeric => 0.20);
select fn_set_product_price(gen_random_uuid(), (select id from products where code = 'MEAT_BOX'),
                            current_date - 30, 350.00);
select fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', (select id from locations where code = 'BRA53'),
                      'READY', 'THAW_IN', 1.00, current_date - 1,
                      p_lot_id => (select id from lots where lot_code = 'LOT-53'),
                      p_smoke_date_group_id => (select id from smoke_date_groups));
-- TC-54: a second branch whose day holds no stock, no rice model and no materials, so every
-- gate passes and only the race is under test. Its day is yesterday, and the day opens for
-- closing at 21:00 Bangkok on that date, which is already past.
insert into locations (code, name_th, kind) values ('BRB54', 'สาขาทดสอบปิดวัน', 'BRANCH');
insert into user_locations (profile_id, location_id)
     values ('$ADMIN', (select id from locations where code = 'BRB54'));
insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
     values ((select id from locations where code = 'BRB54'), current_date - 1, now(), '$ADMIN');
select fn_set_config(gen_random_uuid(), 'business_day_close_earliest', current_date - 30,
                     p_value_text => '21:00');
SQL

# One sale of 5 boxes (1.00 kg) off the tuple. $1 is how long to hold the transaction open
# afterwards. Each call mints its own key: two devices, nothing shared.
sell() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$ADMIN"}', true);
select fn_record_sales(
  gen_random_uuid(),
  (select id from daily_reports where report_date = current_date - 1
      and location_id = (select id from locations where code = 'BRA53')),
  jsonb_build_array(jsonb_build_object(
    'product_code', 'MEAT_BOX', 'qty', 5,
    'lot_id', (select id from lots where lot_code = 'LOT-53'),
    'smoke_date_group_id', (select id from smoke_date_groups))));
select pg_sleep($1);
commit;
SQL
}

sell 2 | $PSQL > "$TMP/a.log" 2>&1 &
pid_a=$!
sleep 0.5
sell 0 | $PSQL > "$TMP/b.log" 2>&1 &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?

Q() { docker exec -i "$CONTAINER" psql -U postgres -d meatshop -tAq -c "$1"; }
ready_kg=$(Q "select coalesce(sum(qty_delta), 0)::text from stock_ledger where item_type = 'SMOKED_MEAT' and stock_state = 'READY'")
lines=$(Q "select count(*)::text from sales_lines")
sales=$(Q "select count(*)::text from stock_ledger where movement_type = 'SALE'")

failures=0
note() { echo "FAIL  $1"; failures=$((failures + 1)); }

if { [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ]; } || { [ "$rc_a" -ne 0 ] && [ "$rc_b" -ne 0 ]; }; then
  note "TC-53: expected exactly one sale to land (A rc=$rc_a, B rc=$rc_b)"
  sed 's/^/      /' "$TMP/a.log" "$TMP/b.log" | tail -10
fi
if ! grep -qs INSUFFICIENT_READY_STOCK "$TMP/a.log" "$TMP/b.log"; then
  note "TC-53: neither session reported INSUFFICIENT_READY_STOCK; the loser failed for another reason"
fi
[ "$ready_kg" = "0.00" ] || note "TC-53: READY reads $ready_kg kg, expected 0.00 and never negative (BR24, R3)"
[ "$lines" = "1" ]       || note "TC-53: $lines sales line(s) committed, expected 1"
[ "$sales" = "1" ]       || note "TC-53: $sales SALE ledger row(s), expected 1"

# ---------------------------------------------------------------------------------- TC-54
# One close of branch BRB54's day. $1 is how long to hold the transaction open afterwards.
# Each call mints its own key: two devices pressing the button, nothing shared.
close_day() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$ADMIN"}', true);
select fn_close_daily_report(
  gen_random_uuid(),
  (select r.id from daily_reports r join locations l on l.id = r.location_id where l.code = 'BRB54'));
select pg_sleep($1);
commit;
SQL
}

close_day 2 | $PSQL > "$TMP/c.log" 2>&1 &
pid_c=$!
sleep 0.5
close_day 0 | $PSQL > "$TMP/d.log" 2>&1 &
pid_d=$!
wait $pid_c; rc_c=$?
wait $pid_d; rc_d=$?

report="(select r.id from daily_reports r join locations l on l.id = r.location_id where l.code = 'BRB54')"
status=$(Q "select status::text from daily_reports where id = $report")
closes=$(Q "select count(*)::text from audit_log where table_name = 'daily_reports' and action = 'UPDATE' and row_id = $report")

if { [ "$rc_c" -eq 0 ] && [ "$rc_d" -eq 0 ]; } || { [ "$rc_c" -ne 0 ] && [ "$rc_d" -ne 0 ]; }; then
  note "TC-54: expected exactly one close to land (C rc=$rc_c, D rc=$rc_d)"
  sed 's/^/      /' "$TMP/c.log" "$TMP/d.log" | tail -10
fi
if ! grep -qs REPORT_ALREADY_CLOSED "$TMP/c.log" "$TMP/d.log"; then
  note "TC-54: neither session reported REPORT_ALREADY_CLOSED; the loser failed for another reason"
fi
[ "$status" = "CLOSED" ] || note "TC-54: the day reads $status, expected CLOSED"
[ "$closes" = "1" ]      || note "TC-54: $closes UPDATE audit row(s) on the day, expected exactly 1 (R32)"

if [ "$failures" -eq 0 ]; then
  echo "PASS  sales_concurrency_test.sh  (one of two concurrent sales of the last 1.00 kg landed; one of two concurrent closes)"
else
  echo "$failures failing"
fi
exit "$failures"
