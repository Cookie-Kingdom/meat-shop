#!/usr/bin/env bash
# TC-35 from TDD-movement.md — two allocations to one branch on one day, at the same moment, and
# they must share one CENTRAL_TO_BRANCH run.
#
#   bash supabase/tests/movement_concurrency_test.sh
#
# A separate runner for the reason ledger_concurrency_test.sh gives: the bug exists only between
# two transactions. fn_allocate_to_branch finds the day's run for the branch and creates one when
# there is none. Two sessions with two different keys both look before either has committed, both
# find nothing, and both create a run — no unique index can see it, because a run has no natural
# key (…0010). The guard is pg_advisory_xact_lock on (branch, event date): the loser waits for the
# winner's commit, then finds the winner's run.
#
# Both allocations draw on the same group with room for both, so the only thing that can differ
# between a pass and a fail is the run count. fn_post_ledger's own tuple lock would also queue the
# loser — but only AFTER it has created its run, which is why that lock does not save this one.
#
# Session A allocates and then sits in pg_sleep holding its locks; session B arrives half a second
# in, well inside the window. The container is removed on exit, pass or fail.

set -uo pipefail
cd "$(dirname "$0")/../.."

CONTAINER=meatshop-movement-concurrency-test
PSQL="docker exec -i $CONTAINER psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1"
OWNER=77777777-7777-7777-7777-7777777777c6
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

# Fixtures, committed: both sessions must see the same central stock. 20 kg of one group lands at
# central directly — the chain that puts it there is movement_test.sql's, not this file's.
$PSQL <<SQL >/dev/null 2>&1 || { echo "FAIL  fixtures"; exit 1; }
insert into auth.users (id) values ('$OWNER');
insert into profiles (id, display_name, role, is_active)
     values ('$OWNER', 'เจ้าของทดสอบพร้อมกัน', 'L1_OWNER', true);
insert into locations (code, name_th, kind) values ('CH9', 'โรงรมทดสอบ', 'CHEF_HOUSE');
insert into locations (code, name_th, kind) values ('CEN', 'คลังกลางทดสอบ', 'CENTRAL');
insert into locations (code, name_th, kind) values ('BRA', 'สาขาทดสอบ', 'BRANCH');
insert into suppliers (name) values ('Foodiva ทดสอบ');
select set_config('request.jwt.claims', '{"sub":"$OWNER"}', false);
select fn_set_config(gen_random_uuid(), 'freight_alloc_method', current_date - 30,
                     p_value_text => 'BY_LOT_WEIGHT');
select fn_create_po(gen_random_uuid(), (select id from suppliers), current_date - 5, 100.00, 250.00);
select fn_add_po_delivery(gen_random_uuid(), (select id from purchase_orders), current_date - 5,
                          40.00, (select id from locations where kind = 'CHEF_HOUSE'));
insert into smoke_date_groups (lot_id, smoke_date) values ((select id from lots), current_date - 3);
select fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', (select id from locations where kind = 'CENTRAL'),
                      'FROZEN', 'TRANSFER_IN', 20.00, current_date - 1,
                      p_lot_id => (select id from lots),
                      p_smoke_date_group_id => (select id from smoke_date_groups));
SQL

# One allocation of 5 kg / 5 bags to the branch, today. \$1 is how long to hold the transaction
# open afterwards. Each call mints its own key: two clicks on two devices, nothing shared.
allocate() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$OWNER"}', true);
select fn_allocate_to_branch(
  p_idempotency_key      => gen_random_uuid(),
  p_branch_location_id   => (select id from locations where kind = 'BRANCH'),
  p_event_date           => current_date,
  p_smoke_date_group_id  => (select id from smoke_date_groups),
  p_dispatched_weight_kg => 5.00,
  p_bag_count            => 5);
select pg_sleep($1);
commit;
SQL
}

allocate 2 | $PSQL > "$TMP/a.log" 2>&1 &
pid_a=$!
sleep 0.5
allocate 0 | $PSQL > "$TMP/b.log" 2>&1 &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?

Q() { docker exec -i "$CONTAINER" psql -U postgres -d meatshop -tAq -c "$1"; }
runs=$(Q "select count(*)::text from transport_runs where route = 'CENTRAL_TO_BRANCH'")
lines=$(Q "select count(*)::text from transport_lines")
fare=$(Q "select coalesce(sum(run_cost_thb), 0)::text from transport_runs")
central=$(Q "select coalesce(sum(qty_delta), 0)::text from stock_ledger s join locations l on l.id = s.location_id where l.kind = 'CENTRAL'")
transit=$(Q "select coalesce(sum(qty_delta), 0)::text from stock_ledger where stock_state = 'IN_TRANSIT'")

failures=0
note() { echo "FAIL  $1"; failures=$((failures + 1)); }

if [ "$rc_a" -ne 0 ] || [ "$rc_b" -ne 0 ]; then
  note "an allocation failed (A rc=$rc_a, B rc=$rc_b) — both had room and both should land"
  sed 's/^/      /' "$TMP/a.log" "$TMP/b.log" | tail -10
fi
[ "$runs" = "1" ]        || note "$runs CENTRAL_TO_BRANCH run(s) for one branch on one day, expected 1"
[ "$lines" = "2" ]       || note "$lines line(s), expected 2"
[ "$fare" = "0.00" ]     || note "the branch leg carries $fare THB, expected 0.00 (R25)"
[ "$central" = "10.00" ] || note "central holds $central kg, expected 10.00"
[ "$transit" = "10.00" ] || note "$transit kg in transit, expected 10.00"

if [ "$failures" -eq 0 ]; then
  echo "PASS  movement_concurrency_test.sh  ($runs run, $lines lines after two concurrent allocations)"
else
  echo "$failures failing"
fi
exit "$failures"
