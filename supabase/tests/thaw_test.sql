-- Card ^ref-40 — fn_record_thaw and fn_require_branch_or_owner, failure first (TDD-thaw.md TC-06
-- ... TC-33, plus TC-26b and TC-26c). TC-01 ... TC-04 are thaw_schema_test.sql's, TC-05 is
-- sweep 1f of rls_deny_all_test.sql (re-asserted at TC-31), and TC-34/TC-35 need two sessions,
-- so they are thaw_concurrency_test.sh's.
--
-- Contract assumed from an unmerged lane: lane C's ...0018 trg_guard_report_closed on
-- thaw_records raises REPORT_CLOSED, naming the date, when status = 'CLOSED' and no APPROVED
-- DAILY_REPORT unlock_requests row has expires_at > now(). fn_record_thaw has no closed check of
-- its own since the ^ref-08 model (ref-08-unlock/PLAN-unlock.md Finding 1): TC-11 and TC-29c need
-- that trigger to refuse, and TC-12, TC-29 and TC-29b need it to admit UNLOCKED and a live approval.
--
-- THE FIXTURE, one branch pair and six lots (TDD "The fixture is ..."). Dates are relative to
-- current_date, because fn_open_daily_report refuses a future day; the labels are the TDD's.
--   at A, FROZEN      L-A  "1 Sep"  (v_d1)  10.00
--                     L-B  "3 Sep"  (v_d3)  10.00   } one smoke date, two lots (D01)
--                     L-C  "3 Sep"  (v_d3)  10.00   }
--   at A, IN_TRANSIT  L-D  "31 Aug"         5.00    allocated, never received (TC-15, TC-24)
--   at A, READY       L-F  "29 Aug"         5.00    (TC-15, TC-24)
--   at B, FROZEN      L-E  "30 Aug"         5.00    (TC-14, TC-24)
-- Branch stock arrives the production way: central FROZEN -> fn_allocate_to_branch ->
-- fn_confirm_transport_receipt. Two things are hand-written, each because no function makes it:
--   * central stock, posted with fn_post_ledger (the chain that makes it is movement_test.sql's);
--   * L-F's READY 5.00. The only writer of READY is the function under test, and a fixture that
--     calls it before the first failure case would hide the failure case behind a fixture error.
-- The smoke-date groups go in while each lot is PO_CREATED, then the lots move to CENTRAL_STOCK:
-- trg_guard_lot_closed on smoke_date_groups refuses a group for a lot already past LOT_CLOSED.
--
-- MUTATION CHECKS (PLAN T6), DESIGNED, NOT RUN — the 10 Sep parallel build writes tests and runs
-- none. Each names the assert that must go red:
--   * move the replay (step 5) after the insert           -> TC-27
--   * put back a function-side `status = 'CLOSED'` raise  -> TC-29b
--   * apply the back-dating window to a CLOSED day        -> TC-29b
--   * compare step 10 on (smoke_date, lot_code)           -> TC-21
--   * drop thaw_records_idempotency_key                   -> TC-34 (thaw_concurrency_test.sh)
--   * point step 9 at v_smoke_group_available             -> TC-15
--   * drop step 15's second preamble call                 -> TC-26b
--
-- ONE do $$ BLOCK: the harness pipes each file into psql without --single-transaction, and the
-- closing raise can only roll back the block it is in. Nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/thaw_test.sql

do $$
declare
  v_owner   uuid := gen_random_uuid();
  v_off     uuid := gen_random_uuid();   -- a deactivated Owner holding a live token
  v_l3      uuid := gen_random_uuid();
  v_l2a     uuid := gen_random_uuid();   -- branch A's admin
  v_l2b     uuid := gen_random_uuid();   -- branch B's admin
  v_today   date := current_date;
  v_d1      date := current_date - 9;    -- "1 Sep"
  v_d3      date := current_date - 7;    -- "3 Sep"
  v_d31     date := current_date - 10;   -- "31 Aug"
  v_d30     date := current_date - 11;   -- "30 Aug"
  v_d29     date := current_date - 12;   -- "29 Aug"
  v_chef    uuid;
  v_central uuid;
  v_bra     uuid;
  v_brb     uuid;
  v_sup     uuid;
  v_po      uuid;
  v_lotA    uuid;  v_lotB uuid;  v_lotC uuid;  v_lotD uuid;  v_lotE uuid;  v_lotF uuid;
  v_gA      uuid;  v_gB   uuid;  v_gC   uuid;  v_gD   uuid;  v_gE   uuid;  v_gF   uuid;
  v_codeA   text;
  v_codeB   text;
  v_rep     uuid;   -- A's day, today
  v_repB    uuid;   -- B's day, today
  v_old     uuid;   -- TC-29: a day five back
  v_line    uuid;
  v_k1      uuid := gen_random_uuid();   -- TC-16's thaw, replayed at TC-25/26/26b/27
  v_k20     uuid := gen_random_uuid();   -- TC-20's override
  v_key     uuid;
  v_res     json;
  v_res2    json;
  v_id      uuid;
  v_id20    uuid;
  v_ids     uuid[];
  v_dates   date[];
  v_codes   text[];
  v_w       numeric;
  v_ok      boolean;
  v_err     text;
  v_txt     text;
  v_n       bigint;
  v_thaws   bigint;
  v_rows    bigint;
  v_notes   bigint;
  v_payload jsonb;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_off), (v_l3), (v_l2a), (v_l2b);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',               'L1_OWNER',        true),
    (v_off,   'เจ้าของที่ปิดบัญชีแล้ว',     'L1_OWNER',        false),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',     'L3_CM_OPERATOR',  true),
    (v_l2a,   'แอดมินสาขาเอ',           'L2_BRANCH_ADMIN', true),
    (v_l2b,   'แอดมินสาขาบี',           'L2_BRANCH_ADMIN', true);

  insert into locations (code, name_th, kind) values ('CH40', 'โรงรมเชียงใหม่', 'CHEF_HOUSE') returning id into v_chef;
  insert into locations (code, name_th, kind) values ('CEN40', 'คลังกลาง', 'CENTRAL') returning id into v_central;
  insert into locations (code, name_th, kind) values ('BRA40', 'สาขาเอ', 'BRANCH') returning id into v_bra;
  insert into locations (code, name_th, kind) values ('BRB40', 'สาขาบี', 'BRANCH') returning id into v_brb;
  insert into user_locations (profile_id, location_id) values
    (v_l3, v_chef), (v_l2a, v_bra), (v_l2b, v_brb);
  insert into suppliers (name) values ('ฟู้ดดีว่า') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', v_today - 60, p_value_text => 'BY_LOT_WEIGHT');
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', v_today - 60, p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', v_today - 60, p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', v_today - 60, p_value_text => 'true');

  v_po   := fn_create_po(gen_random_uuid(), v_sup, v_today - 20, 1000.00, 250.00);
  v_lotA := fn_add_po_delivery(gen_random_uuid(), v_po, v_today - 20, 100.00, v_chef);
  v_lotB := fn_add_po_delivery(gen_random_uuid(), v_po, v_today - 20, 100.00, v_chef);
  v_lotC := fn_add_po_delivery(gen_random_uuid(), v_po, v_today - 20, 100.00, v_chef);
  v_lotD := fn_add_po_delivery(gen_random_uuid(), v_po, v_today - 20, 100.00, v_chef);
  v_lotE := fn_add_po_delivery(gen_random_uuid(), v_po, v_today - 20, 100.00, v_chef);
  v_lotF := fn_add_po_delivery(gen_random_uuid(), v_po, v_today - 20, 100.00, v_chef);

  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotA, v_d1)  returning id into v_gA;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotB, v_d3)  returning id into v_gB;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotC, v_d3)  returning id into v_gC;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotD, v_d31) returning id into v_gD;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotE, v_d30) returning id into v_gE;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotF, v_d29) returning id into v_gF;
  update lots set state = 'CENTRAL_STOCK' where id in (v_lotA, v_lotB, v_lotC, v_lotD, v_lotE, v_lotF);
  select lot_code into v_codeA from lots where id = v_lotA;
  select lot_code into v_codeB from lots where id = v_lotB;

  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_central, 'FROZEN', 'TRANSFER_IN', 10.00, v_today - 5,
                         p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_central, 'FROZEN', 'TRANSFER_IN', 10.00, v_today - 5,
                         p_lot_id => v_lotB, p_smoke_date_group_id => v_gB);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_central, 'FROZEN', 'TRANSFER_IN', 10.00, v_today - 5,
                         p_lot_id => v_lotC, p_smoke_date_group_id => v_gC);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_central, 'FROZEN', 'TRANSFER_IN', 5.00, v_today - 5,
                         p_lot_id => v_lotD, p_smoke_date_group_id => v_gD);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_central, 'FROZEN', 'TRANSFER_IN', 5.00, v_today - 5,
                         p_lot_id => v_lotE, p_smoke_date_group_id => v_gE);

  -- The Owner allocates. Some picks skip central's oldest date, so every call carries a reason;
  -- fn_allocate_to_branch drops it on a compliant pick. Not under test here.
  v_line := fn_allocate_to_branch(gen_random_uuid(), v_bra, v_today - 3, v_gA, 10.00, 5, 'ทดสอบ');
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line, v_today - 2, 10.00, p_received_bag_count => 5);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_line := fn_allocate_to_branch(gen_random_uuid(), v_bra, v_today - 3, v_gB, 10.00, 5, 'ทดสอบ');
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line, v_today - 2, 10.00, p_received_bag_count => 5);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_line := fn_allocate_to_branch(gen_random_uuid(), v_bra, v_today - 3, v_gC, 10.00, 5, 'ทดสอบ');
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line, v_today - 2, 10.00, p_received_bag_count => 5);
  -- L-D goes onto the truck to A and stays there.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_allocate_to_branch(gen_random_uuid(), v_bra, v_today - 3, v_gD, 5.00, 2, 'ทดสอบ');
  -- L-E to B, received by B.
  v_line := fn_allocate_to_branch(gen_random_uuid(), v_brb, v_today - 3, v_gE, 5.00, 2, 'ทดสอบ');
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line, v_today - 2, 5.00, p_received_bag_count => 2);
  -- L-F, READY at A (header).
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_bra, 'READY', 'TRANSFER_IN', 5.00, v_today - 2,
                         p_lot_id => v_lotF, p_smoke_date_group_id => v_gF);

  -- Both branches open today.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_rep := (fn_open_daily_report(gen_random_uuid(), v_bra, v_today) ->> 'daily_report_id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  v_repB := (fn_open_daily_report(gen_random_uuid(), v_brb, v_today) ->> 'daily_report_id')::uuid;

  --------------------------------------------------------------------------------- TC-06
  -- The actor is asked first: a deactivated Owner is NO_ACTOR, not FORBIDDEN (R31).
  perform set_config('request.jwt.claims', json_build_object('sub', v_off)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_require_branch_or_owner(v_bra);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NO_ACTOR:%';
  end;
  assert v_ok, format('TC-06: a deactivated Owner got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-07
  -- The Owner holds no assignment anywhere and passes for any location, a real one or not.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from user_locations where profile_id = v_owner;
  assert v_n = 0, 'TC-07: the fixture gave the Owner an assignment';
  assert fn_require_branch_or_owner(v_bra) = v_owner, 'TC-07: the Owner at branch A did not resolve to the Owner';
  assert fn_require_branch_or_owner(v_brb) = v_owner, 'TC-07: the Owner at branch B did not resolve to the Owner';
  assert fn_require_branch_or_owner(null) = v_owner, 'TC-07: the Owner with no location was refused';

  --------------------------------------------------------------------------------- TC-08
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  assert fn_require_branch_or_owner(v_bra) = v_l2a, 'TC-08: A''s admin at A did not resolve to themselves';

  -- B's admin at A, at nothing, and at a uuid that names nothing: one answer for all three.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  foreach v_id in array array[v_bra, null, gen_random_uuid()] loop
    v_ok := false; v_err := null;
    begin
      perform fn_require_branch_or_owner(v_id);
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN_LOCATION:%';
    end;
    assert v_ok, format('TC-08: B''s admin at %s got %s', coalesce(v_id::text, 'null'), coalesce(v_err, 'no exception at all'));
  end loop;

  -- The operator holds a membership — the chef house — and is still refused on role.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  foreach v_id in array array[v_chef, v_bra] loop
    v_ok := false; v_err := null;
    begin
      perform fn_require_branch_or_owner(v_id);
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
    end;
    assert v_ok, format('TC-08: the operator at %s got %s', v_id, coalesce(v_err, 'no exception at all'));
  end loop;

  ------------------------------------------------------------------------ TC-31, TC-05
  assert has_function_privilege('authenticated', 'public.fn_record_thaw(uuid, uuid, uuid, uuid, numeric, text)', 'EXECUTE'),
    'TC-31: authenticated cannot execute fn_record_thaw';
  assert not has_function_privilege('anon', 'public.fn_record_thaw(uuid, uuid, uuid, uuid, numeric, text)', 'EXECUTE'),
    'TC-31: anon can execute fn_record_thaw';
  assert not has_function_privilege('authenticated', 'public.fn_require_branch_or_owner(uuid)', 'EXECUTE')
     and not has_function_privilege('anon', 'public.fn_require_branch_or_owner(uuid)', 'EXECUTE'),
    'TC-05: the preamble is executable by a session role';

  --------------------------------------------------------------------------------- TC-32
  -- A's admin reads A's freezer: three rows, the 1 Sep lot first, then the two 3 Sep lots as two
  -- rows (not one), lot codes ascending inside the date. Nothing on the truck, nothing thawed.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  select array_agg(smoke_date_group_id), array_agg(smoke_date), array_agg(lot_code)
    into v_ids, v_dates, v_codes
    from v_branch_frozen_available
   where location_id = v_bra;
  assert cardinality(v_ids) = 3 and v_ids[1] = v_gA and v_ids[2:3] @> array[v_gB, v_gC],
    format('TC-32: A''s freezer offers %s, expected L-A''s group then L-B''s and L-C''s', v_ids);
  assert v_dates = array[v_d1, v_d3, v_d3], format('TC-32: the dates read %s', v_dates);
  assert v_codes[2] < v_codes[3], format('TC-32: inside one smoke date the order is %s', v_codes);
  select count(*) into v_n from v_branch_frozen_available where lot_id in (v_lotD, v_lotF);
  assert v_n = 0, format('TC-32: %s IN_TRANSIT or READY row(s) are offered as thawable (Seam 3)', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  select count(*) filter (where location_id = v_bra), count(*) into v_n, v_rows from v_branch_frozen_available;
  assert v_n = 0 and v_rows = 1, format('TC-32: B''s admin reads %s of A''s rows and %s in all', v_n, v_rows);

  foreach v_id in array array[v_l3, v_off] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
    select count(*) into v_n from v_branch_frozen_available;
    assert v_n = 0, format('TC-32: %s reads %s row(s)', (select display_name from profiles where id = v_id), v_n);
  end loop;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_branch_frozen_available;
  assert v_n = 4, format('TC-32: the Owner reads %s row(s), expected A''s three and B''s one', v_n);

  --------------------------------------------------------------------------------- TC-33
  select string_agg(column_name, ', ') into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'v_branch_frozen_available'
     and (column_name like '%cost%' or column_name like '%price%' or column_name like '%thb%'
       or column_name like '%yield%' or column_name like '%loss%');
  assert v_txt is null, format('TC-33: v_branch_frozen_available carries %s (R20)', v_txt);

  --------------------------------------------------------------- the refusals: TC-09 ... TC-23
  -- Every call from here to TC-16 is refused, and none of them writes anything anywhere.
  select count(*) into v_thaws from thaw_records;
  select count(*) into v_rows  from stock_ledger;
  select count(*) into v_notes from notifications;

  --------------------------------------------------------------------------------- TC-09
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(null, v_rep, v_lotA, v_gA, 3.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'IDEMPOTENCY_KEY_REQUIRED:%';
  end;
  assert v_ok, format('TC-09: a null key got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-10
  -- Another branch's day and a day that does not exist read the same to B's admin.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  foreach v_id in array array[v_rep, gen_random_uuid()] loop
    v_ok := false; v_err := null;
    begin
      perform fn_record_thaw(gen_random_uuid(), v_id, v_lotA, v_gA, 3.00);
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN_LOCATION:%';
    end;
    assert v_ok, format('TC-10: B''s admin with report %s got %s', v_id, coalesce(v_err, 'no exception at all'));
  end loop;

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_rep, v_lotA, v_gA, 3.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('TC-10: the operator got %s', coalesce(v_err, 'no exception at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_off)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_rep, v_lotA, v_gA, 3.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NO_ACTOR:%';
  end;
  assert v_ok, format('TC-10: a deactivated Owner got %s', coalesce(v_err, 'no exception at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), gen_random_uuid(), v_lotA, v_gA, 3.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'REPORT_NOT_FOUND:%';
  end;
  assert v_ok, format('TC-10: the Owner with no such report got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-13
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  foreach v_w in array array[0, -1, 3.005, null]::numeric[] loop
    v_ok := false; v_err := null;
    begin
      perform fn_record_thaw(gen_random_uuid(), v_rep, v_lotA, v_gA, v_w);
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'THAW_WEIGHT_INVALID:%';
    end;
    assert v_ok, format('TC-13: weight %s got %s', coalesce(v_w::text, 'null'), coalesce(v_err, 'no exception at all'));
  end loop;

  --------------------------------------------------------------------------------- TC-14
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_rep, null, v_gA, 3.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_REQUIRED:%';
  end;
  assert v_ok, format('TC-14: no lot got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_rep, v_lotA, null, 3.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'SMOKE_GROUP_REQUIRED:%';
  end;
  assert v_ok, format('TC-14: no group got %s', coalesce(v_err, 'no exception at all'));

  -- L-B's group named with L-C: the lot is required AND must be the group's own. The message
  -- names the lot the group belongs to.
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_rep, v_lotC, v_gB, 3.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_REQUIRED:%belongs to lot ' || v_codeB || '%';
  end;
  assert v_ok, format('TC-14: L-B''s group under L-C got %s', coalesce(v_err, 'no exception at all'));

  -- L-A's group at branch B, which never received it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_repB, v_lotA, v_gA, 3.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_REQUIRED:%no frozen stock%';
  end;
  assert v_ok, format('TC-14: L-A''s group at B got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-15
  -- Meat still on the truck, and meat already thawed: not thawable, refused by name before
  -- fn_post_ledger could say INSUFFICIENT_STOCK about a balance nobody asked about (Seam 3).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_rep, v_lotD, v_gD, 1.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_REQUIRED:%no frozen stock%';
  end;
  assert v_ok, format('TC-15: the IN_TRANSIT-only group got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_rep, v_lotF, v_gF, 1.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_REQUIRED:%no frozen stock%';
  end;
  assert v_ok, format('TC-15: the READY-only group got %s', coalesce(v_err, 'no exception at all'));

  ------------------------------------------------------------------------ TC-19, TC-23
  -- 3 Sep while 1 Sep is still in A's freezer: a reason, naming 1 Sep. Blank is no reason.
  foreach v_txt in array array[null, '   '] loop
    v_ok := false; v_err := null;
    begin
      perform fn_record_thaw(gen_random_uuid(), v_rep, v_lotB, v_gB, 3.00, v_txt);
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'FIFO_REASON_REQUIRED:%' || v_d1::text || '%';
    end;
    assert v_ok, format('TC-19/TC-23: skipping %s with reason [%s] got %s', v_d1, coalesce(v_txt, 'null'),
                        coalesce(v_err, 'no exception at all'));
  end loop;

  assert (select count(*) from thaw_records) = v_thaws
     and (select count(*) from stock_ledger) = v_rows
     and (select count(*) from notifications) = v_notes,
    'TC-09 ... TC-23: a refused thaw wrote a thaw row, a ledger row or a notification';

  ------------------------------------------------------------------------ TC-16, TC-24
  -- UAT-10's first half. And TC-24 in the same call: an older date exists only at branch B
  -- (L-E, 30 Aug), only IN_TRANSIT to A (L-D, 31 Aug) and only READY at A (L-F, 29 Aug). None of
  -- them is an older date for A's freezer, so 1 Sep needs no reason. Each of the three alone
  -- would flip fifo_override if "oldest" were scoped wrong.
  v_res := fn_record_thaw(v_k1, v_rep, v_lotA, v_gA, 3.00);
  v_id  := (v_res ->> 'thaw_record_id')::uuid;
  assert (v_res ->> 'frozen_remaining_kg')::numeric = 7.00
     and (v_res ->> 'ready_available_kg')::numeric = 3.00
     and not (v_res ->> 'fifo_override')::boolean,
    format('TC-16/TC-24: the thaw answered %s', v_res);

  select string_agg(format('%s/%s/%s', movement_type, stock_state, qty_delta), ',' order by qty_delta)
    into v_txt
    from stock_ledger where source_table = 'thaw_records' and source_id = v_id;
  assert v_txt = 'THAW_OUT/FROZEN/-3.00,THAW_IN/READY/3.00', format('TC-16: the thaw posted %s', v_txt);
  select count(*) into v_n
    from stock_ledger
   where source_table = 'thaw_records' and source_id = v_id
     and lot_id = v_lotA and smoke_date_group_id = v_gA and location_id = v_bra
     and business_date = v_today and item_type = 'SMOKED_MEAT';
  assert v_n = 2, format('TC-16: %s of the 2 rows carry L-A, its group, branch A and the report''s date', v_n);
  select count(*) into v_n
    from thaw_records
   where id = v_id and created_by = v_l2a and daily_report_id = v_rep and thawed_weight_kg = 3.00
     and fifo_override_reason is null and idempotency_key = v_k1;
  assert v_n = 1, 'TC-16: the thaw record does not read as A''s admin''s 3.00 kg on today''s report';
  select state::text into v_txt from lots where id = v_lotA;
  assert v_txt = 'CENTRAL_STOCK', format('TC-16: the thaw moved L-A to %s (ADR-026)', v_txt);
  assert (select count(*) from notifications) = v_notes, 'TC-24: a compliant thaw wrote a notification';

  --------------------------------------------------------------------------------- TC-30
  select count(*) into v_n from audit_log where table_name = 'thaw_records' and row_id = v_id;
  assert v_n = 1, format('TC-30: the thaw record has %s audit row(s), expected the trigger''s one (R32)', v_n);

  ------------------------------------------------------------------------ TC-25, TC-26
  select count(*) into v_rows from stock_ledger;
  v_res2 := fn_record_thaw(v_k1, v_rep, v_lotA, v_gA, 3.00);
  assert (v_res2 ->> 'thaw_record_id')::uuid = v_id, format('TC-25: the replay answered %s', v_res2);
  -- A different payload under the same key: the key wins, and the answer is the original's.
  v_res2 := fn_record_thaw(v_k1, v_rep, v_lotB, v_gB, 9.99, 'อะไรก็ได้');
  assert (v_res2 ->> 'thaw_record_id')::uuid = v_id
     and (v_res2 ->> 'lot_id')::uuid = v_lotA
     and (v_res2 ->> 'thawed_weight_kg')::numeric = 3.00
     and (v_res2 ->> 'frozen_remaining_kg')::numeric = 7.00
     and not (v_res2 ->> 'fifo_override')::boolean,
    format('TC-26: a replay with another payload answered %s', v_res2);
  select count(*) into v_n from thaw_records where idempotency_key = v_k1;
  assert v_n = 1, format('TC-25: %s thaw row(s) carry the key', v_n);
  assert (select count(*) from stock_ledger) = v_rows,
    format('TC-25/TC-26: two replays posted %s ledger row(s)', (select count(*) from stock_ledger) - v_rows);
  select count(*) into v_n from audit_log where table_name = 'thaw_records' and row_id = v_id;
  assert v_n = 1, format('TC-25: the replays left %s audit row(s) on the record', v_n);

  --------------------------------------------------------------------------------- TC-26c
  -- A key already spent on another write — here the allocation's TRANSFER_OUT — is refused, and
  -- no thaw record is left standing with no movement behind it.
  select idempotency_key into v_key from stock_ledger where source_table = 'transport_lines' limit 1;
  select count(*) into v_thaws from thaw_records;
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(v_key, v_rep, v_lotA, v_gA, 1.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'IDEMPOTENCY_KEY_REUSED:%';
  end;
  assert v_ok, format('TC-26c: a key spent on an allocation got %s', coalesce(v_err, 'no exception at all'));
  assert (select count(*) from thaw_records) = v_thaws and (select count(*) from stock_ledger) = v_rows,
    'TC-26c: the refused thaw left a record or a ledger row';

  --------------------------------------------------------------------------------- TC-17
  v_res := fn_record_thaw(gen_random_uuid(), v_rep, v_lotA, v_gA, 2.00);
  assert (v_res ->> 'frozen_remaining_kg')::numeric = 5.00 and (v_res ->> 'ready_available_kg')::numeric = 5.00,
    format('TC-17: a second partial thaw answered %s', v_res);

  --------------------------------------------------------------------------------- TC-18
  select count(*) into v_thaws from thaw_records;
  select count(*) into v_rows  from stock_ledger;
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_rep, v_lotA, v_gA, 6.00);
  exception when others then
    v_err := sqlerrm;
    v_ok := v_err like 'INSUFFICIENT_FROZEN_STOCK:%' || v_codeA || '%' || v_d1::text || '%5.00%';
  end;
  assert v_ok, format('TC-18: 6.00 kg of 5.00 got %s', coalesce(v_err, 'no exception at all'));
  assert (select count(*) from thaw_records) = v_thaws and (select count(*) from stock_ledger) = v_rows,
    'TC-18: the refused over-thaw left a record or a ledger row';

  --------------------------------------------------------------------------------- TC-22
  -- A reason on the oldest date is dropped, not stored: it is not an override.
  select count(*) into v_notes from notifications;
  v_res := fn_record_thaw(gen_random_uuid(), v_rep, v_lotA, v_gA, 1.00, 'ไม่จำเป็นต้องมีเหตุผล');
  select fifo_override_reason into v_txt from thaw_records where id = (v_res ->> 'thaw_record_id')::uuid;
  assert v_txt is null and not (v_res ->> 'fifo_override')::boolean,
    format('TC-22: a compliant pick stored reason %s and answered %s', v_txt, v_res);
  assert (select count(*) from notifications) = v_notes, 'TC-22: a compliant pick wrote a notification';

  ------------------------------------------------------------------------ TC-20, TC-25
  -- L-A holds 4.00 at 1 Sep. 3 Sep with a reason goes, and the Owner is told once.
  v_res  := fn_record_thaw(v_k20, v_rep, v_lotB, v_gB, 1.00, 'ลูกค้าขอของรมใหม่');
  v_id20 := (v_res ->> 'thaw_record_id')::uuid;
  assert (v_res ->> 'fifo_override')::boolean, format('TC-20: the override answered %s', v_res);
  select fifo_override_reason into v_txt from thaw_records where id = v_id20;
  assert v_txt = 'ลูกค้าขอของรมใหม่', format('TC-20: the override stored %s', v_txt);
  select count(*) into v_n from notifications
   where kind = 'FIFO_OVERRIDE' and target_role = 'L1_OWNER' and location_id = v_bra and lot_id = v_lotB;
  assert v_n = 1 and (select count(*) from notifications) = v_notes + 1,
    format('TC-20: %s FIFO_OVERRIDE row(s) for L-B at A', v_n);
  select payload into v_payload from notifications where kind = 'FIFO_OVERRIDE' and lot_id = v_lotB;
  assert (v_payload ->> 'smoke_date')::date = v_d3 and (v_payload ->> 'oldest_smoke_date')::date = v_d1
     and (v_payload ->> 'thaw_record_id')::uuid = v_id20
     and (v_payload ->> 'thawed_weight_kg')::numeric = 1.00
     and v_payload ->> 'fifo_override_reason' = 'ลูกค้าขอของรมใหม่',
    format('TC-20: the notification payload reads %s', v_payload);

  v_res2 := fn_record_thaw(v_k20, v_rep, v_lotB, v_gB, 1.00, 'ลูกค้าขอของรมใหม่');
  assert (v_res2 ->> 'thaw_record_id')::uuid = v_id20 and (select count(*) from notifications) = v_notes + 1,
    'TC-25: replaying an override wrote a second notification';

  --------------------------------------------------------------------------------- TC-21
  -- Empty 1 Sep. Then the two 3 Sep lots, in both orders, with no reason: inside the oldest date
  -- the lot is a choice, so uuid or lot-code order cannot pass this by luck (Seam 2).
  v_res := fn_record_thaw(gen_random_uuid(), v_rep, v_lotA, v_gA, 4.00);
  assert (v_res ->> 'frozen_remaining_kg')::numeric = 0.00, format('TC-21: emptying L-A answered %s', v_res);
  select count(*) into v_n from v_branch_frozen_available where smoke_date_group_id = v_gA;
  assert v_n = 0, 'TC-21: an emptied group is still offered';

  select count(*) into v_notes from notifications;
  foreach v_id in array array[v_lotC, v_lotB, v_lotB, v_lotC] loop
    v_res := fn_record_thaw(gen_random_uuid(), v_rep, v_id,
                            case v_id when v_lotB then v_gB else v_gC end, 1.00);
    assert not (v_res ->> 'fifo_override')::boolean,
      format('TC-21: %s inside the oldest date answered %s', (select lot_code from lots where id = v_id), v_res);
  end loop;
  assert (select count(*) from notifications) = v_notes, 'TC-21: a pick inside the oldest date notified the Owner';

  --------------------------------------------------------------------------------- TC-28
  -- v0.2:57 and UAT-15: the Owner edits every branch. Signed as the Owner, not as A's admin.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_res := fn_record_thaw(gen_random_uuid(), v_rep, v_lotC, v_gC, 1.00);
  select created_by into v_id from thaw_records where id = (v_res ->> 'thaw_record_id')::uuid;
  assert v_id = v_owner, format('TC-28: the Owner''s thaw was signed by %s', v_id);

  -- The Owner may replay any branch's key, and gets the original answer.
  v_res2 := fn_record_thaw(v_k1, v_repB, v_lotE, v_gE, 1.00);
  assert (v_res2 ->> 'lot_id')::uuid = v_lotA, format('TC-28: the Owner''s replay of A''s key answered %s', v_res2);

  -------------------------------------------------------------------------------- TC-26b
  -- B's admin holding A's key learns nothing, whether they name A's report or their own.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  select count(*) into v_rows from stock_ledger;
  foreach v_id in array array[v_repB, v_rep] loop
    v_ok := false; v_err := null;
    begin
      perform fn_record_thaw(v_k1, v_id, v_lotE, v_gE, 1.00);
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN_LOCATION:%';
    end;
    assert v_ok, format('TC-26b: B''s admin replaying A''s key on report %s got %s', v_id, coalesce(v_err, 'no exception at all'));
  end loop;
  assert (select count(*) from stock_ledger) = v_rows, 'TC-26b: a refused replay posted a ledger row';

  --------------------------------------------------------------------------------- TC-12
  -- An UNLOCKED day takes the correction it was reopened for (Seam 4).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  update daily_reports set status = 'UNLOCKED' where id = v_rep;
  v_res := fn_record_thaw(gen_random_uuid(), v_rep, v_lotC, v_gC, 1.00);
  assert (v_res ->> 'thaw_record_id') is not null, format('TC-12: an UNLOCKED day answered %s', v_res);

  --------------------------------------------------------------------------------- TC-11
  -- CLOSED, and no unlock_requests row for it: lane C's trigger refuses the thaw_records insert
  -- by name, before any ledger row.
  update daily_reports set status = 'CLOSED', closed_at = now(), closed_by = v_l2a where id = v_rep;
  select count(*) into v_thaws from thaw_records;
  select count(*) into v_rows  from stock_ledger;
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_rep, v_lotC, v_gC, 1.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'REPORT_CLOSED:%' || v_today::text || '%';
  end;
  assert v_ok, format('TC-11: a closed day got %s', coalesce(v_err, 'no exception at all'));
  assert (select count(*) from thaw_records) = v_thaws and (select count(*) from stock_ledger) = v_rows,
    'TC-11: the refused thaw wrote a record or a ledger row';

  --------------------------------------------------------------------------------- TC-27
  -- The thaw that committed before the close, retried after it: a return, not a refusal (R4).
  -- The balances are read now: all of L-A is thawed.
  v_res := fn_record_thaw(v_k1, v_rep, v_lotA, v_gA, 3.00);
  select id into v_id from thaw_records where idempotency_key = v_k1;
  assert (v_res ->> 'thaw_record_id')::uuid = v_id
     and (v_res ->> 'frozen_remaining_kg')::numeric = 0.00
     and (v_res ->> 'ready_available_kg')::numeric = 10.00,
    format('TC-27: the retry after the close answered %s', v_res);

  --------------------------------------------------------------------------------- TC-29
  -- Opening balances closed, the window 3 days. None of the fixture's rows is OPENING, so the
  -- close's completeness check passes vacuously.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_close_opening_balances(gen_random_uuid());
  perform fn_set_config(gen_random_uuid(), 'unlock_max_days_back', v_today - 60, p_value_numeric => 3);
  -- Today's report is CLOSED (TC-11), so an OPEN day five back can exist beside it.
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
    values (v_bra, v_today - 5, now(), v_l2a) returning id into v_old;

  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_old, v_lotC, v_gC, 1.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'BACKDATE_NOT_ALLOWED:%' || (v_today - 5)::text || '%';
  end;
  assert v_ok, format('TC-29: an open day five back got %s', coalesce(v_err, 'no exception at all'));
  assert (select count(*) from thaw_records) = v_thaws and (select count(*) from stock_ledger) = v_rows,
    'TC-29: the refused back-dated thaw wrote a record or a ledger row';

  -- The companion (handoff deviation 1): the same day UNLOCKED is the escalation R28 names, and
  -- it takes the thaw, dated to the report.
  update daily_reports set status = 'UNLOCKED' where id = v_old;
  v_res := fn_record_thaw(gen_random_uuid(), v_old, v_lotC, v_gC, 1.00);
  select count(*) into v_n from stock_ledger
   where source_table = 'thaw_records' and source_id = (v_res ->> 'thaw_record_id')::uuid
     and business_date = v_today - 5;
  assert v_n = 2, format('TC-29: the unlocked day''s thaw posted %s row(s) dated to it', v_n);

  -- And the window's last day is inside it (R28 is inclusive).
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
    values (v_bra, v_today - 3, now(), v_l2a) returning id into v_old;
  v_res := fn_record_thaw(gen_random_uuid(), v_old, v_lotC, v_gC, 1.00);
  assert (v_res ->> 'thaw_record_id') is not null, format('TC-29: the window''s last day answered %s', v_res);

  -------------------------------------------------------------------------------- TC-29b
  -- ^ref-08's model (ref-08-unlock/PLAN-unlock.md Finding 1): an approval is an unlock_requests
  -- row, and the day stays CLOSED. Ten days back is outside the 3-day window, and the approved
  -- correction lands anyway — no REPORT_CLOSED (lane C's trigger admits it) and no
  -- BACKDATE_NOT_ALLOWED (the window is an OPEN day's question). Column names are the ...0002
  -- table's; ...0023 (lane H) adds only nullable columns and the APPROVED-needs-expiry check.
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by, closed_by, closed_at)
    values (v_bra, v_today - 10, now() - interval '10 days', 'CLOSED', v_l2a, v_l2a, now() - interval '9 days')
    returning id into v_old;
  insert into unlock_requests (target_type, target_id, requested_by, reason, status,
                               decided_by, decided_at, expires_at)
    values ('DAILY_REPORT', v_old, v_l2a, 'ละลายเกินจริง ต้องแก้ยอด', 'APPROVED',
            v_owner, now(), now() + interval '2 hours');
  v_res := null; v_err := null;
  begin
    v_res := fn_record_thaw(gen_random_uuid(), v_old, v_lotC, v_gC, 1.00);
  exception when others then
    v_err := sqlerrm;
  end;
  assert v_err is null,
    format('TC-29b: a closed day ten back under a live approval got %s', v_err);
  select count(*) into v_n from stock_ledger
   where source_table = 'thaw_records' and source_id = (v_res ->> 'thaw_record_id')::uuid
     and business_date = v_today - 10;
  assert v_n = 2, format('TC-29b: the approved correction posted %s row(s) dated to its day', v_n);
  select status::text into v_txt from daily_reports where id = v_old;
  assert v_txt = 'CLOSED', format('TC-29b: the thaw moved the approved day to %s', v_txt);

  -------------------------------------------------------------------------------- TC-29c
  -- The same shape with the approval expired a minute ago: R42 is read at write time, so the
  -- day is shut again, and nothing is written.
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by, closed_by, closed_at)
    values (v_bra, v_today - 11, now() - interval '11 days', 'CLOSED', v_l2a, v_l2a, now() - interval '10 days')
    returning id into v_old;
  insert into unlock_requests (target_type, target_id, requested_by, reason, status,
                               decided_by, decided_at, expires_at)
    values ('DAILY_REPORT', v_old, v_l2a, 'หมดเวลาแก้แล้ว', 'APPROVED',
            v_owner, now() - interval '3 hours', now() - interval '1 minute');
  select count(*) into v_thaws from thaw_records;
  select count(*) into v_rows  from stock_ledger;
  v_ok := false; v_err := null;
  begin
    perform fn_record_thaw(gen_random_uuid(), v_old, v_lotC, v_gC, 1.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'REPORT_CLOSED:%' || (v_today - 11)::text || '%';
  end;
  assert v_ok, format('TC-29c: a closed day under an expired approval got %s', coalesce(v_err, 'no exception at all'));
  assert (select count(*) from thaw_records) = v_thaws and (select count(*) from stock_ledger) = v_rows,
    'TC-29c: the refused thaw wrote a record or a ledger row';

  raise exception 'THAW_TEST_PASSED';
end $$;
