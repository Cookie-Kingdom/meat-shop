-- Card ^ref-66 — fn_assign_lot_operator.
--
-- Covers LA-01 ... LA-10 from v.0.1/ref-66-assign-operator/PLAN-assign-operator.md.
--
-- ONE do $$ BLOCK, for production_test.sql's reason: migrations_apply_test.sh pipes each file
-- into psql without --single-transaction, and the closing raise can only roll back the block
-- it is in.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/lot_assignment_test.sql

do $$
declare
  v_n        bigint;
  v_n2       bigint;
  v_ledger   bigint;
  v_who      uuid;
  v_ok       boolean;
  v_err      text;
  v_day      date := date '2026-05-04';
  v_owner    uuid := gen_random_uuid();
  v_owner_x  uuid := gen_random_uuid();
  v_l2       uuid := gen_random_uuid();
  v_l3       uuid := gen_random_uuid();
  v_l3c      uuid := gen_random_uuid();
  v_l3b      uuid := gen_random_uuid();
  v_l3_x     uuid := gen_random_uuid();
  v_chef     uuid;
  v_chef2    uuid;
  v_branch   uuid;
  v_sup      uuid;
  v_po       uuid;
  v_lotA     uuid;
  v_lotC     uuid;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values
    (v_owner), (v_owner_x), (v_l2), (v_l3), (v_l3c), (v_l3b), (v_l3_x);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner,   'เจ้าของ',                   'L1_OWNER',        true),
    (v_owner_x, 'เจ้าของที่ปิดใช้',             'L1_OWNER',        false),
    (v_l2,      'แอดมินสาขา',                'L2_BRANCH_ADMIN', true),
    (v_l3,      'ผู้ปฏิบัติงานคนที่หนึ่ง',       'L3_CM_OPERATOR',  true),
    (v_l3c,     'ผู้ปฏิบัติงานคนที่สอง',        'L3_CM_OPERATOR',  true),
    (v_l3b,     'ผู้ปฏิบัติงานโรงรมที่สอง',     'L3_CM_OPERATOR',  true),
    (v_l3_x,    'ผู้ปฏิบัติงานที่ปิดใช้',        'L3_CM_OPERATOR',  false);

  insert into locations (code, name_th, kind) values ('CH66', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('CH67', 'โรงรมที่สอง', 'CHEF_HOUSE')
    returning id into v_chef2;
  insert into locations (code, name_th, kind) values ('BR66', 'สาขามีนบุรี', 'BRANCH')
    returning id into v_branch;

  -- v_l3_x is a member of the chef house, so LA-07 fails on the profile and not on membership.
  insert into user_locations (profile_id, location_id) values
    (v_l3, v_chef), (v_l3c, v_chef), (v_l3_x, v_chef), (v_l3b, v_chef2), (v_l2, v_branch);

  insert into suppliers (name) values ('ฟู้ดดีว่า') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_po   := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);
  v_lotA := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotC := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);

  select count(*) into v_ledger from stock_ledger;

  --------------------------------------------------------------------------------- LA-01
  select count(*) into v_n from audit_log where table_name = 'lots' and row_id = v_lotA;
  v_who := fn_assign_lot_operator(gen_random_uuid(), v_lotA, v_l3);
  assert v_who = v_lotA, format('LA-01: returned %s, not the lot id', v_who);
  assert (select assigned_operator_id from lots where id = v_lotA) = v_l3,
    'LA-01: the lot is not assigned to the operator';

  select count(*) into v_n2 from audit_log
   where table_name = 'lots' and row_id = v_lotA and action = 'UPDATE'
     and actor_id = v_owner and actor_role = 'L1_OWNER'
     and before ->> 'assigned_operator_id' is null
     and (after ->> 'assigned_operator_id')::uuid = v_l3;
  assert v_n2 = 1, format('LA-01: %s audit row(s) record the assignment, expected 1', v_n2);

  --------------------------------------------------------------------------------- LA-02
  -- The column this writes is the one fn_require_operator reads: the assignee passes step 4,
  -- and a second L3 at the same chef house does not.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  assert fn_require_operator(v_lotA) = v_l3, 'LA-02: the assigned operator is refused';

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3c)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_require_operator(v_lotA);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_ASSIGNED_OPERATOR:%';
  end;
  assert v_ok, format('LA-02: another operator at the chef house got %s',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- LA-03
  -- R38: the standing operator under a fresh key is a retry, and writes no audit row.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from audit_log where table_name = 'lots' and row_id = v_lotA;
  v_who := fn_assign_lot_operator(gen_random_uuid(), v_lotA, v_l3);
  select count(*) into v_n2 from audit_log where table_name = 'lots' and row_id = v_lotA;
  assert v_who = v_lotA, 'LA-03: the replay did not return the lot id';
  assert v_n2 = v_n, format('LA-03: a replay wrote %s audit row(s)', v_n2 - v_n);

  --------------------------------------------------------------------------------- LA-04
  -- A reassignment keeps both names in the audit trail, and moves the door with it.
  perform fn_assign_lot_operator(gen_random_uuid(), v_lotA, v_l3c);
  assert (select assigned_operator_id from lots where id = v_lotA) = v_l3c,
    'LA-04: the reassignment did not land';

  select count(*) into v_n from audit_log
   where table_name = 'lots' and row_id = v_lotA and action = 'UPDATE'
     and (before ->> 'assigned_operator_id')::uuid = v_l3
     and (after  ->> 'assigned_operator_id')::uuid = v_l3c;
  assert v_n = 1, format('LA-04: %s audit row(s) record the reassignment, expected 1', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_require_operator(v_lotA);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_ASSIGNED_OPERATOR:%';
  end;
  assert v_ok, format('LA-04: the operator it was taken from got %s',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- LA-05
  -- Only L1. The L3 is refused on an unknown lot id too, so it learns nothing about lot ids.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(gen_random_uuid(), v_lotA, v_l3);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('LA-05: an L2 got %s', coalesce(v_err, 'no exception at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(gen_random_uuid(), v_lotA, v_l3);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('LA-05: an L3 assigning themselves got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(gen_random_uuid(), gen_random_uuid(), v_l3);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('LA-05: an L3 probing an unknown lot got %s', coalesce(v_err, 'no exception at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner_x)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(gen_random_uuid(), v_lotA, v_l3);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NO_ACTOR:%';
  end;
  assert v_ok, format('LA-05: a deactivated Owner got %s', coalesce(v_err, 'no exception at all'));

  assert (select assigned_operator_id from lots where id = v_lotA) = v_l3c,
    'LA-05: a refused caller moved the assignment';

  --------------------------------------------------------------------------------- LA-06
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(gen_random_uuid(), v_lotA, v_l3b);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'OPERATOR_NOT_AT_CHEF_HOUSE:%';
  end;
  assert v_ok, format('LA-06: an L3 of another chef house got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- LA-07
  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(gen_random_uuid(), v_lotA, v_l2);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_AN_OPERATOR:%';
  end;
  assert v_ok, format('LA-07: an L2 as the operator got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(gen_random_uuid(), v_lotA, v_l3_x);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_AN_OPERATOR:%';
  end;
  assert v_ok, format('LA-07: a deactivated L3 at the chef house got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(gen_random_uuid(), v_lotA, gen_random_uuid());
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_AN_OPERATOR:%';
  end;
  assert v_ok, format('LA-07: an unknown profile got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- LA-08
  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(null, v_lotA, v_l3);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'IDEMPOTENCY_KEY_REQUIRED:%';
  end;
  assert v_ok, format('LA-08: a null key got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(gen_random_uuid(), v_lotA, null);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'OPERATOR_REQUIRED:%';
  end;
  assert v_ok, format('LA-08: a null operator got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(gen_random_uuid(), gen_random_uuid(), v_l3);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_NOT_FOUND:%';
  end;
  assert v_ok, format('LA-08: an unknown lot got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- LA-09
  -- A closed lot keeps its operator. The close is set directly: fn_close_lot needs a whole
  -- production run, and what is under test is this function's state guard, not the close.
  perform fn_assign_lot_operator(gen_random_uuid(), v_lotC, v_l3);
  update lots set state = 'LOT_CLOSED', closed_at = now() where id = v_lotC;

  v_ok := false; v_err := null;
  begin
    perform fn_assign_lot_operator(gen_random_uuid(), v_lotC, v_l3c);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_ALREADY_CLOSED:%';
  end;
  assert v_ok, format('LA-09: reassigning a closed lot got %s', coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from audit_log where table_name = 'lots' and row_id = v_lotC;
  v_who := fn_assign_lot_operator(gen_random_uuid(), v_lotC, v_l3);
  select count(*) into v_n2 from audit_log where table_name = 'lots' and row_id = v_lotC;
  assert v_who = v_lotC and v_n2 = v_n,
    'LA-09: a retry of the standing operator after the close was refused or wrote';

  --------------------------------------------------------------------------------- LA-10
  select count(*) into v_n from stock_ledger;
  assert v_n = v_ledger, format('LA-10: assignment wrote %s stock_ledger row(s)', v_n - v_ledger);

  raise exception 'LOT_ASSIGNMENT_TEST_PASSED';   -- the only clean way back out
end $$;
