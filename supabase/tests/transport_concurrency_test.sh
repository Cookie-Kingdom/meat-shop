#!/usr/bin/env bash
# TC-41 from TDD-transport.md — two people sign for the same load at the same moment, and
# only one TRANSFER_IN may exist afterwards.
#
#   bash supabase/tests/transport_concurrency_test.sh
#
# Why this is a separate runner, the same reason as ledger_concurrency_test.sh and
# purchasing_concurrency_test.sh: the bug only exists between two transactions. A receipt
# confirmed twice from one session is a replay and the key catches it. Two sessions with two
# DIFFERENT keys — the CM operator on the tablet and the Owner on a laptop, both looking at
# the same line — carry no shared key at all, so nothing at the idempotency layer can see
# them. Only the row lock can.
#
# WHAT IS AT STAKE. transport_lines.received_weight_kg is a single column, so the second
# UPDATE would simply overwrite the first and look harmless. The damage is one layer down:
# each session also posts its own pair of ledger rows, and stock_ledger is append-only
# (ADR-003), so the second pair cannot be taken back. 40 kg received twice is 80 kg of FROZEN
# stock at the chef house against a truck that carried 40, and the only way back is a
# reversal row somebody has to notice is needed.
#
# THE GUARD BEING TESTED is `select ... for update` on the line, plus receipt_idempotency_key
# from migration ...0010. The loser blocks until the winner commits, re-reads the row, finds
# the key already set by a DIFFERENT key, and raises LINE_ALREADY_RECEIVED rather than
# posting a second TRANSFER_IN.
#
# WHAT REMOVING THE LOCK ACTUALLY DOES, measured rather than assumed — and it is not what
# the paragraph above would lead you to expect. Mutation-checked by deleting `for update`
# from the SELECT in fn_confirm_transport_receipt.sql and re-running: FROZEN does **not**
# read 80.00. It reads 40.00, every data assert below still passes, and the loser dies with
#
#   ERROR:  INSUFFICIENT_STOCK: balance 0.00 cannot absorb -40.00 (BR24/R3)
#
# because fn_post_ledger takes its own advisory lock on the tuple and refuses to take a
# balance negative. The winner's TRANSFER_IN has already emptied IN_TRANSIT, so the loser's
# whole transaction aborts and its UPDATE rolls back with it. The ledger was never in
# danger. This is the same shape as the finding in fn_add_po_delivery's header one card
# back, where a unique index on (po_id, seq) turned out to be serialising the double-book
# by accident — a real second guard nobody had planned.
#
# SO WHAT THE ROW LOCK ACTUALLY BUYS IS THE REFUSAL BEING LEGIBLE, and that is the assert
# below that flips: with it, the loser says LINE_ALREADY_RECEIVED and names the line and
# when it was signed for; without it, a CM operator who was entitled to be told "somebody
# else already signed for this load" gets INSUFFICIENT_STOCK about a balance they never
# asked about. A stock-level error reaching a receiver is a support ticket. It is also the
# difference between a refusal and a crash: with the lock the loser is turned away before
# it touches the ledger at all.
#
# The unique index on receipt_idempotency_key saves nothing here, and that part of the
# paragraph above is correct — the two keys are genuinely different, so both are unique.
#
# The race is made deterministic rather than raced for. Session A signs and then sits in
# pg_sleep before committing, holding the row lock for a known window; session B arrives half
# a second in, well inside it.
#
# The container is removed on exit, pass or fail.

set -uo pipefail
cd "$(dirname "$0")/../.."

CONTAINER=meatshop-transport-concurrency-test
PSQL="docker exec -i $CONTAINER psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1"
OWNER=77777777-7777-7777-7777-7777777777c1
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

# Fixtures, committed on purpose: both sessions have to see the same dispatched line.
# The Owner signs for a CENTRAL destination, so one profile can play both racers — the point
# under test is the row lock, not the role check, and TC-26/TC-27 own the role half.
$PSQL <<SQL >/dev/null 2>&1 || { echo "FAIL  fixtures"; exit 1; }
insert into auth.users (id) values ('$OWNER');
insert into profiles (id, display_name, role, is_active)
     values ('$OWNER', 'เจ้าของทดสอบพร้อมกัน', 'L1_OWNER', true);
-- Two locations, and both are needed. A lot is dispatched to a CHEF_HOUSE or
-- fn_add_po_delivery refuses it by name (BR11); the transport line's DESTINATION is
-- CENTRAL, because that is the kind fn_confirm_transport_receipt resolves to L1 (or, since
-- ^ref-35, a can_receive_central delegate) and one profile then plays both racers.
insert into locations (code, name_th, kind) values ('CH9', 'โรงรมทดสอบ', 'CHEF_HOUSE');
insert into locations (code, name_th, kind) values ('CEN', 'คลังกลางทดสอบ', 'CENTRAL');
insert into suppliers (name) values ('ฟู้ดดีว่าทดสอบ');
select set_config('request.jwt.claims', '{"sub":"$OWNER"}', false);

select fn_set_config(gen_random_uuid(), 'freight_alloc_method', current_date - 30,
                     p_value_text => 'BY_LOT_WEIGHT');
select fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', current_date - 30,
                     p_value_numeric => 20.00);
select fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', current_date - 30,
                     p_value_text => 'true');
select fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', current_date - 30,
                     p_value_text => 'true');

select fn_create_po(gen_random_uuid(), (select id from suppliers), current_date - 2, 100.00, 250.00);
select fn_add_po_delivery(gen_random_uuid(), (select id from purchase_orders), current_date - 2,
                          40.00, (select id from locations where kind = 'CHEF_HOUSE'));
select fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', current_date - 1,
                               'รถห้องเย็น', false, 4500.00);
select fn_dispatch_transport_line(gen_random_uuid(), (select id from transport_runs),
                                  (select id from lots), null, null,
                                  (select id from locations where kind = 'CENTRAL'), 40.00);
SQL

# One receipt for the whole 40 kg. \$1 is how long to hold the transaction open after signing.
# Each call mints its OWN key, which is the whole point: two people, two clients, no shared
# idempotency key to catch them.
sign() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$OWNER"}', true);
select fn_confirm_transport_receipt(
  p_idempotency_key    => gen_random_uuid(),
  p_line_id            => (select id from transport_lines),
  p_event_date         => current_date,
  p_received_weight_kg => 40.00);
select pg_sleep($1);
commit;
SQL
}

sign 2 | $PSQL > "$TMP/a.log" 2>&1 &
pid_a=$!
sleep 0.5
sign 0 | $PSQL > "$TMP/b.log" 2>&1 &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?

Q() { docker exec -i "$CONTAINER" psql -U postgres -d meatshop -tAq -c "$1"; }
frozen=$(Q "select coalesce(sum(qty_delta), 0)::text from stock_ledger where stock_state = 'FROZEN'")
transit=$(Q "select coalesce(sum(qty_delta), 0)::text from stock_ledger where stock_state = 'IN_TRANSIT'")
ins=$(Q "select count(*)::text from stock_ledger where movement_type = 'TRANSFER_IN'")
signed=$(Q "select count(*)::text from transport_lines where receipt_idempotency_key is not null")

failures=0
note() { echo "FAIL  $1"; failures=$((failures + 1)); }

if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ]; then
  note "both sessions signed for the same line — the row lock did not hold"
elif [ "$rc_a" -ne 0 ] && [ "$rc_b" -ne 0 ]; then
  note "both sessions failed — the first one should have succeeded"
fi

# The assert the lock owns. Without `for update` both sessions read a null key, both pass,
# and the loser reports nothing at all because nothing refused it.
if ! grep -qs LINE_ALREADY_RECEIVED "$TMP/a.log" "$TMP/b.log"; then
  note "neither session reported LINE_ALREADY_RECEIVED; the loser was not refused by name"
  sed 's/^/      /' "$TMP/a.log" "$TMP/b.log" | tail -10
fi

# ADR-003: the ledger is append-only, so a second TRANSFER_IN pair is damage that cannot be
# taken back. These three are the data the lock protects.
[ "$ins" = "2" ]        || note "expected 2 TRANSFER_IN rows (one off the truck, one onto the shelf), found $ins"
[ "$frozen" = "40.00" ] || note "FROZEN stock is $frozen, expected 40.00 — the load was received twice"
[ "$transit" = "0.00" ] || note "IN_TRANSIT is $transit, expected 0.00"
[ "$signed" = "1" ]     || note "$signed line(s) carry a receipt key, expected exactly 1"

if [ "$failures" -eq 0 ]; then
  echo "PASS  transport_concurrency_test.sh  (FROZEN $frozen after two concurrent 40.00 kg receipts)"
else
  echo "$failures failing"
fi
exit "$failures"
