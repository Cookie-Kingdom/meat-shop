#!/usr/bin/env bash
# TC-34 and TC-35 from TDD-thaw.md — fn_record_thaw between two transactions.
#
#   bash supabase/tests/thaw_concurrency_test.sh
#
# A separate runner for ledger_concurrency_test.sh's reason: both bugs exist only between two
# sessions, and thaw_test.sql is one.
#
# TC-34 — THE SAME KEY, TWO SESSIONS (Seam 1). A branch phone submits, loses the response on a
# weak signal and submits again while the first request is still in flight. Both calls miss the
# replay lookup, because neither has committed. The guard is ...0019's unique index on
# thaw_records.idempotency_key, hit by the record insert BEFORE any ledger row: session B blocks
# on A's uncommitted index entry, wakes to a conflict when A commits, and answers with A's record.
# Without the index (mutation, designed, not run), both insert a record, B's THAW_OUT hits the
# ledger's own key and posts nothing, and the table holds two thaws for one movement.
# Asserted: one record, two ledger rows, and both sessions print the same thaw_record_id.
#
# TC-35 — TWO KEYS RACE THE LAST 3.00 KG (R3). Two genuine thaws, two keys, one freezer with 3.00
# left. Nothing at the key layer can see them. fn_post_ledger's advisory lock on the FROZEN tuple
# queues B behind A; B then sums a zero balance and is refused, and fn_record_thaw re-raises it
# as INSUFFICIENT_FROZEN_STOCK. The balance is deliberately not pre-checked in fn_record_thaw — a
# read outside the lock is the race — so this runner is what proves the lock is the check.
# Asserted: FROZEN reads 0.00, not -3.00, and the loser's record rolled back with it.
#
# Both races are made deterministic rather than raced for: session A thaws and then sits in
# pg_sleep holding its locks; session B arrives half a second in, well inside the window, after
# its own reads have already seen stock.
#
# Contract assumed from an unmerged lane: lane C's fn_guard_report_closed on thaw_records passes an
# OPEN report (...0018). The container is removed on exit, pass or fail.

set -uo pipefail
cd "$(dirname "$0")/../.."

CONTAINER=meatshop-thaw-concurrency-test
PSQL="docker exec -i $CONTAINER psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1"
OWNER=77777777-7777-7777-7777-7777777777d1
L2=77777777-7777-7777-7777-7777777777d2
K34=77777777-7777-7777-7777-7777777777e1
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

# Fixtures, committed: both sessions must see the same freezer. 4.00 kg of one lot lands FROZEN at
# the branch through the production path (central -> allocation -> receipt); central stock is
# posted directly, as movement_concurrency_test.sh does. The branch's day is open.
$PSQL <<SQL >/dev/null 2>&1 || { echo "FAIL  fixtures"; exit 1; }
insert into auth.users (id) values ('$OWNER'), ('$L2');
insert into profiles (id, display_name, role, is_active) values
  ('$OWNER', 'เจ้าของทดสอบพร้อมกัน', 'L1_OWNER', true),
  ('$L2',    'แอดมินสาขาทดสอบพร้อมกัน', 'L2_BRANCH_ADMIN', true);
insert into locations (code, name_th, kind) values ('CH9', 'โรงรมทดสอบ', 'CHEF_HOUSE');
insert into locations (code, name_th, kind) values ('CEN', 'คลังกลางทดสอบ', 'CENTRAL');
insert into locations (code, name_th, kind) values ('BRA', 'สาขาทดสอบ', 'BRANCH');
insert into user_locations (profile_id, location_id)
     values ('$L2', (select id from locations where kind = 'BRANCH'));
insert into suppliers (name) values ('ฟู้ดดีว่าทดสอบ');
select set_config('request.jwt.claims', '{"sub":"$OWNER"}', false);
select fn_set_config(gen_random_uuid(), 'freight_alloc_method', current_date - 30, p_value_text => 'BY_LOT_WEIGHT');
select fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', current_date - 30, p_value_numeric => 20.00);
select fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', current_date - 30, p_value_text => 'true');
select fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', current_date - 30, p_value_text => 'true');
select fn_create_po(gen_random_uuid(), (select id from suppliers), current_date - 5, 100.00, 250.00);
select fn_add_po_delivery(gen_random_uuid(), (select id from purchase_orders), current_date - 5,
                          40.00, (select id from locations where kind = 'CHEF_HOUSE'));
insert into smoke_date_groups (lot_id, smoke_date) values ((select id from lots), current_date - 3);
update lots set state = 'CENTRAL_STOCK';
select fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', (select id from locations where kind = 'CENTRAL'),
                      'FROZEN', 'TRANSFER_IN', 4.00, current_date - 2,
                      p_lot_id => (select id from lots),
                      p_smoke_date_group_id => (select id from smoke_date_groups));
select fn_allocate_to_branch(gen_random_uuid(), (select id from locations where kind = 'BRANCH'),
                             current_date - 1, (select id from smoke_date_groups), 4.00, 2);
select set_config('request.jwt.claims', '{"sub":"$L2"}', false);
select fn_confirm_transport_receipt(gen_random_uuid(), (select id from transport_lines), current_date,
                                    4.00, p_received_bag_count => 2);
select fn_open_daily_report(gen_random_uuid(), (select id from locations where kind = 'BRANCH'), current_date);
SQL

# One thaw by the branch admin. \$1 is the key as an SQL expression (a quoted literal, or
# gen_random_uuid() so Postgres mints it and the host needs no uuid tool), \$2 kg, \$3 how long to
# hold the transaction open after. The id is printed with a tag so two answers can be compared.
thaw() {
  cat <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$L2"}', true);
select 'THAW_ID=' || (fn_record_thaw(
  p_idempotency_key     => $1,
  p_daily_report_id     => (select id from daily_reports),
  p_lot_id              => (select id from lots),
  p_smoke_date_group_id => (select id from smoke_date_groups),
  p_thawed_weight_kg    => $2) ->> 'thaw_record_id');
select pg_sleep($3);
commit;
SQL
}

Q() { docker exec -i "$CONTAINER" psql -U postgres -d meatshop -tAq -c "$1"; }
failures=0
note() { echo "FAIL  $1"; failures=$((failures + 1)); }

# ------------------------------------------------------------------------------------ TC-34
thaw "'$K34'" 1.00 2 | $PSQL > "$TMP/a34.log" 2>&1 &
pid_a=$!
sleep 0.5
thaw "'$K34'" 1.00 0 | $PSQL > "$TMP/b34.log" 2>&1 &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?

id_a=$(grep -o 'THAW_ID=[0-9a-f-]*' "$TMP/a34.log" | head -1)
id_b=$(grep -o 'THAW_ID=[0-9a-f-]*' "$TMP/b34.log" | head -1)
thaws=$(Q "select count(*)::text from thaw_records")
rows=$(Q "select count(*)::text from stock_ledger where source_table = 'thaw_records'")

if [ "$rc_a" -ne 0 ] || [ "$rc_b" -ne 0 ]; then
  note "TC-34: a same-key session failed (A rc=$rc_a, B rc=$rc_b) — a retry must return, not raise (R4)"
  sed 's/^/      /' "$TMP/a34.log" "$TMP/b34.log" | tail -10
fi
[ -n "$id_a" ] && [ "$id_a" = "$id_b" ] || note "TC-34: the sessions answered [$id_a] and [$id_b], expected one id"
[ "$thaws" = "1" ] || note "TC-34: $thaws thaw record(s) for one key, expected 1"
[ "$rows" = "2" ]  || note "TC-34: $rows ledger row(s) for one thaw, expected 2 (THAW_OUT and THAW_IN)"

# ------------------------------------------------------------------------------------ TC-35
# 3.00 kg left. Two keys, 3.00 each.
thaw "gen_random_uuid()" 3.00 2 | $PSQL > "$TMP/a35.log" 2>&1 &
pid_a=$!
sleep 0.5
thaw "gen_random_uuid()" 3.00 0 | $PSQL > "$TMP/b35.log" 2>&1 &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?

frozen=$(Q "select coalesce(sum(qty_delta), 0)::text from stock_ledger where stock_state = 'FROZEN' and location_id = (select id from locations where kind = 'BRANCH')")
ready=$(Q "select coalesce(sum(qty_delta), 0)::text from stock_ledger where stock_state = 'READY'")
thaws=$(Q "select count(*)::text from thaw_records")

if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ]; then
  note "TC-35: both 3.00 kg thaws of a 3.00 kg freezer committed — the tuple lock did not hold"
elif [ "$rc_a" -ne 0 ] && [ "$rc_b" -ne 0 ]; then
  note "TC-35: both thaws failed — the first one should have succeeded"
  sed 's/^/      /' "$TMP/a35.log" "$TMP/b35.log" | tail -10
fi
if ! grep -qs INSUFFICIENT_FROZEN_STOCK "$TMP/a35.log" "$TMP/b35.log"; then
  note "TC-35: the loser was not refused as INSUFFICIENT_FROZEN_STOCK"
  sed 's/^/      /' "$TMP/a35.log" "$TMP/b35.log" | tail -10
fi
[ "$frozen" = "0.00" ] || note "TC-35: the branch freezer reads $frozen, expected 0.00 (R3)"
[ "$ready" = "4.00" ]  || note "TC-35: READY reads $ready, expected 4.00"
[ "$thaws" = "2" ]     || note "TC-35: $thaws thaw record(s), expected 2 — the loser's record must roll back with it"

if [ "$failures" -eq 0 ]; then
  echo "PASS  thaw_concurrency_test.sh  (one record for a doubled key; FROZEN $frozen after racing the last 3.00)"
else
  echo "$failures failing"
fi
exit "$failures"
