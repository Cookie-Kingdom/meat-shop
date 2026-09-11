#!/usr/bin/env bash
# TC-29 and TC-54 from TDD-lots.md — the two F6 writes that two sessions can collide on.
#
#   bash supabase/tests/production_concurrency_test.sh
#
# A separate runner for the reason transport_concurrency_test.sh gives: the bug only exists
# between two transactions, and two saves carry two DIFFERENT keys, so nothing at the
# idempotency layer can see them.
#
# TC-29 — TWO BAG RACES, BECAUSE fn_record_lot_bags HAS TWO GUARDS.
#
#   1. The group does not exist yet. Both sessions miss it; the second one's
#      `insert ... on conflict do nothing` waits on the first one's uncommitted row and then
#      does nothing. A plain insert there surfaces unique_violation on (lot_id, smoke_date).
#   2. The group exists. Both lock it FOR UPDATE; the second waits and reads max(seq) only
#      after the first has committed. Without the lock both read the same max, both mint the
#      same seqs, and the second dies on (smoke_date_group_id, seq).
#
# Either failure is an error on a save nobody did wrong, and CM 04's answer to an error is an
# operator typing 60 weights in again — with wet hands.
#
# TC-54 — TWO CLOSES OF ONE LOT, under two keys. fn_close_lot reads the lot `for update`, so
# the second waits, then finds close_idempotency_key already set and raises
# LOT_ALREADY_CLOSED: one winner, one named refusal, one set of PRODUCTION rows. Without the
# lock the loser reads the lot as still SMOKING, sums the raw balance the winner has not
# committed yet, and dies inside fn_post_ledger on INSUFFICIENT_STOCK instead — which is why
# the assertion names the error and not just "B failed".
#
# Deterministic, not raced for: session A writes and sits in pg_sleep before committing; B
# arrives half a second in, well inside the window.
#
# The container is removed on exit, pass or fail.

set -uo pipefail
cd "$(dirname "$0")/../.."

CONTAINER=meatshop-production-concurrency-test
PSQL="docker exec -i $CONTAINER psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1"
OWNER=77777777-7777-7777-7777-7777777777d1
OP=77777777-7777-7777-7777-7777777777d3
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

# Fixtures, committed on purpose: both sessions have to see the same lot and the same log.
# One operator plays both racers — the point under test is the row they compete for, not the
# role check, and TC-09 ... TC-12 own that half. The transport legs are not under test, so
# the lot's state, its receipt and the 98.00 kg raw balance CM 02 leaves are set directly.
$PSQL <<SQL >/dev/null 2>&1 || { echo "FAIL  fixtures"; exit 1; }
insert into auth.users (id) values ('$OWNER'), ('$OP');
insert into profiles (id, display_name, role, is_active) values
  ('$OWNER', 'เจ้าของทดสอบพร้อมกัน', 'L1_OWNER', true),
  ('$OP',    'ผู้ปฏิบัติงานทดสอบพร้อมกัน', 'L3_CM_OPERATOR', true);
insert into locations (code, name_th, kind) values ('CH9', 'โรงรมทดสอบ', 'CHEF_HOUSE');
insert into user_locations (profile_id, location_id) values ('$OP', (select id from locations));
insert into suppliers (name) values ('Foodiva ทดสอบ');

select set_config('request.jwt.claims', '{"sub":"$OWNER"}', false);
select fn_set_config(gen_random_uuid(), 'yield_alert_threshold_pct', current_date - 30,
                     p_value_numeric => 20.00);
select fn_create_po(gen_random_uuid(), (select id from suppliers), current_date - 2, 100.00, 250.00);
select fn_add_po_delivery(gen_random_uuid(), (select id from purchase_orders), current_date - 2,
                          100.00, (select id from locations));
update lots set state = 'CM_RECEIVED', assigned_operator_id = '$OP';
insert into lot_receipts (lot_id, event_date, received_weight_kg, post_drain_weight_kg, recorded_by)
  values ((select id from lots), current_date - 1, 98.00, 96.50, '$OP');
select fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', (select id from locations), 'FROZEN',
                      'TRANSFER_IN', 98.00, current_date - 1, p_lot_id => (select id from lots));

select set_config('request.jwt.claims', '{"sub":"$OP"}', false);
select fn_upsert_smoke_daily_log(gen_random_uuid(), (select id from lots), current_date,
  jsonb_build_array(jsonb_build_object('lot_id', (select id from lots), 'input_weight_kg', 90.00)));
SQL

# One CM 04 save of \$1 bags at 0.50 kg, holding the transaction open \$2 seconds afterwards.
# Each call mints its OWN key: two saves, two clients, nothing shared to catch them.
bags() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$OP"}', true);
select fn_record_lot_bags(gen_random_uuid(), (select id from lots), current_date,
                          array(select 0.50::numeric from generate_series(1, $1)));
select pg_sleep($2);
commit;
SQL
}

# One CM 05 confirm, holding the transaction open \$1 seconds afterwards. Its own key, too.
closer() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$OP"}', true);
select fn_close_lot(gen_random_uuid(), (select id from lots));
select pg_sleep($1);
commit;
SQL
}

Q() { docker exec -i "$CONTAINER" psql -U postgres -d meatshop -tAq -c "$1"; }

failures=0
note() { echo "FAIL  $1"; failures=$((failures + 1)); }

# \$1 names the race; \$2 and \$3 are the bag count and the kilograms expected once both land.
race() {
  bags 60 2 | $PSQL > "$TMP/$1-a.log" 2>&1 &
  pid_a=$!
  sleep 0.5
  bags 10 0 | $PSQL > "$TMP/$1-b.log" 2>&1 &
  pid_b=$!
  wait $pid_a; rc_a=$?
  wait $pid_b; rc_b=$?

  [ "$rc_a" -eq 0 ] || { note "$1: session A's save failed"; sed 's/^/      /' "$TMP/$1-a.log" | tail -5; }
  [ "$rc_b" -eq 0 ] || { note "$1: session B's save failed"; sed 's/^/      /' "$TMP/$1-b.log" | tail -5; }

  groups=$(Q "select count(*) from smoke_date_groups")
  seqs=$(Q "select count(*) || '/' || min(seq) || '/' || max(seq) from lot_bags")
  rollup=$(Q "select bag_count || '/' || packed_weight_kg from smoke_date_groups")

  [ "$groups" = "1" ]       || note "$1: $groups smoke-date groups for one (lot, smoke_date), expected 1 (R7)"
  [ "$seqs" = "$2/1/$2" ]   || note "$1: bags/min seq/max seq read $seqs, expected $2/1/$2 — a bag was lost or a seq reused"
  [ "$rollup" = "$2/$3" ]   || note "$1: the group's roll-up reads $rollup, expected $2/$3 (R7a)"
}

race "new group"      70  35.00
race "existing group" 140 70.00

# TC-54. 140 bags at 0.50 is 70.00 kg of output against a 98.00 kg raw balance, so the one
# legitimate set of PRODUCTION rows is a -98.00 draw and a +70.00 group, netting -28.00; and
# 70 out of a 100 kg dispatch is 30% — one YIELD_ALERT, not two.
closer 2 | $PSQL > "$TMP/close-a.log" 2>&1 &
pid_a=$!
sleep 0.5
closer 0 | $PSQL > "$TMP/close-b.log" 2>&1 &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?

[ "$rc_a" -eq 0 ] || { note "close: session A's close failed"; sed 's/^/      /' "$TMP/close-a.log" | tail -5; }
if [ "$rc_b" -eq 0 ]; then
  note "close: session B closed the same lot a second time"
elif ! grep -q "LOT_ALREADY_CLOSED" "$TMP/close-b.log"; then
  note "close: session B failed, but not with LOT_ALREADY_CLOSED — the lot row was not what they competed for"
  sed 's/^/      /' "$TMP/close-b.log" | tail -5
fi

rows=$(Q "select count(*) || '/' || sum(qty_delta) from stock_ledger where movement_type = 'PRODUCTION'")
alerts=$(Q "select count(*) from notifications where kind = 'YIELD_ALERT'")
[ "$rows" = "2/-28.00" ] || note "close: PRODUCTION rows read $rows, expected 2/-28.00 — one raw draw and one group, once (ADR-025)"
[ "$alerts" = "1" ]      || note "close: $alerts YIELD_ALERT(s), expected 1"

if [ "$failures" -eq 0 ]; then
  echo "PASS  production_concurrency_test.sh  (140 bags in one group after two pairs of concurrent saves; two concurrent closes, one winner, one set of ledger rows)"
else
  echo "$failures failing"
fi
exit "$failures"
