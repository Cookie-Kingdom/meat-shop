#!/usr/bin/env bash
# TC-04 from TDD-ledger-core.md — two concurrent draws cannot drive a tuple negative.
#
#   bash supabase/tests/ledger_concurrency_test.sh
#
# Why this is a separate runner. Every other test in this directory is a single psql
# session inside one aborting transaction. This one cannot be: the bug it hunts only
# exists between two transactions. Without the advisory lock in fn_post_ledger, BOTH
# sessions read the same balance — neither can see the other's uncommitted row — and both
# commit, leaving the tuple negative. A one-session test passes either way, which is
# exactly what makes it useless here (BR24, R3, UAT-05).
#
# The race is made deterministic rather than raced-for. Session A posts its draw and then
# sits in pg_sleep before committing, so it holds the transaction-scoped advisory lock for
# a known window. Session B arrives half a second in, well inside that window:
#
#   with the lock     B blocks until A commits, then re-sums, sees 2.00, refuses -8.00
#   without the lock  B sums the pre-A balance of 10.00, allows -8.00, and commits -6.00
#
# The container is removed on exit, pass or fail.

set -uo pipefail
cd "$(dirname "$0")/../.."

CONTAINER=meatshop-concurrency-test
PSQL="docker exec -i $CONTAINER psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1"
ACTOR=77777777-7777-7777-7777-777777777777
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

# Fixtures, committed on purpose: two sessions have to see the same starting balance.
$PSQL <<SQL >/dev/null 2>&1 || { echo "FAIL  fixtures"; exit 1; }
insert into auth.users (id) values ('$ACTOR');
insert into profiles (id, display_name, role, is_active)
     values ('$ACTOR', 'ผู้ทดสอบพร้อมกัน', 'L1_OWNER', true);
insert into locations (code, name_th, kind) values ('CH8', 'โรงรมทดสอบ', 'CHEF_HOUSE');
insert into suppliers (name) values ('ผู้ขายทดสอบ');
insert into purchase_orders (po_number, supplier_id, event_date, ordered_weight_kg, created_by)
     select 'PO-CONC-1', s.id, current_date - 1, 100.00, '$ACTOR' from suppliers s;
insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg)
     select p.id, 1, current_date - 1, 100.00 from purchase_orders p;
insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                  chef_house_location_id, event_date)
     select 'LOT-CONC-1', p.id, d.id, 100.00, l.id, current_date - 1
       from purchase_orders p, po_deliveries d, locations l;
-- The opening balance: 10.00 kg frozen on the lot.
select set_config('request.jwt.claims', '{"sub":"$ACTOR"}', false);
select fn_post_ledger(
  p_idempotency_key => gen_random_uuid(),
  p_item_type       => 'SMOKED_MEAT',
  p_location_id     => (select id from locations),
  p_stock_state     => 'FROZEN',
  p_movement_type   => 'INTAKE',
  p_qty_delta       => 10.00,
  p_business_date   => current_date - 1,
  p_lot_id          => (select id from lots));
SQL

# One draw of -8.00. \$1 is how long to hold the transaction open after posting.
draw() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$ACTOR"}', true);
select fn_post_ledger(
  p_idempotency_key => gen_random_uuid(),
  p_item_type       => 'SMOKED_MEAT',
  p_location_id     => (select id from locations),
  p_stock_state     => 'FROZEN',
  p_movement_type   => 'SALE',
  p_qty_delta       => -8.00,
  p_business_date   => current_date - 1,
  p_lot_id          => (select id from lots));
select pg_sleep($1);
commit;
SQL
}

draw 2 | $PSQL > "$TMP/a.log" 2>&1 &
pid_a=$!
sleep 0.5
draw 0 | $PSQL > "$TMP/b.log" 2>&1 &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?

balance=$(docker exec -i "$CONTAINER" psql -U postgres -d meatshop -tAq \
  -c "select coalesce(sum(qty_delta), 0)::text from stock_ledger")
draws=$(docker exec -i "$CONTAINER" psql -U postgres -d meatshop -tAq \
  -c "select count(*)::text from stock_ledger where movement_type = 'SALE'")

failures=0
note() { echo "FAIL  $1"; failures=$((failures + 1)); }

# Exactly one of the two sessions succeeded, and the other said why it did not.
if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ]; then
  note "both draws committed — the tuple went negative (BR24)"
elif [ "$rc_a" -ne 0 ] && [ "$rc_b" -ne 0 ]; then
  note "both draws failed — the first one should have succeeded"
fi

if ! grep -qs INSUFFICIENT_STOCK "$TMP/a.log" "$TMP/b.log"; then
  note "neither session reported INSUFFICIENT_STOCK; the loser failed for some other reason"
  sed 's/^/      /' "$TMP/a.log" "$TMP/b.log" | tail -10
fi

[ "$draws" = "1" ] || note "expected 1 committed draw, found $draws"
[ "$balance" = "2.00" ] || note "final balance is $balance, expected 2.00"

if [ "$failures" -eq 0 ]; then
  echo "PASS  ledger_concurrency_test.sh  (balance $balance after two concurrent -8.00 draws)"
else
  echo "$failures failing"
fi
exit "$failures"
