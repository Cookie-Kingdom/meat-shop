-- Card ^ref-34 — fn_set_return_pickup_date, with what it stands on: fn_grant_central_receiver
-- (the delegation's only writer, PLAN-movement.md Finding 2), fn_require_central_receiver (its
-- preamble, Finding 4) and v_lot_return_pending (OW 05's read path, Finding 7). Covers TC-04 ...
-- TC-22 of TDD-movement.md; TC-03 is sweep 1f of rls_deny_all_test.sql. ^ref-35 appended
-- TC-23, TC-25, TC-26 and TC-43 ... TC-45 at the foot, and ^ref-36 TC-27 ... TC-38 (bar TC-35,
-- which is movement_concurrency_test.sh), TC-46 and TC-47 below those — TC-01/TC-02 are
-- movement_schema_test.sql's, and TC-24 is transport_concurrency_test.sh's race, which runs the
-- same function and the same row lock into a CENTRAL destination. ^ref-36 appends next.
-- ^ref-37 (lane A, branch fix/dispatch-branch-leg-guard) appended TC-48 ... TC-50 at the foot:
-- fn_dispatch_transport_line refuses a branch leg that does not leave central (BR11,
-- PLAN-movement.md Finding 11). It assumes no contract from an unmerged lane.
--
-- ONE do $$ BLOCK, for production_test.sql's reason: the harness pipes each file into psql
-- without --single-transaction, and the closing raise can only roll back the block it is in.
--
-- THE LOTS ARE CLOSED BY fn_close_lot, never by setting LOT_CLOSED (Seam 3): TC-18 dispatches
-- a smoke-date group, and only the close puts weight on one. The legs before the chef house
-- are not under test, so IN_TRANSIT and lot A's 98.00 kg raw balance are set directly, as
-- lot_close_test.sql does.
--
-- Everything runs in a transaction that aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/movement_test.sql

do $$
declare
  v_owner   uuid := gen_random_uuid();
  v_off     uuid := gen_random_uuid();   -- a deactivated Owner holding a live token
  v_l3      uuid := gen_random_uuid();
  v_l2a     uuid := gen_random_uuid();   -- Branch A, delegated at TC-06
  v_l2b     uuid := gen_random_uuid();   -- Branch B, never delegated
  v_day     date := date '2026-05-04';
  v_chef    uuid;
  v_central uuid;
  v_bra     uuid;
  v_brb     uuid;
  v_sup     uuid;
  v_po      uuid;
  v_lotA    uuid;   -- closed, scheduled at TC-12, dispatched at TC-18
  v_lotB    uuid;   -- closed, never scheduled
  v_lotC    uuid;   -- still at the smoker
  v_open    uuid;   -- an opening lot: LOT_CLOSED from birth, with no close behind it
  v_gA      uuid;
  v_gB      uuid;
  v_line    uuid;   -- lot A's return leg, TC-18's dispatch
  v_runB    uuid;
  v_lineB   uuid;   -- lot B's return leg, received short at TC-26
  v_cbr     uuid;
  v_cline   uuid;   -- a branch leg out of central, TC-25 and TC-43
  v_ul      uuid;
  v_run     uuid;
  v_key     uuid := gen_random_uuid();
  v_locs    uuid[];
  v_closed  date;
  v_date    date;
  v_id      uuid;
  v_ok      boolean;
  v_err     text;
  v_txt     text;
  v_n       bigint;
  v_n2      bigint;
  v_kg      numeric;
  v_kg2     numeric;
  v_kg3     numeric;
  v_lotL    uuid;   -- ^ref-36: put straight into central, with later smoke dates than A and B
  v_gL      uuid;   -- lot L on v_day + 1, FROZEN at central
  v_gT      uuid;   -- lot L on v_day + 2, still IN_TRANSIT to central
  v_g1      uuid;   -- the first v_day group v_central_available offers
  v_g2      uuid;   -- the second: a first-ROW FIFO would refuse it, a first-DATE FIFO does not
  v_a1      numeric;
  v_a2      numeric;
  v_aline   uuid;   -- v_g2 to branch A, a FIFO pick
  v_lline   uuid;   -- lot L to branch A, an override with a reason
  v_bline   uuid;   -- the whole of v_g1 to branch B
  v_akey    uuid := gen_random_uuid();
  v_bags    integer;
  v_codes   text[];
  v_ids     uuid[];
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_off), (v_l3), (v_l2a), (v_l2b);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',               'L1_OWNER',        true),
    (v_off,   'เจ้าของที่ปิดบัญชีแล้ว',     'L1_OWNER',        false),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',     'L3_CM_OPERATOR',  true),
    (v_l2a,   'แอดมินสาขาเอ',           'L2_BRANCH_ADMIN', true),
    (v_l2b,   'แอดมินสาขาบี',           'L2_BRANCH_ADMIN', true);

  insert into locations (code, name_th, kind) values ('CH34', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('CEN34', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  insert into locations (code, name_th, kind) values ('BRA34', 'สาขาเอ', 'BRANCH')
    returning id into v_bra;
  insert into locations (code, name_th, kind) values ('BRB34', 'สาขาบี', 'BRANCH')
    returning id into v_brb;
  insert into user_locations (profile_id, location_id) values
    (v_l3, v_chef), (v_l2a, v_bra), (v_l2b, v_brb);
  insert into suppliers (name) values ('Foodiva') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'yield_alert_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', date '2026-01-01',
                        p_value_text => 'BY_LOT_WEIGHT');

  v_po   := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);
  v_lotA := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotB := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotC := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  update lots set state = 'IN_TRANSIT', assigned_operator_id = v_l3
   where id in (v_lotA, v_lotB, v_lotC);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 'FROZEN', 'TRANSFER_IN',
                         98.00, v_day, p_lot_id => v_lotA);

  -- The operator receives and logs all three, bags and closes A and B. C never closes.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotA, v_day, 98.00, 96.50);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotB, v_day, 98.00, 96.50);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotC, v_day, 98.00, 96.50);
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotA, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotA, 'input_weight_kg', 96.50)));
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotB, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotB, 'input_weight_kg', 96.50)));
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotC, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotC, 'input_weight_kg', 96.50)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotA, v_day,
                             array(select 0.50::numeric from generate_series(1, 80)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotB, v_day,
                             array(select 0.50::numeric from generate_series(1, 80)));
  perform fn_close_lot(gen_random_uuid(), v_lotA);
  perform fn_close_lot(gen_random_uuid(), v_lotB);

  select id into v_gA from smoke_date_groups where lot_id = v_lotA;
  select closed_at::date into v_closed from lots where id = v_lotA;

  -- ^ref-62's shape, inserted directly: the opening path is not under test here.
  insert into lots (lot_code, is_opening, state, event_date)
    values ('OPEN-34', true, 'LOT_CLOSED', v_day) returning id into v_open;

  -- One balance at each branch, so "only their own branch" has something to exclude (TC-07).
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_bra, 'FROZEN', 'TRANSFER_IN',
                         5.00, v_day, p_lot_id => v_lotC);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_brb, 'FROZEN', 'TRANSFER_IN',
                         5.00, v_day, p_lot_id => v_lotC);

  --------------------------------------------------------------------------------- TC-04
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_grant_central_receiver(gen_random_uuid(), v_l2a, v_bra, true);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('TC-04: an L2 granting the delegation got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-05
  -- The flag is a property of an existing assignment; A's admin has none at central.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_grant_central_receiver(gen_random_uuid(), v_l2a, v_central, true);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'USER_LOCATION_NOT_FOUND:%';
  end;
  assert v_ok, format('TC-05: a grant with no assignment behind it got %s', coalesce(v_err, 'no exception at all'));
  select count(*) into v_n from user_locations where profile_id = v_l2a;
  assert v_n = 1, format('TC-05: the refused grant left %s assignment(s) for the profile, expected 1', v_n);

  -- TC-07's "before": what A's admin may read, captured while undelegated.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_locs := fn_current_locations();

  --------------------------------------------------------------------------------- TC-06
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select id into v_ul from user_locations where profile_id = v_l2a and location_id = v_bra;
  v_id := fn_grant_central_receiver(gen_random_uuid(), v_l2a, v_bra, true);
  assert v_id = v_ul, format('TC-06: the grant returned %s, not the assignment %s', v_id, v_ul);
  select count(*) into v_n from user_locations where id = v_ul and can_receive_central;
  assert v_n = 1, 'TC-06: the grant did not set can_receive_central';

  select count(*) into v_n from audit_log where table_name = 'user_locations' and row_id = v_ul;
  v_id := fn_grant_central_receiver(gen_random_uuid(), v_l2a, v_bra, true);
  select count(*) into v_n2 from audit_log where table_name = 'user_locations' and row_id = v_ul;
  assert v_id = v_ul and v_n2 = v_n,
    format('TC-06: the repeat returned %s and wrote %s audit row(s); expected %s and none (R38)',
           v_id, v_n2 - v_n, v_ul);

  --------------------------------------------------------------------------------- TC-07
  -- The delegation grants the act, not the data (Seam 1).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  assert fn_current_locations() = v_locs,
    format('TC-07: the delegation moved fn_current_locations() from %s to %s', v_locs, fn_current_locations());
  select count(*) filter (where location_id = v_bra), count(*) filter (where location_id <> v_bra)
    into v_n, v_n2 from v_stock_balance;
  assert v_n = 1 and v_n2 = 0,
    format('TC-07: the delegate reads %s balance row(s) at their branch and %s elsewhere', v_n, v_n2);

  --------------------------------------------------------------------------------- TC-08
  perform set_config('request.jwt.claims', json_build_object('sub', v_off)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_require_central_receiver();
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NO_ACTOR:%';
  end;
  assert v_ok, format('TC-08: a deactivated Owner got %s — the actor is asked first (R31)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-09
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_require_central_receiver();
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('TC-09: an undelegated L2 got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-10
  -- The flag sits on A's Branch A row, and it still admits a central act (Seam 1).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_id := fn_require_central_receiver();
  assert v_id = v_l2a, format('TC-10: the delegate resolved to %s', v_id);

  --------------------------------------------------------------------------------- TC-11
  foreach v_id in array array[v_l2b, v_l3] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
    v_ok := false; v_err := null;
    begin
      perform fn_set_return_pickup_date(gen_random_uuid(), v_lotA, v_closed);
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
    end;
    assert v_ok, format('TC-11: %s setting a pickup date got %s',
                        (select role from profiles where id = v_id), coalesce(v_err, 'no exception at all'));
  end loop;

  --------------------------------------------------------------------------------- TC-15
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select state::text into v_txt from lots where id = v_lotC;
  v_ok := false; v_err := null;
  begin
    perform fn_set_return_pickup_date(gen_random_uuid(), v_lotC, v_closed);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_NOT_CLOSED:%' || v_txt || '%';
  end;
  assert v_ok, format('TC-15: a lot at %s got %s', v_txt, coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-16
  v_ok := false; v_err := null;
  begin
    perform fn_set_return_pickup_date(gen_random_uuid(), v_lotA, v_closed - 1);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'RETURN_PICKUP_DATE_INVALID:%';
  end;
  assert v_ok, format('TC-16: a pickup the day before the close got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_set_return_pickup_date(gen_random_uuid(), v_lotA, null);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'RETURN_PICKUP_DATE_REQUIRED:%';
  end;
  assert v_ok, format('TC-16: a null pickup date got %s', coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from lots where id = v_lotA and state = 'LOT_CLOSED' and return_pickup_date is null;
  assert v_n = 1, 'TC-15..16: a refused call moved lot A';

  --------------------------------------------------------------------------------- TC-12
  -- R8's guard and this card, side by side (Finding 8): the lock is on the five production
  -- child tables, not on lots.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotA, v_day + 1,
      jsonb_build_array(jsonb_build_object('lot_id', v_lotA, 'input_weight_kg', 1.00)));
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_CLOSED:%';
  end;
  assert v_ok, format('TC-12: a log against a closed lot got %s', coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from stock_ledger;

  -- The delegate names the date, and it is the close's own day: same-day collection is
  -- ordinary (TC-16's other half).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_id := fn_set_return_pickup_date(v_key, v_lotA, v_closed);
  assert v_id = v_lotA, format('TC-12: the pickup date returned %s', v_id);
  select state::text, return_pickup_date, return_pickup_set_by into v_txt, v_date, v_id
    from lots where id = v_lotA;
  assert v_txt = 'RETURN_SCHEDULED' and v_date = v_closed and v_id = v_l2a,
    format('TC-12: lot A reads %s / %s / set by %s', v_txt, v_date, v_id);

  --------------------------------------------------------------------------------- TC-19
  select count(*) into v_n2 from stock_ledger;
  assert v_n2 = v_n, format('TC-19: a pickup date posted %s ledger row(s)', v_n2 - v_n);

  --------------------------------------------------------------------------------- TC-17
  select count(*) into v_n from audit_log where table_name = 'lots' and row_id = v_lotA;
  v_id := fn_set_return_pickup_date(v_key, v_lotA, v_closed);
  select count(*) into v_n2 from audit_log where table_name = 'lots' and row_id = v_lotA;
  assert v_id = v_lotA and v_n2 = v_n,
    format('TC-17: the retry returned %s and wrote %s audit row(s)', v_id, v_n2 - v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_return_pickup_date(gen_random_uuid(), v_lotA, v_closed + 2);
  select return_pickup_date, return_pickup_set_by into v_date, v_id from lots where id = v_lotA;
  assert v_date = v_closed + 2 and v_id = v_owner,
    format('TC-17: the reschedule left %s set by %s', v_date, v_id);
  select count(*) into v_n from audit_log
   where table_name = 'lots' and row_id = v_lotA
     and before ->> 'return_pickup_date' = v_closed::text
     and after  ->> 'return_pickup_date' = (v_closed + 2)::text;
  assert v_n = 1, format('TC-17: %s audit row(s) carry both dates of the reschedule (R32)', v_n);

  ------------------------------------------------------------------------ TC-20, TC-21
  select count(*) into v_n from v_lot_return_pending where lot_id in (v_lotA, v_lotB);
  assert v_n = 2, format('TC-20: the queue holds %s of the two closed lots', v_n);
  select count(*) into v_n from v_lot_return_pending where lot_id in (v_lotC, v_open);
  assert v_n = 0, format('TC-20: %s lot(s) still smoking or opening are in the return queue', v_n);
  select count(*) into v_n from v_lot_return_pending
   where lot_id in (v_lotA, v_lotB) and days_since_close is not null;
  assert v_n = 2, 'TC-20: days_since_close is null on a closed lot';
  select return_pickup_date into v_date from v_lot_return_pending where lot_id = v_lotB;
  assert v_date is null, format('TC-20: lot B, never scheduled, shows %s', v_date);
  select packed_weight_kg, group_count into v_kg, v_n from v_lot_return_pending where lot_id = v_lotA;
  assert v_kg = 40.00 and v_n = 1, format('TC-20: lot A reads %s kg in %s group(s)', v_kg, v_n);

  select string_agg(column_name, ', ') into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'v_lot_return_pending'
     and (column_name like '%cost%' or column_name like '%price%' or column_name like '%thb%'
       or column_name like '%yield%' or column_name like '%loss%' or column_name like '%foodiva%');
  assert v_txt is null, format('TC-21: v_lot_return_pending carries %s (R20)', v_txt);

  --------------------------------------------------------------------------------- TC-22
  foreach v_id in array array[v_owner, v_l2a, v_l2b, v_l3, v_off] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
    select count(*) into v_n from v_lot_return_pending;
    assert v_n = case when v_id in (v_owner, v_l2a) then 2 else 0 end,
      format('TC-22: %s (active %s) reads %s row(s)',
             (select role from profiles where id = v_id),
             (select is_active from profiles where id = v_id), v_n);
  end loop;

  ------------------------------------------------------------------------ TC-14, TC-13
  -- ^ref-22's own guard is the assertion (Seam 3): it stays shut for B and opens for A.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select lot_code into v_txt from lots where id = v_lotB;
  v_ok := false; v_err := null;
  begin
    perform fn_create_transport_run(gen_random_uuid(), 'CM_TO_FOODIVA', v_day + 5,
                                    p_run_cost_thb => 1500.00, p_lot_ids => array[v_lotA, v_lotB]);
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'RETURN_NOT_SCHEDULED:%' || v_txt || '%'
        and v_err not like '%' || (select lot_code from lots where id = v_lotA) || '%';
  end;
  assert v_ok, format('TC-14: a run with unscheduled lot %s got %s', v_txt, coalesce(v_err, 'no exception at all'));

  v_run := fn_create_transport_run(gen_random_uuid(), 'CM_TO_FOODIVA', v_day + 5,
                                   p_run_cost_thb => 1500.00, p_lot_ids => array[v_lotA]);
  assert v_run is not null, 'TC-13: the return run for a scheduled lot was not created';

  --------------------------------------------------------------------------------- TC-18
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotA, v_gA, v_chef,
                                     v_central, 40.00);

  -- The date that stands, again, is still a retry — the truck changes nothing about that.
  v_id := fn_set_return_pickup_date(gen_random_uuid(), v_lotA, v_closed + 2);
  assert v_id = v_lotA, format('TC-18: a retry after dispatch returned %s', v_id);

  v_ok := false; v_err := null;
  begin
    perform fn_set_return_pickup_date(gen_random_uuid(), v_lotA, v_closed + 3);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'RETURN_ALREADY_DISPATCHED:%';
  end;
  assert v_ok, format('TC-18: a reschedule after the truck got %s', coalesce(v_err, 'no exception at all'));
  select return_pickup_date into v_date from lots where id = v_lotA;
  assert v_date = v_closed + 2, format('TC-18: the refused reschedule left %s', v_date);

  ------------------------------------------------------------ ^ref-35: central intake
  -- Lot B gets a truck of its own: scheduled, booked and dispatched like lot A.
  -- partial_receipt_allowed is TC-26's — a 25% short intake has to be recordable before its
  -- reason can be demanded.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_return_pickup_date(gen_random_uuid(), v_lotB, v_closed);
  select id into v_gB from smoke_date_groups where lot_id = v_lotB;
  v_runB  := fn_create_transport_run(gen_random_uuid(), 'CM_TO_FOODIVA', v_day + 5,
                                     p_run_cost_thb => 1500.00, p_lot_ids => array[v_lotB]);
  v_lineB := fn_dispatch_transport_line(gen_random_uuid(), v_runB, v_lotB, v_gB, v_chef,
                                        v_central, 40.00);
  select id into v_line from transport_lines where run_id = v_run;

  ------------------------------------------------------------------------ TC-23, TC-44
  -- The amendment opened central to the delegate, not to every L2: B's admin, undelegated, and
  -- the operator are still refused.
  foreach v_id in array array[v_l2b, v_l3] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
    v_ok := false; v_err := null;
    begin
      perform fn_confirm_transport_receipt(gen_random_uuid(), v_line, v_day + 6, 40.00);
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
    end;
    assert v_ok, format('TC-23: %s signing for central got %s',
                        (select role from profiles where id = v_id), coalesce(v_err, 'no exception at all'));
  end loop;

  -- The delegate signs through the BASE function, bypassing the wrapper, and the lot advances
  -- all the same (Seam 2). 80 bags counted against a line that carries no count asks for no
  -- reason (TC-44): null is "not counted", and a coalesce(bag_count, 0) reads 80 against zero.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_id := fn_confirm_transport_receipt(gen_random_uuid(), v_line, v_day + 6, 40.00,
                                       p_received_bag_count => 80);
  assert v_id = v_line, format('TC-23: the receipt returned %s', v_id);
  select state::text into v_txt from lots where id = v_lotA;
  assert v_txt = 'CENTRAL_STOCK', format('TC-23: lot A reads %s after its return leg landed', v_txt);
  select received_by, received_bag_count into v_id, v_n from transport_lines where id = v_line;
  assert v_id = v_l2a and v_n = 80,
    format('TC-23/TC-44: the line was received by %s with %s bag(s)', v_id, v_n);
  select coalesce(sum(qty_delta), 0) into v_kg from stock_ledger
   where lot_id = v_lotA and location_id = v_central and stock_state = 'FROZEN';
  assert v_kg = 40.00, format('TC-23: central holds %s kg of lot A, expected 40.00', v_kg);

  --------------------------------------------------------------------------------- TC-26
  -- Through the wrapper, 30 of 40 with no reason: 25% past a 20% tolerance, refused by the base
  -- function's own rule, and nothing written.
  v_ok := false; v_err := null;
  begin
    perform fn_confirm_central_intake(gen_random_uuid(), v_lineB, v_day + 6, 30.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'VARIANCE_REASON_REQUIRED:%kg%';
  end;
  assert v_ok, format('TC-26: a 25%% short intake with no reason got %s', coalesce(v_err, 'no exception at all'));
  select count(*) into v_n from transport_lines where id = v_lineB and receipt_idempotency_key is null;
  select state::text into v_txt from lots where id = v_lotB;
  assert v_n = 1 and v_txt = 'RETURN_SCHEDULED',
    format('TC-26: the refused intake left %s unsigned line(s) and lot B at %s', v_n, v_txt);

  -- ALERT, not BLOCK: with a reason the same 30 kg is accepted, and 10 stays on the truck.
  v_id := fn_confirm_central_intake(gen_random_uuid(), v_lineB, v_day + 6, 30.00,
                                    'ถุงแตกระหว่างทาง');
  assert v_id = v_lineB, format('TC-26: the intake returned %s', v_id);
  select state::text into v_txt from lots where id = v_lotB;
  assert v_txt = 'CENTRAL_STOCK', format('TC-26: lot B reads %s after a partial intake', v_txt);
  select coalesce(sum(qty_delta), 0) into v_kg from stock_ledger
   where lot_id = v_lotB and location_id = v_central and stock_state = 'IN_TRANSIT';
  assert v_kg = 10.00, format('TC-26: %s kg of lot B is still on the truck, expected 10.00', v_kg);

  --------------------------------------------------------------------------------- TC-25
  -- A branch leg's id typed into OW 06 fails by name, and nothing is signed. The leg is
  -- dispatched directly and its bag count set directly: fn_allocate_to_branch, the only writer
  -- of both, is ^ref-36's.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_cbr   := fn_create_transport_run(gen_random_uuid(), 'CENTRAL_TO_BRANCH', v_day + 7);
  v_cline := fn_dispatch_transport_line(gen_random_uuid(), v_cbr, v_lotA, v_gA, v_central,
                                        v_bra, 20.00);
  update transport_lines set bag_count = 10 where id = v_cline;

  -- The preamble runs before the line is read: an undelegated caller learns nothing about
  -- which route a line id belongs to.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_confirm_central_intake(gen_random_uuid(), v_cline, v_day + 8, 20.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('TC-25: an undelegated L2 at OW 06 got %s', coalesce(v_err, 'no exception at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_confirm_central_intake(gen_random_uuid(), v_cline, v_day + 8, 20.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_A_CENTRAL_INTAKE:%CENTRAL_TO_BRANCH%';
  end;
  assert v_ok, format('TC-25: a branch leg through OW 06 got %s', coalesce(v_err, 'no exception at all'));

  ------------------------------------------------------------------------ TC-43, TC-45
  -- Ten bags out, nine counted in at 19.50 kg: 2.5% off by weight, inside the 20% tolerance,
  -- and still a reason — the bag is somewhere (Seam 7). A's admin signs at their own branch.
  v_ok := false; v_err := null;
  begin
    perform fn_confirm_transport_receipt(gen_random_uuid(), v_cline, v_day + 8, 19.50,
                                         p_received_bag_count => 0);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'RECEIPT_BAG_COUNT_INVALID:%';
  end;
  assert v_ok, format('TC-43: zero bags counted got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_confirm_transport_receipt(gen_random_uuid(), v_cline, v_day + 8, 19.50,
                                         p_received_bag_count => 9);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'VARIANCE_REASON_REQUIRED:%bag%';
  end;
  assert v_ok, format('TC-43: nine bags against ten with no reason got %s', coalesce(v_err, 'no exception at all'));
  select count(*) into v_n from transport_lines where id = v_cline and receipt_idempotency_key is null;
  assert v_n = 1, 'TC-25/TC-43: a refused call signed the branch leg';

  perform fn_confirm_transport_receipt(gen_random_uuid(), v_cline, v_day + 8, 19.50,
                                       'ถุงหายหนึ่งถุง', p_received_bag_count => 9);
  select bag_count, received_bag_count into v_n, v_n2 from transport_lines where id = v_cline;
  assert v_n = 10 and v_n2 = 9, format('TC-45: the line stores %s bag(s) out and %s in', v_n, v_n2);
  select coalesce(sum(qty_delta), 0) into v_kg from stock_ledger
   where lot_id = v_lotA and location_id = v_bra and stock_state = 'FROZEN';
  assert v_kg = 19.50, format('TC-45: branch A holds %s kg of lot A, expected the 19.50 weighed', v_kg);
  select count(*) into v_n from stock_ledger
   where lot_id = v_lotA and location_id = v_bra and abs(qty_delta) in (9, 10);
  assert v_n = 0, format('TC-45: %s ledger row(s) at the branch carry a bag count as a quantity', v_n);
  select state::text into v_txt from lots where id = v_lotA;
  assert v_txt = 'CENTRAL_STOCK', format('TC-45: a branch receipt moved lot A to %s', v_txt);

  ------------------------------------------------------------ ^ref-36: allocation to branches
  -- Central holds lot A's group (20.00 after TC-25's leg) and lot B's (30.00, with 10 more still
  -- on TC-26's truck), both smoked on v_day. Lot L is put straight into central with a later
  -- smoke date, and a second group of L's is left IN_TRANSIT to central — inserted directly,
  -- because the chain that makes central stock is TC-23's and TC-26's and is not tested twice.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_lotL := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotL, v_day + 1) returning id into v_gL;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotL, v_day + 2) returning id into v_gT;
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_central, 'FROZEN', 'TRANSFER_IN',
                         10.00, v_day + 6, p_lot_id => v_lotL, p_smoke_date_group_id => v_gL);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_central, 'IN_TRANSIT', 'TRANSFER_OUT',
                         10.00, v_day + 6, p_lot_id => v_lotL, p_smoke_date_group_id => v_gT);

  --------------------------------------------------------------------------------- TC-27
  -- Two lots on one smoke date are two rows, the older date first, lot codes inside it (ADR-017).
  select array_agg(smoke_date_group_id), array_agg(lot_code) into v_ids, v_codes
    from v_central_available;
  assert cardinality(v_ids) = 3 and v_ids[3] = v_gL and v_ids[1:2] @> array[v_gA, v_gB],
    format('TC-27: central offers %s, expected lot A''s and B''s groups, then lot L''s', v_ids);
  assert v_codes[1] < v_codes[2], format('TC-27: inside one smoke date the order is %s', v_codes);
  v_g1 := v_ids[1];
  v_g2 := v_ids[2];
  select available_qty into v_a1 from v_central_available where smoke_date_group_id = v_g1;
  select available_qty into v_a2 from v_central_available where smoke_date_group_id = v_g2;

  --------------------------------------------------------------------------------- TC-28
  -- What has not landed and what is not central is not offered: lot B's 10 kg on the truck, lot
  -- L's IN_TRANSIT group, lot A's 19.50 at branch A.
  select available_qty into v_kg from v_central_available where smoke_date_group_id = v_gB;
  select count(*) into v_n from v_central_available
   where smoke_date_group_id = v_gT or location_id <> v_central;
  assert v_kg = 30.00 and v_n = 0,
    format('TC-28: lot B offers %s kg, and %s row(s) are not landed central stock', v_kg, v_n);

  -- Nobody but the Owner reads it — the central-intake delegate included (Seam 1).
  foreach v_id in array array[v_l2a, v_l2b, v_l3] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
    select count(*) into v_n from v_central_available;
    assert v_n = 0, format('TC-28: %s reads %s central row(s)',
                           (select display_name from profiles where id = v_id), v_n);
  end loop;

  ------------------------------------------------------------------------------ T9 step 2
  -- Allocation is L1's. The delegation signs for central; it does not send central stock out.
  foreach v_id in array array[v_l2a, v_l3] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
    v_ok := false; v_err := null;
    begin
      perform fn_allocate_to_branch(gen_random_uuid(), v_bra, v_day + 9, v_g1, 5.00, 5);
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
    end;
    assert v_ok, format('T9: %s allocating got %s',
                        (select role from profiles where id = v_id), coalesce(v_err, 'no exception at all'));
  end loop;

  ------------------------------------------------------------------- TC-46, TC-29, TC-32
  -- Every refusal from here to TC-30's writes nothing: no line, no ledger row.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from transport_lines;
  select count(*) into v_n2 from stock_ledger;

  foreach v_bags in array array[null, 0]::integer[] loop
    v_ok := false; v_err := null;
    begin
      perform fn_allocate_to_branch(gen_random_uuid(), v_bra, v_day + 9, v_g1, 5.00, v_bags);
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'BAG_COUNT_REQUIRED:%';
    end;
    assert v_ok, format('TC-46: %s bag(s) got %s', coalesce(v_bags::text, 'null'),
                        coalesce(v_err, 'no exception at all'));
  end loop;

  v_ok := false; v_err := null;
  begin
    perform fn_allocate_to_branch(gen_random_uuid(), v_bra, v_day + 9, v_gT, 5.00, 5);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_IN_CENTRAL_STOCK:%';
  end;
  assert v_ok, format('TC-29: a group still in transit got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_allocate_to_branch(gen_random_uuid(), v_bra, v_day + 9, v_gB, 31.00, 31);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'INSUFFICIENT_CENTRAL_STOCK:%30.00%31.00%';
  end;
  assert v_ok, format('TC-32: 31 kg of a 30 kg group got %s', coalesce(v_err, 'no exception at all'));

  -- A destination that is not a branch, or not a location at all.
  v_ok := false; v_err := null;
  begin
    perform fn_allocate_to_branch(gen_random_uuid(), v_central, v_day + 9, v_g1, 5.00, 5);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_A_BRANCH:%CENTRAL%';
  end;
  assert v_ok, format('T9: allocating to central got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_allocate_to_branch(gen_random_uuid(), gen_random_uuid(), v_day + 9, v_g1, 5.00, 5);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOCATION_NOT_FOUND:%';
  end;
  assert v_ok, format('T9: allocating to nowhere got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-30
  -- Lot L is a later smoke date than central still holds: a reason, naming the oldest date.
  v_ok := false; v_err := null;
  begin
    perform fn_allocate_to_branch(gen_random_uuid(), v_bra, v_day + 9, v_gL, 10.00, 5);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FIFO_OVERRIDE_REASON_REQUIRED:%' || v_day::text || '%';
  end;
  assert v_ok, format('TC-30: skipping %s with no reason got %s', v_day, coalesce(v_err, 'no exception at all'));

  assert (select count(*) from transport_lines) = v_n and (select count(*) from stock_ledger) = v_n2,
    'TC-29/30/32/46: a refused allocation wrote a line or a ledger row';

  -- The SECOND lot of the oldest date is a choice, not an override (v0.2:188), so no reason is
  -- asked. Comparing against the first ROW rather than the first DATE refuses this call.
  v_aline := fn_allocate_to_branch(gen_random_uuid(), v_bra, v_day + 9, v_g2, 10.00, 10);
  -- With a reason, the later date goes.
  v_lline := fn_allocate_to_branch(gen_random_uuid(), v_bra, v_day + 9, v_gL, 10.00, 5,
                                   'สาขาขอของรมใหม่');
  select fifo_override_reason into v_txt from transport_lines where id = v_aline;
  assert v_txt is null, format('TC-30: a FIFO pick stored an override reason %s', v_txt);
  select fifo_override_reason into v_txt from transport_lines where id = v_lline;
  assert v_txt = 'สาขาขอของรมใหม่', format('TC-30: the override stored %s', v_txt);

  ------------------------------------------------------------------- TC-34, TC-33, TC-37, TC-47
  -- One run per branch per day, and it is free as an absence: a zero fare and null shares, never
  -- 0.00 shares (Seam 6).
  select run_id into v_run from transport_lines where id = v_aline;
  select count(*) into v_n from transport_lines where run_id = v_run;
  assert v_n = 2 and (select run_id from transport_lines where id = v_lline) = v_run,
    format('TC-34: two allocations to branch A on one day left %s line(s) on the first one''s run', v_n);
  select count(*) into v_n from transport_runs
   where route = 'CENTRAL_TO_BRANCH' and event_date = v_day + 9;
  assert v_n = 1, format('TC-34: branch A''s day has %s run(s)', v_n);

  select count(*) into v_n from transport_runs where id = v_run and run_cost_thb = 0;
  select count(*) into v_n2 from transport_lines where run_id = v_run and freight_share_thb is null;
  assert v_n = 1 and v_n2 = 2, format('TC-33: fare-free run %s, lines with no share %s', v_n, v_n2);

  -- The tuple: off central FROZEN, onto the truck AT the branch (R43), naming the group.
  select string_agg(format('%s/%s/%s',
                           case location_id when v_central then 'central' when v_bra then 'A' else 'elsewhere' end,
                           stock_state, qty_delta), ',' order by qty_delta)
    into v_txt
    from stock_ledger
   where source_table = 'transport_lines' and source_id = v_aline and smoke_date_group_id = v_g2;
  assert v_txt = 'central/FROZEN/-10.00,A/IN_TRANSIT/10.00', format('TC-37: the allocation posted %s', v_txt);
  select count(*) into v_n from stock_ledger where source_table = 'transport_lines' and source_id = v_aline;
  assert v_n = 2, format('TC-37: the allocation posted %s ledger row(s)', v_n);

  -- The count is the number loaded, not the number packed.
  select bag_count into v_n from transport_lines where id = v_aline;
  select count(*) into v_n2 from lot_bags where smoke_date_group_id = v_g2;
  assert v_n = 10 and v_n2 = 80, format('TC-47: the line carries %s bag(s) of a %s-bag group', v_n, v_n2);

  --------------------------------------------------------------------------------- TC-33a
  -- Part of a lot allocated: the lot does not move, and central still offers the rest (ADR-026).
  select state::text into v_txt from lots where id = (select lot_id from smoke_date_groups where id = v_g2);
  select available_qty into v_kg from v_central_available where smoke_date_group_id = v_g2;
  assert v_txt = 'CENTRAL_STOCK' and v_kg = v_a2 - 10.00,
    format('TC-33a: the lot reads %s and central offers %s of its %s kg', v_txt, v_kg, v_a2);

  --------------------------------------------------------------------------------- TC-36
  -- The whole of the other v_day group to branch B. A FIFO pick, so the reason sent is dropped.
  v_bline := fn_allocate_to_branch(v_akey, v_brb, v_day + 9, v_g1, v_a1, 8, 'ไม่ต้องใช้เหตุผล');
  -- The group is empty now, and the replay still returns the line, not NOT_IN_CENTRAL_STOCK.
  v_id := fn_allocate_to_branch(v_akey, v_brb, v_day + 9, v_g1, v_a1, 8, 'ไม่ต้องใช้เหตุผล');
  assert v_id = v_bline, format('TC-36: the replay returned %s, not %s', v_id, v_bline);
  select count(*) into v_n from transport_lines where idempotency_key = v_akey;
  select count(*) into v_n2 from stock_ledger where source_table = 'transport_lines' and source_id = v_bline;
  assert v_n = 1 and v_n2 = 2,
    format('TC-36: the replay left %s line(s) and %s ledger row(s), expected 1 and 2', v_n, v_n2);
  select count(*) into v_n from v_central_available where smoke_date_group_id = v_g1;
  assert v_n = 0, 'TC-36: an emptied group is still offered';
  select fifo_override_reason, run_id into v_txt, v_id from transport_lines where id = v_bline;
  assert v_txt is null, format('TC-30: a reason on a FIFO pick was stored as %s', v_txt);
  assert v_id <> v_run, 'TC-34: branch B''s allocation rode branch A''s run';

  v_ok := false; v_err := null;
  begin
    perform fn_allocate_to_branch(v_akey, v_brb, v_day + 9, v_g1, v_a1, 7);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LINE_IDEMPOTENCY_CONFLICT:%';
  end;
  assert v_ok, format('TC-36: the key reused for 7 bags got %s', coalesce(v_err, 'no exception at all'));

  -- The Owner's key in an L2's hands is refused, not answered with the line id: the preamble
  -- runs before the retry check.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_allocate_to_branch(v_akey, v_brb, v_day + 9, v_g1, v_a1, 8);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('TC-36: an L2 replaying the Owner''s key got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-31
  -- Branch A signs for lot L with no variance reason; the sender's FIFO reason stays (Seam 4).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_lline, v_day + 10, 10.00);
  select fifo_override_reason, variance_reason into v_txt, v_err from transport_lines where id = v_lline;
  assert v_txt = 'สาขาขอของรมใหม่' and v_err is null,
    format('TC-31: after the receipt the FIFO reason reads %s and the variance reason %s', v_txt, v_err);

  --------------------------------------------------------------------------------- TC-38
  -- The chain's last two links, read the way the Owner reads them: lot L's 10 kg left central
  -- whole and sits FROZEN at branch A, and nothing of it is on a truck.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select coalesce(sum(balance_qty) filter (where location_id = v_bra and stock_state = 'FROZEN'), 0),
         coalesce(sum(balance_qty) filter (where stock_state = 'IN_TRANSIT'), 0),
         coalesce(sum(balance_qty) filter (where location_id = v_central), 0)
    into v_kg, v_kg2, v_kg3
    from v_stock_balance
   where smoke_date_group_id = v_gL;
  assert v_kg = 10.00 and v_kg2 = 0 and v_kg3 = 0,
    format('TC-38: lot L reads %s at branch A, %s in transit, %s at central', v_kg, v_kg2, v_kg3);

  ------------------------------------------------------------------------- TC-48 ... TC-50
  -- ^ref-37's acceptance line, below the screens (PLAN-movement.md Finding 11): nothing reaches
  -- a branch without passing through central stock first, even through
  -- fn_dispatch_transport_line called directly. First, 5 kg of lot A's group goes back on the
  -- chef-house shelf, FROZEN. Each refused leg below WOULD post without the guard, so the
  -- named raise is the only thing in its way, not an empty balance.
  --
  -- Baselines first. TC-43 received lot A's branch leg short, so this group need not be empty
  -- in transit to branch A. The closing assertion compares against what was there before,
  -- never against zero.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select coalesce(sum(balance_qty) filter (where location_id = v_chef and stock_state = 'FROZEN'), 0),
         coalesce(sum(balance_qty) filter (where location_id = v_bra and stock_state = 'IN_TRANSIT'), 0)
    into v_a1, v_a2
    from v_stock_balance
   where smoke_date_group_id = v_gA;
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 'FROZEN', 'TRANSFER_IN',
                         5.00, v_day + 11, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  v_run := fn_create_transport_run(gen_random_uuid(), 'CENTRAL_TO_BRANCH', v_day + 11,
                                   p_run_cost_thb => 0);

  -- TC-48: a CENTRAL_TO_BRANCH run carrying chef-house stock straight to a branch.
  v_ok := false; v_err := null;
  begin
    perform fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotA, v_gA, v_chef, v_bra, 5.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'BRANCH_LEG_ORIGIN_INVALID:%';
  end;
  assert v_ok, format('TC-48: chef-house stock sent straight to branch A got %s',
                      coalesce(v_err, 'no exception at all'));

  -- TC-49: a branch line hung on the return run, which leaves the chef house by design.
  select id into v_id from transport_runs where route = 'CM_TO_FOODIVA' order by created_at limit 1;
  v_ok := false; v_err := null;
  begin
    perform fn_dispatch_transport_line(gen_random_uuid(), v_id, v_lotA, v_gA, v_chef, v_bra, 5.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'BRANCH_LEG_ROUTE_INVALID:%';
  end;
  assert v_ok, format('TC-49: a branch line on a CM_TO_FOODIVA run got %s',
                      coalesce(v_err, 'no exception at all'));

  -- TC-50: a CENTRAL_TO_BRANCH run used for something that is not a branch leg at all.
  v_ok := false; v_err := null;
  begin
    perform fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotA, v_gA, v_chef, v_central, 5.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_A_BRANCH:%';
  end;
  assert v_ok, format('TC-50: a CENTRAL_TO_BRANCH line into central got %s',
                      coalesce(v_err, 'no exception at all'));

  -- And nothing moved: no line on the branch run, the chef-house shelf up by exactly the 5 kg
  -- put there, and transit to branch A where it was before.
  select count(*) into v_n from transport_lines where run_id = v_run;
  select coalesce(sum(balance_qty) filter (where location_id = v_chef and stock_state = 'FROZEN'), 0),
         coalesce(sum(balance_qty) filter (where location_id = v_bra and stock_state = 'IN_TRANSIT'), 0)
    into v_kg, v_kg2
    from v_stock_balance
   where smoke_date_group_id = v_gA;
  assert v_n = 0 and v_kg = v_a1 + 5.00 and v_kg2 = v_a2,
    format('TC-48..TC-50: %s line(s) on the branch run; chef house %s kg (was %s + 5.00); in transit to branch A %s kg (was %s)',
           v_n, v_kg, v_a1, v_kg2, v_a2);

  raise exception 'MOVEMENT_TEST_PASSED';
end $$;
