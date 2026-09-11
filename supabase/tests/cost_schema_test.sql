-- Card ^ref-32 — the schema half: …0022's columns and checks, v_lot_cost's column contract,
-- and the grant shape. TC-10 ... TC-12 of v.0.1/ref-31-33-cost/TDD-cost.md.
-- Contract assumed from an unmerged lane: none (every function called is on develop at 9362eca).
--
-- The checks are exercised with direct UPDATEs as the superuser on purpose: the constraint is
-- the enforcement for every writer, including one added in 2027 that never goes through
-- fn_set_smoke_fee_override. The function's named refusals are cost_test.sql's.
--
-- ONE do $$ BLOCK, for lot_close_test.sql's reason. Everything runs in a transaction that
-- aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/cost_schema_test.sql

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_chef  uuid;
  v_sup   uuid;
  v_po    uuid;
  v_lot   uuid;
  v_n     bigint;
  v_txt   text;
  v_bad   text;
  v_ok    boolean;
  v_con   text;
  v_prec  integer;
  v_scale integer;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner);
  insert into profiles (id, display_name, role, is_active)
    values (v_owner, 'เจ้าของ', 'L1_OWNER', true);
  insert into locations (code, name_th, kind) values ('CH32S', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into suppliers (name) values ('Foodiva') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_po  := fn_create_po(gen_random_uuid(), v_sup, date '2026-05-04', 500.00, 250.00);
  v_lot := fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-05-04', 100.00, v_chef);

  --------------------------------------------------------------------------------- TC-10
  -- …0022's two columns: money is numeric(12,2), never float (CLAUDE.md), and the reason is
  -- free text.
  select data_type, numeric_precision, numeric_scale into v_txt, v_prec, v_scale
    from information_schema.columns
   where table_schema = 'public' and table_name = 'lots' and column_name = 'smoke_fee_override_thb';
  assert v_txt = 'numeric' and v_prec = 12 and v_scale = 2,
    format('TC-10: lots.smoke_fee_override_thb is %s(%s,%s), expected numeric(12,2)', v_txt, v_prec, v_scale);

  select data_type into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'lots' and column_name = 'smoke_fee_override_reason';
  assert v_txt = 'text', format('TC-10: lots.smoke_fee_override_reason is %s, expected text', coalesce(v_txt, 'missing'));

  -- v_lot_cost's column contract — the one lane K builds v_cost_breakdown on (PLAN Doc deltas).
  select string_agg(want, ', '), count(*) into v_bad, v_n
    from unnest(array[
      'lot_id', 'lot_code', 'state', 'closed_at', 'priced_at', 'po_id', 'po_number',
      'foodiva_sent_weight_kg', 'meat_unit_price_thb_per_kg', 'meat_cost_thb',
      'brine_pct_of_meat', 'brine_cost_thb_per_kg', 'brine_rate_effective_from', 'brine_cost_thb',
      'smoke_fee_tier_id', 'smoke_fee_tier_effective_from', 'smoke_fee_rate_thb',
      'smoke_fee_rate_basis', 'smoke_fee_computed_thb', 'smoke_fee_override_thb',
      'smoke_fee_override_reason', 'smoke_fee_thb', 'smoke_fee_is_overridden',
      'freight_outbound_thb', 'freight_return_thb', 'freight_share_thb',
      'chef_house_frozen_kg', 'total_cost_thb', 'is_complete', 'missing_inputs']) as want
   where not exists (select 1 from information_schema.columns c
                      where c.table_schema = 'public' and c.table_name = 'v_lot_cost'
                        and c.column_name = want);
  assert v_n = 0, format('TC-10: v_lot_cost is missing %s column(s): %s', v_n, v_bad);

  -- Every money column is numeric — a float here is a satang that never reconciles.
  select string_agg(format('%s:%s', column_name, data_type), ', '), count(*) into v_bad, v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'v_lot_cost'
     and (column_name like '%\_thb' or column_name like '%\_thb\_per\_kg' or column_name like '%\_kg')
     and data_type <> 'numeric';
  assert v_n = 0, format('TC-10: %s v_lot_cost quantity column(s) are not numeric: %s', v_n, v_bad);

  select data_type into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'v_lot_cost' and column_name = 'is_complete';
  assert v_txt = 'boolean', format('TC-10: v_lot_cost.is_complete is %s', v_txt);

  select data_type into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'v_lot_cost' and column_name = 'missing_inputs';
  assert v_txt = 'ARRAY', format('TC-10: v_lot_cost.missing_inputs is %s, expected an array', v_txt);

  --------------------------------------------------------------------------------- TC-11
  -- R41: set together or not at all. Each half alone is a check_violation, and it is the pair
  -- constraint that fires, not some other one.
  v_ok := false; v_con := null;
  begin
    update lots set smoke_fee_override_thb = 100.00 where id = v_lot;
  exception when check_violation then
    get stacked diagnostics v_con = constraint_name;
    v_ok := v_con = 'lots_smoke_fee_override_pair';
  end;
  assert v_ok, format('TC-11: an amount with no reason got %s', coalesce(v_con, 'no violation at all'));

  v_ok := false; v_con := null;
  begin
    update lots set smoke_fee_override_reason = 'ส่วนลด' where id = v_lot;
  exception when check_violation then
    get stacked diagnostics v_con = constraint_name;
    v_ok := v_con = 'lots_smoke_fee_override_pair';
  end;
  assert v_ok, format('TC-11: a reason with no amount got %s', coalesce(v_con, 'no violation at all'));

  -- The floor: below zero is nothing, even with a reason.
  v_ok := false; v_con := null;
  begin
    update lots set smoke_fee_override_thb = -1.00, smoke_fee_override_reason = 'ส่วนลด'
     where id = v_lot;
  exception when check_violation then
    get stacked diagnostics v_con = constraint_name;
    v_ok := v_con = 'lots_smoke_fee_override_nonneg';
  end;
  assert v_ok, format('TC-11: a negative override got %s', coalesce(v_con, 'no violation at all'));

  -- A blank reason is not a reason.
  v_ok := false; v_con := null;
  begin
    update lots set smoke_fee_override_thb = 5.00, smoke_fee_override_reason = '   '
     where id = v_lot;
  exception when check_violation then
    get stacked diagnostics v_con = constraint_name;
    v_ok := v_con = 'lots_smoke_fee_override_reason_not_blank';
  end;
  assert v_ok, format('TC-11: a blank reason got %s', coalesce(v_con, 'no violation at all'));

  -- 0.00 with a reason is a free run and is accepted; both null is the ordinary lot.
  update lots set smoke_fee_override_thb = 0.00, smoke_fee_override_reason = 'ร้านรมควันให้ฟรี'
   where id = v_lot;
  select count(*) into v_n from lots
   where id = v_lot and smoke_fee_override_thb = 0.00;
  assert v_n = 1, 'TC-11: an override of 0.00 with a reason was not stored';

  update lots set smoke_fee_override_thb = null, smoke_fee_override_reason = null
   where id = v_lot;
  select count(*) into v_n from lots
   where id = v_lot and smoke_fee_override_thb is null and smoke_fee_override_reason is null;
  assert v_n = 1, 'TC-11: clearing both columns together was refused';

  --------------------------------------------------------------------------------- TC-12
  -- ^ref-64: one SELECT to authenticated on the view, nothing to anon.
  select string_agg(format('%s:%s', grantee, privilege_type), ', '), count(*) into v_bad, v_n
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'v_lot_cost'
     and grantee in ('anon', 'authenticated');
  assert v_n = 1 and v_bad = 'authenticated:SELECT',
    format('TC-12: v_lot_cost holds %s session-role grant(s): %s', v_n, v_bad);

  -- The RPC is callable by a session (sweep 1g's rule) and never by anon (1e).
  assert has_function_privilege('authenticated',
           'public.fn_set_smoke_fee_override(uuid, uuid, numeric, text)', 'EXECUTE'),
    'TC-12: authenticated cannot execute fn_set_smoke_fee_override';
  assert not has_function_privilege('anon',
           'public.fn_set_smoke_fee_override(uuid, uuid, numeric, text)', 'EXECUTE'),
    'TC-12: anon can execute fn_set_smoke_fee_override';

  -- R20: no session role can read the price columns on the base table.
  assert not has_column_privilege('authenticated', 'public.lots', 'smoke_fee_override_thb', 'SELECT')
     and not has_column_privilege('authenticated', 'public.lots', 'smoke_fee_override_reason', 'SELECT')
     and not has_column_privilege('anon', 'public.lots', 'smoke_fee_override_thb', 'SELECT')
     and not has_column_privilege('anon', 'public.lots', 'smoke_fee_override_reason', 'SELECT'),
    'TC-12: a session role holds SELECT on a smoke-fee override column of lots (R20)';

  raise exception 'COST_SCHEMA_TEST_PASSED';   -- the only clean way back out
end $$;
