-- Failure-case tests for card ^ref-12 — v_config_history, the OW 10 reader.
--
-- ^ref-11's tests prove the four setters write correctly. This one proves the screen reads
-- them, by exactly one role, and agrees with the resolver about what "current" means. Each
-- assert is a way the screen ships looking right and being wrong:
--
--   * the L1 gate is in the nav instead of the database, so an L2 or L3 who types the URL —
--     or calls PostgREST directly — reads every price in the system (TC-32, TC-33). R20 is
--     the rule; a hidden menu is not enforcement (ADR-004).
--   * the gate is so tight it locks the Owner out too, and "deny everyone" passes both deny
--     tests vacuously (TC-34)
--   * a screen reaches past the view to the table and the WHERE clause is decoration (TC-35)
--   * is_current disagrees with fn_config_value, so the screen shows a rate the engine is
--     not using — the one failure worse than showing no rate at all (TC-36)
--   * is_current is computed per source instead of per (source, item_key, scope), so a
--     branch override and the global default collapse into one and the deliberate one is
--     the one that disappears (TC-37)
--   * a future-dated row renders as the effective one, so the number on the screen stops
--     being the number in the ledger (TC-38)
--   * the band set is listed as N items, inviting an edit of one band that
--     fn_set_smoke_fee_tier will refuse — a gap is a property of the set (TC-39, D02, R37)
--   * a retry writes a second row (TC-40)
--   * a superseded row vanishes, and the append-only rule becomes invisible (TC-42)
--
-- TC-41 (CONFIG_DUPLICATE_DATE reaching the Owner as a Thai sentence) is Manual — it is a
-- property of the RPC wrapper and the screen, not of the database. The raise itself is
-- covered by config_writers_test.sql TC-16.
--
-- Covers TC-32 … TC-42 from v.0.1/ref-10-12-config-layer/TDD-config-layer.md.
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/config_screen_test.sql

do $$
declare
  v_owner   uuid := '11111111-1111-1111-1111-111111111111';
  v_l2      uuid := '22222222-2222-2222-2222-222222222222';
  v_l3      uuid := '33333333-3333-3333-3333-333333333333';
  v_branch  uuid;
  v_old     date := current_date - 200;
  v_new     date := current_date - 10;
  v_soon    date := current_date + 30;
  v_key     text := 'box_sale_price_thb';
  v_id_old  uuid;
  v_id_new  uuid;
  v_id_br   uuid;
  v_view_id uuid;
  v_res_id  uuid;
  v_n       bigint;
  v_bands   jsonb;
  v_display text;
  v_name    text;
  v_ok      boolean;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของกิจการ',    'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',       'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่', 'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind) values ('BR-TEST', 'สาขาทดสอบ', 'BRANCH')
    returning id into v_branch;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  -- Two global rows for one key, and a branch row that is OLDER than the newer global one.
  -- That last one is the whole point of TC-37: newest-wins would hide it.
  v_id_old := fn_set_config(gen_random_uuid(), v_key, v_old, p_value_numeric => 300.00);
  v_id_new := fn_set_config(gen_random_uuid(), v_key, v_new, p_value_numeric => 350.00);
  v_id_br  := fn_set_config(gen_random_uuid(), v_key, v_old, p_value_numeric => 320.00,
                            p_scope_location_id => v_branch);

  ----------------------------------------------------------------------- TC-32, the L3 gate
  -- The card's acceptance line. R20: an L3 session never reads a price, and it reads zero
  -- rows from the database rather than from a hidden nav item.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  select count(*) into v_n from v_config_history;
  assert v_n = 0, format('TC-32: an L3 session reads %s rows of v_config_history', v_n);

  ----------------------------------------------------------------------- TC-33, the L2 gate
  -- A branch admin never reads a price either — including the price scoped to their own
  -- branch, which is the one a "own branch" reading of R20 would leak.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  select count(*) into v_n from v_config_history;
  assert v_n = 0, format('TC-33: an L2 session reads %s rows of v_config_history', v_n);

  ------------------------------------------------------------------ TC-34, not deny-everyone
  -- Two passing deny tests prove nothing on their own: `where false` passes both.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_config_history
   where source = 'CONFIG' and item_key = v_key and is_current;
  assert v_n > 0, 'TC-34: the WHERE clause hid the Owner too — "deny everyone" is not the rule';

  ------------------------------------------------------- TC-36, the view agrees with the resolver
  -- Two definitions of "current" in one system is how a screen shows a price the engine is
  -- not using. Same key, same scope, same day: the same row id, or the screen is lying.
  select row_id into v_view_id from v_config_history
   where source = 'CONFIG' and item_key = v_key and scope_location_id is null and is_current;
  select (fn_config_value(v_key, current_date)).id into v_res_id;
  assert v_view_id = v_res_id, format(
    'TC-36: the view calls %s current, fn_config_value resolves %s', v_view_id, v_res_id);
  assert v_view_id = v_id_new, 'TC-36: the newer of the two past rows is not the current one';

  ------------------------------------------------------------ TC-37, scope does not collapse
  -- is_current partitioned per source instead of per (source, item_key, scope) yields ONE
  -- current row here — and the one it drops is the branch override somebody set on purpose.
  select count(*) into v_n from v_config_history
   where source = 'CONFIG' and item_key = v_key and is_current;
  assert v_n = 2, format(
    'TC-37: %s current row(s) for one key across two scopes — expected 2, one per scope', v_n);

  select row_id into v_view_id from v_config_history
   where source = 'CONFIG' and item_key = v_key and scope_location_id = v_branch and is_current;
  assert v_view_id = v_id_br,
    'TC-37: the branch row is not current — a newer global row hid a deliberate override';

  -- And the resolver makes the same call for that branch: scope beats recency (R12).
  select (fn_config_value(v_key, current_date, v_branch)).id into v_res_id;
  assert v_res_id = v_id_br, 'TC-37: the resolver and the view disagree about the branch row';

  -- scope_name_th is what the screen shows instead of a uuid.
  select scope_name_th into v_display from v_config_history where row_id = v_id_br;
  assert v_display = 'สาขาทดสอบ', format('TC-37: scope_name_th was %L', v_display);

  --------------------------------------------------------- TC-42, a superseded row stays readable
  -- The append-only rule is invisible unless the older row is reachable from the value.
  select is_current into v_ok from v_config_history where row_id = v_id_old;
  assert v_ok = false, 'TC-42: the superseded row is still flagged current';
  select value_display, created_by_name into v_display, v_name
    from v_config_history where row_id = v_id_old;
  assert v_display = '300.00', format('TC-42: the superseded row shows %L, not its own value', v_display);
  assert v_name = 'เจ้าของกิจการ', format('TC-42: created_by_name was %L', v_name);

  --------------------------------------------------------------- TC-38, a future row is not current
  -- The Owner enters next month's price today. Rendering it as effective makes the number
  -- on the screen stop being the number in the ledger.
  perform fn_set_config(gen_random_uuid(), 'brine_cost_thb_per_kg', v_soon, p_value_numeric => 45.00);

  select count(*) into v_n from v_config_history
   where item_key = 'brine_cost_thb_per_kg' and is_current;
  assert v_n = 0, format('TC-38: a future-dated row is flagged current (%s row(s))', v_n);

  select is_future into v_ok from v_config_history where item_key = 'brine_cost_thb_per_kg';
  assert v_ok, 'TC-38: a row dated next month is not flagged is_future';

  -- And the resolver refuses it, which is the behaviour the flag has to mirror.
  v_ok := false;
  begin
    perform fn_config_numeric('brine_cost_thb_per_kg', current_date);
  exception when others then
    v_ok := sqlerrm like 'CONFIG_NOT_SET%';
  end;
  assert v_ok, 'TC-38: the resolver did not raise CONFIG_NOT_SET for a future-only key';

  ------------------------------------------------------------------ TC-39, the tier set is one item
  -- Three bands, one item. Listing them as three invites editing one band alone, and a gap
  -- is a property of the set — fn_set_smoke_fee_tier refuses a partial write anyway.
  perform fn_set_smoke_fee_tier(gen_random_uuid(), v_old, jsonb_build_array(
    jsonb_build_object('min_weight_kg', 0,   'max_weight_kg', 100,  'rate_thb', 20, 'rate_basis', 'PER_KG'),
    jsonb_build_object('min_weight_kg', 100, 'max_weight_kg', 200,  'rate_thb', 18, 'rate_basis', 'PER_KG'),
    jsonb_build_object('min_weight_kg', 200, 'max_weight_kg', null, 'rate_thb', 15, 'rate_basis', 'PER_KG')
  ));

  select count(*) into v_n from v_config_history where source = 'SMOKE_FEE_TIER';
  assert v_n = 1, format('TC-39: a 3-band set became %s rows — the set is one item (D02)', v_n);

  select value_json, is_current into v_bands, v_ok
    from v_config_history where source = 'SMOKE_FEE_TIER';
  assert jsonb_array_length(v_bands) = 3, format(
    'TC-39: value_json carries %s band(s), expected 3', jsonb_array_length(v_bands));
  assert (v_bands -> 0 ->> 'min_weight_kg')::numeric = 0,
    'TC-39: the bands are not aggregated in min_weight_kg order — the screen reads the set '
    'in a different order from the one the validator walked';
  assert v_ok, 'TC-39: the only band set is not current';

  ------------------------------------------------------------- TC-40, a retry writes one row
  -- The same create form submitted twice with one idempotency key (R38, R4). The natural
  -- unique key is what carries this — there is no rpc_calls table.
  declare
    v_key_1 uuid := gen_random_uuid();
    v_a     uuid;
    v_b     uuid;
  begin
    v_a := fn_set_config(v_key_1, 'material_alert_ratio', v_new, p_value_numeric => 0.20);
    v_b := fn_set_config(v_key_1, 'material_alert_ratio', v_new, p_value_numeric => 0.20);
    assert v_a = v_b, 'TC-40: a retry returned a different id';
  end;

  select count(*) into v_n from v_config_history where item_key = 'material_alert_ratio';
  assert v_n = 1, format('TC-40: a retried submit wrote %s rows', v_n);

  ------------------------------------------------------------------- TC-35, no way around it
  -- The workaround. A screen that selects the tables directly must fail, or the WHERE
  -- clause above is decoration — and the view must still be readable as a real session,
  -- or the grant is missing and the screen is broken for the Owner too.
  set local role authenticated;

  foreach v_display in array array['config_settings', 'product_prices',
                                   'packaging_full_stock', 'smoke_fee_tiers'] loop
    v_ok := false;
    begin
      execute format('select 1 from %I limit 1', v_display);
    exception when others then
      v_ok := true;
    end;
    assert v_ok, format('TC-35: an authenticated session read %s directly (ADR-004)', v_display);
  end loop;

  v_ok := false;
  begin
    select count(*) into v_n from v_config_history;
    v_ok := true;
  exception when others then
    v_ok := false;
  end;
  assert v_ok, 'TC-35: authenticated cannot select v_config_history — the grant is missing';
  assert v_n > 0, 'TC-35: a real authenticated L1 session read 0 rows through the view';

  reset role;

  -- And no grant was quietly added to any of the four tables to make the above work.
  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name in ('config_settings', 'product_prices',
                        'packaging_full_stock', 'smoke_fee_tiers')
     and grantee in ('anon', 'authenticated');
  assert v_n = 0, format('TC-35: %s grant(s) were added on the config tables (ADR-004)', v_n);

  raise exception 'CONFIG_SCREEN_TEST_PASSED';   -- the only clean way back out
end $$;
