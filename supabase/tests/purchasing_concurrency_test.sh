#!/usr/bin/env bash
# TC-20 from TDD-purchasing.md — two concurrent rounds cannot both fit a PO that only has
# room for one of them.
#
#   bash supabase/tests/purchasing_concurrency_test.sh
#
# Why this is a separate runner, same reason as ledger_concurrency_test.sh: the bug only
# exists between two transactions. 60 kg and 60 kg against a 100 kg PO each fit alone.
# Without `for update` on the purchase_orders row both sessions sum the same cumulative of
# 0.00 — neither can see the other's uncommitted round — and both believe there is room.
# A one-session test passes either way, which is exactly what makes it useless here.
#
# WHAT REMOVING THE LOCK ACTUALLY DOES, measured rather than assumed. Mutation-checked by
# deleting `for update` and re-running this file: the second session does NOT commit
# 120.00 kg. It fails on `po_deliveries_po_id_seq_key`, because seq is derived from the same
# rows the overshoot check sums, so two concurrent callers always compute the same seq and
# the unique key serialises them by accident. That index is a real second guard against the
# double-book and this test asserts the data it protects (1 round, 1 lot, 60.00 kg).
#
# So what the lock buys is the REFUSAL ITSELF BEING LEGIBLE, and that is the assert below
# that flips: with it the loser says PO_OVERDELIVERY and names the weights; without it the
# Owner gets `duplicate key value violates unique constraint "po_deliveries_po_id_seq_key"`
# for a round they were entitled to be told was 20 kg too big. A constraint name reaching
# the Owner is a support ticket — the CHECKs and indexes are the backstop, not the message.
# The lock is also what stops the loser having to be rolled back by an index violation at
# all, which is the difference between a refusal and a crash.
#
# The race is made deterministic rather than raced-for. Session A books its round and then
# sits in pg_sleep before committing, so it holds the row lock for a known window. Session B
# arrives half a second in, well inside that window:
#
#   with FOR UPDATE     B blocks until A commits, then re-sums, sees 60.00, refuses by name
#   without FOR UPDATE  B computes the same seq as A and dies on the unique index instead
#
# The container is removed on exit, pass or fail.

set -uo pipefail
cd "$(dirname "$0")/../.."

CONTAINER=meatshop-purchasing-concurrency-test
PSQL="docker exec -i $CONTAINER psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1"
ACTOR=77777777-7777-7777-7777-777777777795
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

# Fixtures, committed on purpose: two sessions have to see the same PO with no rounds on it.
$PSQL <<SQL >/dev/null 2>&1 || { echo "FAIL  fixtures"; exit 1; }
insert into auth.users (id) values ('$ACTOR');
insert into profiles (id, display_name, role, is_active)
     values ('$ACTOR', 'เจ้าของทดสอบพร้อมกัน', 'L1_OWNER', true);
insert into locations (code, name_th, kind) values ('CH9', 'โรงรมทดสอบ', 'CHEF_HOUSE');
insert into suppliers (name) values ('ฟู้ดดีว่าทดสอบ');
select set_config('request.jwt.claims', '{"sub":"$ACTOR"}', false);
select fn_create_po(gen_random_uuid(), (select id from suppliers), current_date - 1, 100.00, 250.00);
SQL

# One 60 kg round. \$1 is how long to hold the transaction open after booking.
book() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$ACTOR"}', true);
select fn_add_po_delivery(
  p_idempotency_key        => gen_random_uuid(),
  p_po_id                  => (select id from purchase_orders),
  p_event_date             => current_date - 1,
  p_foodiva_sent_weight_kg => 60.00,
  p_chef_house_location_id => (select id from locations));
select pg_sleep($1);
commit;
SQL
}

book 2 | $PSQL > "$TMP/a.log" 2>&1 &
pid_a=$!
sleep 0.5
book 0 | $PSQL > "$TMP/b.log" 2>&1 &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?

Q() { docker exec -i "$CONTAINER" psql -U postgres -d meatshop -tAq -c "$1"; }
sent=$(Q "select coalesce(sum(foodiva_sent_weight_kg), 0)::text from po_deliveries")
rounds=$(Q "select count(*)::text from po_deliveries")
lots=$(Q "select count(*)::text from lots")

failures=0
note() { echo "FAIL  $1"; failures=$((failures + 1)); }

if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ]; then
  note "both rounds committed — 120 kg dispatched against a 100 kg order (UAT-01)"
elif [ "$rc_a" -ne 0 ] && [ "$rc_b" -ne 0 ]; then
  note "both rounds failed — the first one should have succeeded"
fi

# The assert the lock owns. Without `for update` the loser still fails — the (po_id, seq)
# index sees to that — but it fails with a constraint name instead of the business rule.
if ! grep -qs PO_OVERDELIVERY "$TMP/a.log" "$TMP/b.log"; then
  note "neither session reported PO_OVERDELIVERY; the loser got a constraint name instead"
  sed 's/^/      /' "$TMP/a.log" "$TMP/b.log" | tail -10
fi

[ "$rounds" = "1" ] || note "expected 1 committed round, found $rounds"
# D01: whatever committed, the round and its lot committed together or neither did.
[ "$lots" = "$rounds" ] || note "$rounds rounds but $lots lots — D01 is one round, one lot"
[ "$sent" = "60.00" ] || note "cumulative dispatched is $sent, expected 60.00"

if [ "$failures" -eq 0 ]; then
  echo "PASS  purchasing_concurrency_test.sh  (dispatched $sent after two concurrent 60.00 kg rounds)"
else
  echo "$failures failing"
fi
exit "$failures"
