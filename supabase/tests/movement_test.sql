-- Card ^ref-34 — fn_set_return_pickup_date, with what it stands on: fn_grant_central_receiver
-- (the delegation's only writer, PLAN-movement.md Finding 2), fn_require_central_receiver (its
-- preamble, Finding 4) and v_lot_return_pending (OW 05's read path, Finding 7). Covers TC-04 ...
-- TC-22 of TDD-movement.md; TC-03 is sweep 1f of rls_deny_all_test.sql. ^ref-35 and ^ref-36
-- append to this file.
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
  insert into suppliers (name) values ('ฟู้ดดีว่า') returning id into v_sup;

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

  raise exception 'MOVEMENT_TEST_PASSED';
end $$;
