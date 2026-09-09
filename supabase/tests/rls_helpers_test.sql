-- Failure-case tests for the ^ref-05 helpers and the profiles policy.
--
-- Every assert below is a way the card fails silently rather than loudly:
--   * the helper recurses and every policy in the system throws at query time
--   * a deactivated profile keeps its role because is_active was checked somewhere else
--   * fn_current_locations() returns null, and `= any(null)` quietly matches nothing that
--     anyone ever verifies
--   * a policy exists but the grant behind it opens the whole table
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/rls_helpers_test.sql

do $$
declare
  v_owner    uuid := '11111111-1111-1111-1111-111111111111';
  v_admin    uuid := '22222222-2222-2222-2222-222222222222';
  v_dormant  uuid := '33333333-3333-3333-3333-333333333333';
  v_unscoped uuid := '44444444-4444-4444-4444-444444444444';
  v_branch   uuid;
  v_role     user_role;
  v_locs     uuid[];
  v_n        bigint;
  v_ok       boolean;
begin
  insert into auth.users (id) values (v_owner), (v_admin), (v_dormant), (v_unscoped);

  insert into profiles (id, display_name, role, is_active) values
    (v_owner,    'เจ้าของ',        'L1_OWNER',        true),
    (v_admin,    'แอดมินสาขา',     'L2_BRANCH_ADMIN', true),
    (v_dormant,  'พนักงานลาออก',   'L3_CM_OPERATOR',  false),
    (v_unscoped, 'ยังไม่ผูกสาขา',  'L2_BRANCH_ADMIN', true);

  insert into locations (code, name_th, kind, rice_model)
       values ('B01', 'สาขาทดสอบ', 'BRANCH', 'EXTERNAL_COOKED')
    returning id into v_branch;

  insert into user_locations (profile_id, location_id) values (v_admin, v_branch);

  ---------------------------------------------------------------- as an L2 branch admin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);

  -- TC-02. The helper reads `profiles`, and `profiles` now has a policy that calls the
  -- helper. Without SECURITY DEFINER this line is `stack depth limit exceeded`.
  v_role := fn_current_role();
  assert v_role = 'L2_BRANCH_ADMIN', format('fn_current_role() gave %s for an active L2', v_role);

  v_locs := fn_current_locations();
  assert v_locs = array[v_branch], format('fn_current_locations() gave %s, expected one branch', v_locs);

  -- TC-05 shape. Zero rows for someone else's profile, not an error and not a partial row.
  select count(*) into v_n from profiles;
  assert v_n = 1, format('an L2 saw %s profiles, expected only their own', v_n);

  -- Card acceptance, clause 3. The grant is SELECT and nothing else, forever (ADR-002).
  v_ok := false;
  begin
    update profiles set display_name = 'เปลี่ยนเอง' where id = v_admin;
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'authenticated could UPDATE profiles directly';

  ------------------------------------------------------------------ a deactivated profile
  -- TC-07. A valid JWT survives deactivation; the role must not.
  perform set_config('request.jwt.claims', json_build_object('sub', v_dormant)::text, true);
  v_role := fn_current_role();
  assert v_role is null, format('a deactivated profile still resolved to %s', v_role);

  select count(*) into v_n from profiles;
  assert v_n = 0, format('a deactivated profile read %s rows from profiles', v_n);

  ------------------------------------------------------- a profile with no user_locations
  perform set_config('request.jwt.claims', json_build_object('sub', v_unscoped)::text, true);
  v_locs := fn_current_locations();
  assert v_locs = '{}', format('fn_current_locations() gave %s, expected an empty array', v_locs);
  assert v_locs is not null, 'fn_current_locations() returned null — `= any(null)` is null, not false';

  ------------------------------------------------------------------------------ the Owner
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from profiles;
  assert v_n = 4, format('the Owner saw %s profiles, expected all 4', v_n);

  -- An L1 who is also scoped to a location must not be narrowed by that scope. The Owner
  -- has no user_locations row here and still reads everything, which is the same rule seen
  -- from the empty side.
  assert fn_current_locations() = '{}', 'the Owner picked up a location scope from nowhere';

  ------------------------------------------------------------------------------- as anon
  reset role;
  set local role anon;
  perform set_config('request.jwt.claims', '', true);

  v_ok := false;
  begin
    perform 1 from profiles limit 1;
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'anon could read profiles — the policy is granted to authenticated only';

  v_ok := false;
  begin
    perform fn_current_role();
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'anon could execute fn_current_role()';

  reset role;

  raise exception 'RLS_HELPERS_TEST_PASSED';   -- the only clean way back out
end $$;
