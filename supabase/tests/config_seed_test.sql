-- Failure-case tests for card ^ref-61 — the v0.2 config seed (migration …0024) and
-- v_config_readiness (views/190).
--
-- Assumes from unmerged lanes: nothing. If lane C's …0017 seeds products or lane D seeds
-- packaging_items, TC-19 and TC-20 deactivate those rows inside this aborted transaction.
--
-- Covers TC-01 … TC-28 from v.0.1/ref-61-config-seed/TDD-config-seed.md. Each assert is a way
-- the first-run gate lies:
--   * the seed invents an Owner number, and a figure nobody chose reads as settled (ADR-023,
--     ADR-006, BR23) — TC-03
--   * a seed row can be forged by a session, or a row can be stored with no author and no
--     reason for having none — TC-04 … TC-06
--   * the seed stops answering for the past once the Owner sets a value, and a closed period
--     moves (BR23) — TC-07
--   * "set" on the screen while the RPC still raises CONFIG_NOT_SET: a branch-only row counted
--     for a global key, a future row counted as in force, an empty catalogue read as fully
--     priced — TC-14 … TC-20
--   * L2 or L3 reads a value through the one config surface they are allowed (R20) — TC-11
--   * the gate becomes the enforcement, so deleting it lets an unset number through (R35) —
--     TC-23 … TC-25
--
-- Everything runs in one transaction that aborts on purpose. TC-21 closes the opening window,
-- which is permanent even inside a transaction, so it runs in its own sub-block and unwinds
-- (the opening_close_test.sql pattern).
-- Run:  psql "$DATABASE_URL" -f supabase/tests/config_seed_test.sql

do $$
declare
  v_owner   uuid := '61616161-6161-6161-6161-616161616101';
  v_l2      uuid := '61616161-6161-6161-6161-616161616102';
  v_l3      uuid := '61616161-6161-6161-6161-616161616103';
  v_gone    uuid := '61616161-6161-6161-6161-616161616104';
  v_central uuid;
  v_br_a    uuid;
  v_br_b    uuid;
  v_pack    uuid;
  v_p1      uuid;
  v_p2      uuid;
  v_id      uuid;
  v_by      uuid;
  v_seed    boolean;
  v_set     boolean;
  v_ok      boolean;
  v_err     text;
  v_txt     text;
  v_want    text;
  v_rows_l1 text;
  v_rows_l2 text;
  v_rows_l3 text;
  v_key     text;
  v_n       bigint;
  v_n2      bigint;
  v_n3      bigint;
  v_num     numeric;
  v_config_keys text[];
  v_block_keys  text[];
  v_seeded  text[] := array[
    'brine_pct_of_meat', 'rice_serving_weight_kg', 'chilli_paste_tube_weight_g',
    'chilli_paste_cost_thb_per_tube', 'receipt_variance_threshold_pct',
    'receipt_variance_requires_reason', 'partial_receipt_allowed',
    'yield_alert_threshold_pct', 'material_alert_ratio', 'unlock_max_days_back',
    'business_day_close_earliest', 'smoke_fee_tier_basis', 'business_day_shift_rule'];
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3), (v_gone);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',                'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',             'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',   'L3_CM_OPERATOR',  true),
    (v_gone,  'เจ้าของที่ปิดใช้',         'L1_OWNER',        false);

  -- Branches the readiness rules count. Any branch another card seeded is set aside for the
  -- length of this aborted transaction, so "every active branch" means exactly these two.
  update locations set is_active = false where kind = 'BRANCH';
  insert into locations (code, name_th, kind) values ('SEED-BRA', 'สาขาเอ', 'BRANCH')
    returning id into v_br_a;
  insert into locations (code, name_th, kind) values ('SEED-BRB', 'สาขาบี', 'BRANCH')
    returning id into v_br_b;
  insert into locations (code, name_th, kind) values ('SEED-CEN', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-01
  -- Exactly the thirteen keys PLAN-config-seed.md Finding 4 traces to v0.2, all dated
  -- 2000-01-01, global, and authored by nobody.
  select count(*) into v_n from config_settings where is_seed;
  assert v_n = 13, format('TC-01: expected 13 seed rows, found %s', v_n);

  select string_agg(key, ',' order by key) into v_txt from config_settings where is_seed;
  select string_agg(k, ',' order by k) into v_want from unnest(v_seeded) k;
  assert v_txt = v_want, format('TC-01: seeded keys are %s, expected %s', v_txt, v_want);

  select count(*) into v_n
    from config_settings
   where is_seed
     and (effective_from <> date '2000-01-01'
          or created_by is not null
          or scope_location_id is not null);
  assert v_n = 0,
    format('TC-01: %s seed row(s) are not global, undated-before-everything and authorless', v_n);

  --------------------------------------------------------------------------------- TC-02
  -- The values are v0.2's, stored in the house units: percentages as 20.00 meaning 20%, a
  -- ratio as 0.20 (R10), booleans as json (^ref-12 decision 4).
  assert (select value_numeric from config_settings where is_seed and key = 'brine_pct_of_meat') = 10.00,
    'TC-02: brine_pct_of_meat is not v0.2''s 10.00 (BR 02)';
  assert (select value_numeric from config_settings where is_seed and key = 'rice_serving_weight_kg') = 0.20,
    'TC-02: rice_serving_weight_kg is not v0.2''s 0.20 kg (BR 05)';
  assert (select value_numeric from config_settings where is_seed and key = 'chilli_paste_tube_weight_g') = 30,
    'TC-02: chilli_paste_tube_weight_g is not v0.2''s 30 g (BR 13)';
  assert (select value_numeric from config_settings where is_seed and key = 'chilli_paste_cost_thb_per_tube') = 15.00,
    'TC-02: chilli_paste_cost_thb_per_tube is not v0.2''s 15.00 (BR 13)';
  assert (select value_numeric from config_settings where is_seed and key = 'receipt_variance_threshold_pct') = 20.00,
    'TC-02: receipt_variance_threshold_pct is not 20.00 — a percentage stored as 0.20 is a 0.2% threshold (BR 12)';
  assert (select value_numeric from config_settings where is_seed and key = 'yield_alert_threshold_pct') = 20.00,
    'TC-02: yield_alert_threshold_pct is not 20.00 (BR 03)';
  assert (select value_numeric from config_settings where is_seed and key = 'material_alert_ratio') = 0.20,
    'TC-02: material_alert_ratio is not the ratio 0.20 (BR 20, R10)';
  assert (select value_numeric from config_settings where is_seed and key = 'unlock_max_days_back') = 3,
    'TC-02: unlock_max_days_back is not v0.2''s 3 days (BR 15)';
  assert (select value_text from config_settings where is_seed and key = 'business_day_close_earliest') = '21:00',
    'TC-02: business_day_close_earliest is not 21:00 (BR 21)';
  assert (select value_text from config_settings where is_seed and key = 'smoke_fee_tier_basis') = 'FOODIVA_DISPATCH',
    'TC-02: smoke_fee_tier_basis is not FOODIVA_DISPATCH (BR 10)';
  -- Through the resolvers the consumers actually call, not just the column.
  assert fn_config_boolean('receipt_variance_requires_reason', current_date),
    'TC-02: receipt_variance_requires_reason does not resolve to true (BR 12)';
  assert fn_config_boolean('partial_receipt_allowed', current_date),
    'TC-02: partial_receipt_allowed does not resolve to true (M2, UAT-07)';

  ------------------------------------------------------------------------ TC-03, no guessing
  -- THE CARD'S REASON TO EXIST, stated from the other side: nothing the readiness view lists
  -- as the Owner's to enter has a seed row, and neither do the deferred keys nor the two
  -- price keys product_prices superseded. A seeded Owner number is a settled-looking figure
  -- nobody chose (ADR-023, BR23).
  select array_agg(item_key) into v_config_keys
    from v_config_readiness where source = 'config_settings';
  select array_agg(item_key) into v_block_keys
    from v_config_readiness where source = 'config_settings' and severity = 'BLOCK';
  assert coalesce(array_length(v_block_keys, 1), 0) = 7,
    format('TC-03: expected 7 BLOCK config keys in the view, found %s — the check below would '
           'be vacuous', coalesce(array_length(v_block_keys, 1), 0));

  select string_agg(key, ', ' order by key) into v_txt
    from config_settings
   where is_seed
     and (key = any(v_config_keys)
          or key in ('line_man_gp_pct', 'corporate_tax_pct',
                     'box_sale_price_thb', 'addon_sealed_meat_price_thb',
                     'rice_sale_price_thb_per_kg', 'chilli_paste_sale_price_thb_per_tube'));
  assert v_txt is null, format('TC-03: the seed invented an Owner number for %s', v_txt);

  --------------------------------------------------------------------- TC-04 / TC-05, the pair
  -- The biconditional, from both sides. An authorless row that is not a seed is an
  -- unattributed rate; an authored row flagged as a seed is a forged requirement.
  v_ok := false;
  begin
    insert into config_settings (key, value_numeric, effective_from, created_by, is_seed)
         values ('tc04_orphan', 1, date '2026-01-01', null, false);
  exception when check_violation then
    v_ok := true;
  end;
  assert v_ok, 'TC-04: a row with no author and no seed flag was stored — a rate nobody set';

  v_ok := false;
  begin
    insert into config_settings (key, value_numeric, effective_from, created_by, is_seed)
         values ('tc05_forged', 1, date '2026-01-01', v_owner, true);
  exception when check_violation then
    v_ok := true;
  end;
  assert v_ok, 'TC-05: an authored row was stored as a seed — a person''s value passing as v0.2''s';

  --------------------------------------------------------------------------------- TC-06
  -- No RPC can write a seed: fn_set_config has no seed flag and no actor parameter, and what
  -- it writes is authored by the caller.
  select pg_get_function_arguments(p.oid) into v_txt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_set_config';
  assert v_txt not ilike '%seed%' and v_txt not ilike '%created_by%' and v_txt not ilike '%actor%',
    format('TC-06: fn_set_config exposes a seed or actor parameter: %s', v_txt);

  v_id := fn_set_config(gen_random_uuid(), 'tc06_key', date '2026-09-01', p_value_numeric => 1);
  select is_seed, created_by into v_seed, v_by from config_settings where id = v_id;
  assert not v_seed and v_by = v_owner,
    format('TC-06: fn_set_config wrote is_seed=%s created_by=%s', v_seed, v_by);

  --------------------------------------------------------------------------------- TC-07
  -- The Owner's row supersedes the seed from its own date, and the seed still answers for
  -- the days before it — a closed period keeps the number it had (BR23, R12).
  perform fn_set_config(gen_random_uuid(), 'unlock_max_days_back', date '2026-09-01',
                        p_value_numeric => 5);
  v_num := fn_config_numeric('unlock_max_days_back', date '2026-09-10');
  assert v_num = 5, format('TC-07: the Owner''s 5 did not supersede the seed (%s)', v_num);
  v_num := fn_config_numeric('unlock_max_days_back', date '2026-08-31');
  assert v_num = 3, format('TC-07: the Owner''s row reached back before its own date (%s)', v_num);

  --------------------------------------------------------------------------------- TC-08
  -- Dated before any transaction: a date years before go-live still resolves.
  v_num := fn_config_numeric('yield_alert_threshold_pct', date '2020-01-01');
  assert v_num = 20.00, format('TC-08: the seed does not answer for 2020-01-01 (%s)', v_num);

  --------------------------------------------------------------------------------- TC-09
  -- The requirement list, exactly: 10 BLOCK + 8 WARN (PLAN-config-seed.md Finding 5).
  select string_agg(item_key, ',' order by item_key) into v_txt from v_config_readiness;
  select string_agg(k, ',' order by k) into v_want from unnest(array[
    'smoke_fee_tiers', 'avg_pack_weight_kg', 'product_prices', 'brine_cost_thb_per_kg',
    'freight_thb_by_vehicle_type', 'freight_alloc_method', 'full_stock_qty',
    'receipt_variance_settlement_method', 'opening_cutoff_date', 'unlock_window_hours',
    'opening_balances_open', 'alert_recipients', 'alert_enabled',
    'central_warehouse_keeper_ids', 'vehicle_schedule', 'material_reorder_point_qty',
    'material_days_of_cover_target', 'product_costs']) k;
  assert v_txt = v_want, format('TC-09: the view lists %s, expected %s', v_txt, v_want);

  --------------------------------------------------------------------------------- TC-10
  select count(*) filter (where severity = 'BLOCK'),
         count(*) filter (where severity = 'WARN'),
         count(*) filter (where severity not in ('BLOCK', 'WARN')
                             or label_th is null or feature is null or gates_th is null
                             or affects_roles is null or is_set is null)
    into v_n, v_n2, v_n3
    from v_config_readiness;
  assert v_n = 10 and v_n2 = 8 and v_n3 = 0,
    format('TC-10: %s BLOCK, %s WARN, %s malformed row(s); expected 10, 8, 0', v_n, v_n2, v_n3);

  ------------------------------------------------------------------- TC-11, no value column
  -- The whole reason all three roles may read this view (ADR-023, R20).
  select string_agg(column_name || ':' || data_type, ', ') into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'v_config_readiness'
     and (data_type in ('numeric', 'jsonb', 'json', 'money', 'double precision', 'real')
          or (data_type = 'boolean' and column_name <> 'is_set')
          or column_name like 'value%');
  assert v_txt is null, format('TC-11: v_config_readiness exposes a value column: %s', v_txt);

  ------------------------------------------------------------ TC-12, one list for every role
  select string_agg(item_key || '=' || is_set::text, ',' order by sort_order)
    into v_rows_l1 from v_config_readiness;
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  select string_agg(item_key || '=' || is_set::text, ',' order by sort_order)
    into v_rows_l2 from v_config_readiness;
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  select string_agg(item_key || '=' || is_set::text, ',' order by sort_order)
    into v_rows_l3 from v_config_readiness;
  assert v_rows_l1 is not null and v_rows_l1 = v_rows_l2 and v_rows_l2 = v_rows_l3,
    format('TC-12: the roles read different lists — L1 %s | L2 %s | L3 %s',
           v_rows_l1, v_rows_l2, v_rows_l3);

  --------------------------------------------------------- TC-13, deactivated and anonymous
  perform set_config('request.jwt.claims', json_build_object('sub', v_gone)::text, true);
  select count(*) into v_n from v_config_readiness;
  assert v_n = 0, format('TC-13: a deactivated profile reads %s readiness row(s) (R31)', v_n);
  assert not has_table_privilege('anon', 'public.v_config_readiness', 'select'),
    'TC-13: anon holds SELECT on v_config_readiness';
  assert has_table_privilege('authenticated', 'public.v_config_readiness', 'select'),
    'TC-13: authenticated cannot select v_config_readiness — the grant is missing';

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  ------------------------------------------------------------------ TC-14, global key flips
  delete from config_settings where key = 'avg_pack_weight_kg';
  select is_set into v_set from v_config_readiness where item_key = 'avg_pack_weight_kg';
  assert not v_set, 'TC-14: avg_pack_weight_kg reads set with no row';
  insert into config_settings (key, value_numeric, effective_from, created_by)
       values ('avg_pack_weight_kg', 0.10, current_date, v_owner);
  select is_set into v_set from v_config_readiness where item_key = 'avg_pack_weight_kg';
  assert v_set, 'TC-14: avg_pack_weight_kg reads unset with a row in force today';

  ------------------------------------------------------------ TC-15, future is not in force
  delete from config_settings where key = 'brine_cost_thb_per_kg';
  insert into config_settings (key, value_numeric, effective_from, created_by)
       values ('brine_cost_thb_per_kg', 25.00, current_date + 7, v_owner);
  select is_set into v_set from v_config_readiness where item_key = 'brine_cost_thb_per_kg';
  assert not v_set,
    'TC-15: a row dated next week reads as set — today''s lot cost still raises CONFIG_NOT_SET';

  -------------------------------------------------- TC-16, a branch row is not a global set
  delete from config_settings where key = 'opening_cutoff_date';
  insert into config_settings (key, scope_location_id, value_text, effective_from, created_by)
       values ('opening_cutoff_date', v_br_a, '2026-10-01', current_date - 1, v_owner);
  select is_set into v_set from v_config_readiness where item_key = 'opening_cutoff_date';
  assert not v_set,
    'TC-16: a branch-only row reads as set for a global key — a global lookup never picks a '
    'branch row (R36), so the opening path still raises';

  ---------------------------------------------------------- TC-17, one source for a price
  -- Lane C's fn_record_sales prices every SKU — rice and chilli included — from
  -- product_prices and reads no sale-price config key (fn_record_sales.sql:228). A readiness
  -- row for one of those keys would send the Owner to set a number that unblocks nothing,
  -- and would be a BLOCK row with no CONFIG_NOT_SET behind it (R35).
  select count(*) into v_n from v_config_readiness
   where item_key in ('box_sale_price_thb', 'addon_sealed_meat_price_thb',
                      'rice_sale_price_thb_per_kg', 'chilli_paste_sale_price_thb_per_tube');
  assert v_n = 0,
    format('TC-17: %s sale-price config key(s) are listed — prices live in product_prices', v_n);
  select count(*) into v_n from v_config_readiness
   where item_key = 'product_prices' and severity = 'BLOCK';
  assert v_n = 1, 'TC-17: product_prices is not the BLOCK row for selling prices';

  ------------------------------------------------------------------------ TC-18, tier set
  delete from smoke_fee_tiers;
  select is_set into v_set from v_config_readiness where item_key = 'smoke_fee_tiers';
  assert not v_set, 'TC-18: the smoke fee reads set with no band';
  perform fn_set_smoke_fee_tier(gen_random_uuid(), current_date, jsonb_build_array(
    jsonb_build_object('min_weight_kg', 0, 'max_weight_kg', null,
                       'rate_thb', 2000, 'rate_basis', 'PER_KG')));
  select is_set into v_set from v_config_readiness where item_key = 'smoke_fee_tiers';
  assert v_set, 'TC-18: one [0, ∞) PER_KG set in force reads unset (ADR-024)';

  ------------------------------------------------------------------ TC-19, product prices
  update products set is_active = false;
  select is_set into v_set from v_config_readiness where item_key = 'product_prices';
  assert not v_set,
    'TC-19: an empty product catalogue reads as fully priced — vacuous truth, R9''s failure';

  insert into products (code, name_th, item_type, sale_unit)
       values ('SEED-P1', 'กล่องเนื้อรมควัน', 'SMOKED_MEAT', 'box') returning id into v_p1;
  insert into products (code, name_th, item_type, sale_unit)
       values ('SEED-P2', 'Add-on เนื้อซีล', 'SMOKED_MEAT', 'bag') returning id into v_p2;
  insert into product_prices (product_id, price_thb, effective_from, created_by)
       values (v_p1, 350.00, current_date, v_owner);
  select is_set into v_set from v_config_readiness where item_key = 'product_prices';
  assert not v_set, 'TC-19: one of two products priced reads as set — a sale of the other raises';

  insert into product_prices (product_id, price_thb, effective_from, created_by)
       values (v_p2, 320.00, current_date, v_owner);
  select is_set into v_set from v_config_readiness where item_key = 'product_prices';
  assert v_set, 'TC-19: every active product priced still reads unset';

  ------------------------------------------------------------------------ TC-20, full stock
  update packaging_items set is_active = false;
  select is_set into v_set from v_config_readiness where item_key = 'full_stock_qty';
  assert not v_set, 'TC-20: no packaging item at all reads as "every full stock set"';

  insert into packaging_items (code, name_th, unit) values ('SEED-BOX', 'กล่องสกรีน', 'ใบ')
    returning id into v_pack;
  select is_set into v_set from v_config_readiness where item_key = 'full_stock_qty';
  assert not v_set, 'TC-20: an item with no full-stock row reads as set';

  insert into packaging_full_stock (packaging_item_id, location_id, full_stock_qty, effective_from, created_by)
       values (v_pack, v_br_a, 500, current_date, v_owner);
  select is_set into v_set from v_config_readiness where item_key = 'full_stock_qty';
  assert not v_set, 'TC-20: branch A''s row reads as set while branch B has none and no global row';

  insert into packaging_full_stock (packaging_item_id, location_id, full_stock_qty, effective_from, created_by)
       values (v_pack, null, 500, current_date, v_owner);
  select is_set into v_set from v_config_readiness where item_key = 'full_stock_qty';
  assert v_set, 'TC-20: a global full-stock row reads unset';

  ------------------------------------------------------- TC-26, non-meat product costs (WARN)
  -- Lane K's row (PLAN-reporting Finding 6): a rice or water product whose CURRENT price row
  -- has no cost makes the P&L incomplete. Meat is costed by its lot (R30) and chilli by the
  -- seeded config key (BR13), so neither is asked — only the two meat SKUs are active here.
  select is_set into v_set from v_config_readiness where item_key = 'product_costs';
  assert v_set, 'TC-26: with only meat products active, the product-cost WARN reads unset';

  insert into products (code, name_th, item_type, sale_unit, is_stock_tracked)
       values ('SEED-RICE', 'ข้าวเหนียว', 'COOKED_RICE', 'kg', false) returning id into v_id;
  insert into product_prices (product_id, price_thb, cost_thb, effective_from, created_by)
       values (v_id, 60.00, 18.00, current_date - 2, v_owner),
              (v_id, 60.00, null,  current_date - 1, v_owner);
  select is_set into v_set from v_config_readiness where item_key = 'product_costs';
  assert not v_set,
    'TC-26: an older row''s cost was read as today''s — the current rice price carries none';

  insert into product_prices (product_id, price_thb, cost_thb, effective_from, created_by)
       values (v_id, 60.00, 20.00, current_date, v_owner);
  select is_set into v_set from v_config_readiness where item_key = 'product_costs';
  assert v_set, 'TC-26: a rice price with a cost in force today still reads uncosted';

  insert into products (code, name_th, item_type, sale_unit)
       values ('SEED-CHILLI', 'น้ำพริก', 'CHILLI_PASTE', 'tube');
  select is_set into v_set from v_config_readiness where item_key = 'product_costs';
  assert v_set,
    'TC-26: an uncosted chilli product was asked for a cost — its only home is the config key';

  ------------------------------------------------------------------------ TC-21, opening WARN
  -- The close is permanent even inside this transaction, so it happens in a sub-block that
  -- unwinds to its implicit savepoint. Asserts are ASSERT_FAILURE, which WHEN OTHERS does not
  -- catch, so a failing one still fails the file.
  begin
    select is_set into v_set from v_config_readiness where item_key = 'opening_balances_open';
    assert not v_set,
      'TC-21: the opening WARN reads set while the window is open — an unlocked ledger nobody '
      'is told about (ADR-021)';
    perform fn_close_opening_balances(gen_random_uuid());
    select is_set into v_set from v_config_readiness where item_key = 'opening_balances_open';
    assert v_set, 'TC-21: the opening WARN still reads unset after the close';
    raise exception 'ROLLBACK_TC21';
  exception when others then
    if sqlerrm not like '%ROLLBACK_TC21%' then raise; end if;
  end;
  select count(*) into v_n from opening_balance_close;
  assert v_n = 0, 'TC-21: the close survived its sub-block — every later case runs shut';

  ------------------------------------------------------------ TC-22, seeded keys are not asked
  select count(*) into v_n from v_config_readiness where item_key = any(v_seeded);
  assert v_n = 0,
    format('TC-22: %s seeded key(s) are still listed as the Owner''s to enter', v_n);

  ------------------------------------------------- TC-23, the gate is not the enforcement (R35)
  -- Take every row for every BLOCK config key away — including any a later seed might add —
  -- and every one of them must still refuse through the primitive each consumer calls.
  delete from config_settings where key = any(v_block_keys);
  foreach v_key in array v_block_keys loop
    v_ok := false; v_err := null;
    begin
      perform fn_config_value(v_key, current_date);
    exception when others then
      v_err := sqlerrm;
      v_ok  := v_err like '%CONFIG_NOT_SET%';
    end;
    assert v_ok,
      format('TC-23: BLOCK key %s did not raise CONFIG_NOT_SET with no row — delete the gate and '
             'it would be guessed (R35): %s', v_key, coalesce(v_err, 'no exception at all'));
  end loop;

  --------------------------------------------------------- TC-24, built consumer: opening path
  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'PACKAGING', v_central, 10,
                                      current_date, p_packaging_item_id => v_pack);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_NOT_SET%';
  end;
  assert v_ok,
    format('TC-24: an opening row was dated with no opening_cutoff_date set (R35, R46): %s',
           coalesce(v_err, 'no exception at all'));

  ------------------------------------------------------ TC-25, built consumer: transport run
  v_ok := false; v_err := null;
  begin
    perform fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', current_date);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_NOT_SET%';
  end;
  assert v_ok,
    format('TC-25: a run was created with no freight_alloc_method set (R35, D04.1): %s',
           coalesce(v_err, 'no exception at all'));

  ------------------------------------------------ TC-27, the Owner-run packaging seed: refusals
  -- The seven BR 08 materials arrive by the Owner's hand from /owner/setup, never from a
  -- migration the harness applies — that would switch on lane C's MATERIAL_COUNT_INCOMPLETE
  -- for every test (PLAN-config-seed.md Finding 10).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_seed_packaging_items(gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-27: an L2 seeded the material catalogue (%s)',
                      coalesce(v_err, 'no exception at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_seed_packaging_items(null);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%IDEMPOTENCY_KEY_REQUIRED%';
  end;
  assert v_ok, format('TC-27: a keyless seed call was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------- TC-28, seven rows, idempotent, retired stays so
  -- One of the seven already exists, retired and renamed by the Owner. The seed must not
  -- revive it or overwrite the name.
  insert into packaging_items (code, name_th, unit, is_active)
       values ('PKG_LINER', 'กระดาษรองแบบเก่า', 'แผ่น', false);

  v_n := fn_seed_packaging_items(gen_random_uuid());
  assert v_n = 7, format('TC-28: the seed reports %s of the seven codes, expected 7', v_n);

  select count(*) into v_n2 from packaging_items
   where code = any(array['PKG_SCREEN_BOX', 'PKG_LINER', 'PKG_ZIP_MEAT', 'PKG_ZIP_RICE',
                          'PKG_PAPER_BAG', 'PKG_LOGO_STICKER', 'PKG_REHEAT_CARD']);
  assert v_n2 = 7, format('TC-28: %s rows for the seven codes, expected 7', v_n2);

  select is_active, name_th into v_seed, v_txt from packaging_items where code = 'PKG_LINER';
  assert not v_seed and v_txt = 'กระดาษรองแบบเก่า',
    format('TC-28: the seed revived or renamed a material the Owner retired (active=%s, %s)',
           v_seed, v_txt);

  -- The retry: same answer, nothing written (R4, R38).
  v_n := fn_seed_packaging_items(gen_random_uuid());
  select count(*) into v_n2 from packaging_items
   where code = any(array['PKG_SCREEN_BOX', 'PKG_LINER', 'PKG_ZIP_MEAT', 'PKG_ZIP_RICE',
                          'PKG_PAPER_BAG', 'PKG_LOGO_STICKER', 'PKG_REHEAT_CARD']);
  assert v_n = 7 and v_n2 = 7,
    format('TC-28: a replay returned %s and left %s rows — expected 7 and 7', v_n, v_n2);

  raise exception 'CONFIG_SEED_TEST_PASSED';   -- the only clean way back out
end $$;
