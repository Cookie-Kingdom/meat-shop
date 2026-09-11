-- Failure-case tests for card ^ref-11 — the four config setters.
--
-- Covers TC-11 … TC-28 and TC-31 from TDD-config-layer.md.
--
-- Each assert is a way a rate change fails silently rather than loudly:
--   * an L2 or a deactivated Owner writes a rate, and the audit trail names them as
--     entitled to (ADR-004, R31)
--   * created_by is a parameter, so a rate change can be signed as somebody else
--   * a setter updates instead of inserting, and last month's closed P&L moves (BR23)
--   * a retry from a dropped connection writes a second row, or raises so the client
--     retries forever (R4)
--   * a same-day correction lands on top of the original with no trace
--   * a band set is stored with a gap, an overlap, or no open top band, and a dispatch
--     falls off the fee table as a silent zero (D02, BR10)
--   * a second GLOBAL full-stock row is stored for one date, because NULLs are distinct in
--     the unique index, and resolution turns on physical row order
--   * a zero full-stock level is stored and becomes a divisor (R9)
--   * this card quietly grants a session SELECT on a price table (ADR-004, R20)
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/config_writers_test.sql

do $$
declare
  v_owner  uuid := '77777777-7777-7777-7777-777777777781';
  v_l2     uuid := '77777777-7777-7777-7777-777777777782';
  v_gone   uuid := '77777777-7777-7777-7777-777777777783';
  v_branch uuid;
  v_prod   uuid;
  v_item   uuid;
  v_id     uuid;
  v_again  uuid;
  v_by     uuid;
  v_n      bigint;
  v_num    numeric;
  v_txt    text;
  v_bands  jsonb;
  v_ok     boolean;
  v_err    text;
  v_k      uuid := gen_random_uuid();
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_gone);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',        'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',     'L2_BRANCH_ADMIN', true),
    (v_gone,  'เจ้าของที่ปิดใช้', 'L1_OWNER',        false);

  insert into locations (code, name_th, kind) values ('BRC', 'สาขาซี', 'BRANCH')
    returning id into v_branch;
  insert into products (code, name_th, item_type, sale_unit)
       values ('BOX', 'กล่องเนื้อรมควัน', 'SMOKED_MEAT', 'box') returning id into v_prod;
  insert into packaging_items (code, name_th, unit)
       values ('BAG', 'ถุงสุญญากาศ', 'ใบ') returning id into v_item;

  -- ^ref-61: migration …0024 seeds brine_pct_of_meat and rice_serving_weight_kg at
  -- 2000-01-01. TC-11, TC-14, TC-15 and TC-16 count or select those keys' rows, so the seed
  -- rows are taken out of this aborted transaction to restore the baseline the cases were
  -- written against. No assert is changed.
  delete from config_settings where is_seed;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-11
  -- L1 only, and the check is in the function body: these are SECURITY DEFINER, so RLS
  -- does not apply inside them and there is no policy to consult (ADR-002, ADR-004).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  v_ok := false;
  begin
    perform fn_set_config(gen_random_uuid(), 'brine_pct_of_meat', date '2026-01-01',
                          p_value_numeric => 10);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-11: an L2 session was not refused (%s)',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from config_settings where key = 'brine_pct_of_meat';
  assert v_n = 0, format('TC-11: the refused L2 call still wrote %s row(s)', v_n);

  --------------------------------------------------------------------------------- TC-12
  -- A deactivated Owner holding a live JWT is NO_ACTOR, not FORBIDDEN — the distinction is
  -- what whoever reads the error needs (R31).
  perform set_config('request.jwt.claims', json_build_object('sub', v_gone)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_set_config(gen_random_uuid(), 'brine_pct_of_meat', date '2026-01-01',
                          p_value_numeric => 10);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%NO_ACTOR%';
  end;
  assert v_ok, format('TC-12: a deactivated Owner was not refused by name (%s)',
                      coalesce(v_err, 'no exception at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-13
  -- created_by is resolved inside the function and is not a parameter. A rate change is
  -- the thing the audit trail exists for.
  v_id := fn_set_config(gen_random_uuid(), 'brine_pct_of_meat', date '2026-01-01',
                        p_value_numeric => 10);
  select created_by into v_by from config_settings where id = v_id;
  assert v_by = v_owner, format('TC-13: created_by is %s, expected the caller %s', v_by, v_owner);

  select string_agg(p.proname || '(' || pg_get_function_arguments(p.oid) || ')', '; ')
    into v_txt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_set_config', 'fn_set_smoke_fee_tier',
                       'fn_set_product_price', 'fn_set_packaging_full_stock')
     and (pg_get_function_arguments(p.oid) ilike '%created_by%'
       or pg_get_function_arguments(p.oid) ilike '%actor%');
  assert v_txt is null, format('TC-13: a setter exposes an actor parameter: %s', v_txt);

  --------------------------------------------------------------------------------- TC-14
  -- A second date is a second row. No setter issues an UPDATE, ever, so the January row
  -- is still there and still resolves for January (ADR-006).
  perform fn_set_config(gen_random_uuid(), 'brine_pct_of_meat', date '2026-06-01',
                        p_value_numeric => 12);
  select count(*) into v_n from config_settings where key = 'brine_pct_of_meat';
  assert v_n = 2, format('TC-14: expected 2 dated rows, found %s', v_n);

  v_num := fn_config_numeric('brine_pct_of_meat', date '2026-03-01');
  assert v_num = 10, format('TC-14: the January row now reads %s', v_num);

  --------------------------------------------------------------------------------- TC-15
  -- The retry. Same key, scope, date and value: one row, the original id back, no error.
  -- Raising here would make a client with a dropped connection retry forever.
  v_k     := gen_random_uuid();
  v_id    := fn_set_config(v_k, 'rice_serving_weight_kg', date '2026-01-01',
                           p_value_numeric => 0.20);
  v_again := fn_set_config(v_k, 'rice_serving_weight_kg', date '2026-01-01',
                           p_value_numeric => 0.20);
  assert v_id = v_again, format('TC-15: the retry returned %s, expected %s', v_again, v_id);
  select count(*) into v_n from config_settings where key = 'rice_serving_weight_kg';
  assert v_n = 1, format('TC-15: the retry wrote a second row (%s rows)', v_n);

  --------------------------------------------------------------------------------- TC-16
  -- A different value on the same date is a correction, not a retry, and append-only has
  -- no answer for one. Refusing is the safe direction; it is also an Open Question.
  v_ok := false; v_err := null;
  begin
    perform fn_set_config(gen_random_uuid(), 'rice_serving_weight_kg', date '2026-01-01',
                          p_value_numeric => 0.25);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_DUPLICATE_DATE%';
  end;
  assert v_ok, format('TC-16: a same-day correction was not refused (%s)',
                      coalesce(v_err, 'no exception at all'));

  select value_numeric into v_num from config_settings where key = 'rice_serving_weight_kg';
  assert v_num = 0.20, format('TC-16: the original value is now %s', v_num);

  --------------------------------------------------------------------------------- TC-17
  -- Two values in one row. config_settings_one_value catches it too, by constraint name;
  -- the function catches it first and says which two arrived.
  v_ok := false; v_err := null;
  begin
    perform fn_set_config(gen_random_uuid(), 'smoke_fee_tier_basis', date '2026-01-01',
                          p_value_numeric => 1, p_value_text => 'FOODIVA_DISPATCH');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_ONE_VALUE%';
  end;
  assert v_ok, format('TC-17: two values were not refused by name (%s)',
                      coalesce(v_err, 'no exception at all'));

  -- ...and none at all is the same failure from the other side.
  v_ok := false; v_err := null;
  begin
    perform fn_set_config(gen_random_uuid(), 'smoke_fee_tier_basis', date '2026-01-01');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_ONE_VALUE%';
  end;
  assert v_ok, format('TC-17: a valueless row was not refused by name (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-18
  -- A gap. Nothing prices a 120 kg dispatch, and no row may be written.
  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01', '[
      {"min_weight_kg": 0,   "max_weight_kg": 100,  "rate_thb": 12, "rate_basis": "PER_KG"},
      {"min_weight_kg": 150, "max_weight_kg": null, "rate_thb": 10, "rate_basis": "PER_KG"}]'::jsonb);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%TIER_GAP%';
  end;
  assert v_ok, format('TC-18: a band gap was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));
  select count(*) into v_n from smoke_fee_tiers;
  assert v_n = 0, format('TC-18: the refused set wrote %s row(s)', v_n);

  --------------------------------------------------------------------------------- NS-07
  -- ^fix-numeric-scale. smoke_fee_tiers.rate_thb is numeric(12,2): 12.005 is refused by name,
  -- not stored as 12.01, and the refused set writes nothing.
  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01', '[
      {"min_weight_kg": 0, "max_weight_kg": null, "rate_thb": 12.005, "rate_basis": "PER_KG"}]'::jsonb);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like 'TOO_MANY_DECIMALS: band 1 rate_thb is 12.005 %';
  end;
  assert v_ok, format('NS-07: a 12.005 THB rate got %s', coalesce(v_err, 'no exception at all'));
  select count(*) into v_n from smoke_fee_tiers;
  assert v_n = 0, format('NS-07: the refused set wrote %s row(s)', v_n);

  --------------------------------------------------------------------------------- TC-19
  -- An overlap. Two bands price 90 kg and nothing says which wins.
  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01', '[
      {"min_weight_kg": 0,  "max_weight_kg": 100,  "rate_thb": 12, "rate_basis": "PER_KG"},
      {"min_weight_kg": 80, "max_weight_kg": null, "rate_thb": 10, "rate_basis": "PER_KG"}]'::jsonb);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%TIER_OVERLAP%';
  end;
  assert v_ok, format('TC-19: a band overlap was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-20
  -- Not anchored at zero. A 5 kg dispatch would have no band at all.
  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01', '[
      {"min_weight_kg": 10,  "max_weight_kg": 100,  "rate_thb": 12, "rate_basis": "PER_KG"},
      {"min_weight_kg": 100, "max_weight_kg": null, "rate_thb": 10, "rate_basis": "PER_KG"}]'::jsonb);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%TIER_NOT_ANCHORED%';
  end;
  assert v_ok, format('TC-20: an unanchored set was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-21
  -- A closed top band. A 250 kg dispatch must never fall off the fee table as a zero.
  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01', '[
      {"min_weight_kg": 0,   "max_weight_kg": 100, "rate_thb": 12, "rate_basis": "PER_KG"},
      {"min_weight_kg": 100, "max_weight_kg": 200, "rate_thb": 10, "rate_basis": "PER_KG"}]'::jsonb);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%TIER_NOT_OPEN_ENDED%';
  end;
  assert v_ok, format('TC-21: a closed top band was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-22
  -- All or nothing. The first two bands are valid; the third overlaps. Zero rows land.
  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01', '[
      {"min_weight_kg": 0,   "max_weight_kg": 100,  "rate_thb": 12, "rate_basis": "PER_KG"},
      {"min_weight_kg": 100, "max_weight_kg": 200,  "rate_thb": 10, "rate_basis": "PER_KG"},
      {"min_weight_kg": 150, "max_weight_kg": null, "rate_thb": 8,  "rate_basis": "PER_KG"}]'::jsonb);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%TIER_OVERLAP%';
  end;
  assert v_ok, format('TC-22: an invalid third band was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));
  select count(*) into v_n from smoke_fee_tiers;
  assert v_n = 0, format('TC-22: a partially valid set wrote %s row(s)', v_n);

  -- An unrecognised rate basis is a typo, not a default.
  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01', '[
      {"min_weight_kg": 0, "max_weight_kg": null, "rate_thb": 12, "rate_basis": "PER_TONNE"}]'::jsonb);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%TIER_RATE_BASIS%';
  end;
  assert v_ok, format('TC-22: rate_basis PER_TONNE was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-23
  -- The valid set, and the boundary. Bands are half-open [min, max): exactly 100.00 kg is
  -- priced by the SECOND band, 99.99 by the first. ^ref-29 inherits this rule from the
  -- shape of the data rather than re-deciding it.
  v_bands := '[
    {"min_weight_kg": 0,   "max_weight_kg": 100,  "rate_thb": 12, "rate_basis": "PER_KG"},
    {"min_weight_kg": 100, "max_weight_kg": null, "rate_thb": 10, "rate_basis": "PER_KG"}]'::jsonb;
  assert fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01', v_bands) = 2,
    'TC-23: the valid set did not report two bands';

  select count(*) into v_n from smoke_fee_tiers
   where effective_from = date '2026-01-01'
     and min_weight_kg <= 100.00
     and (max_weight_kg is null or max_weight_kg > 100.00);
  assert v_n = 1, format('TC-23: %s band(s) price exactly 100.00 kg, expected 1', v_n);

  select min_weight_kg into v_num from smoke_fee_tiers
   where effective_from = date '2026-01-01'
     and min_weight_kg <= 100.00
     and (max_weight_kg is null or max_weight_kg > 100.00);
  assert v_num = 100.00, format('TC-23: 100.00 kg landed in the band starting at %s', v_num);

  select min_weight_kg into v_num from smoke_fee_tiers
   where effective_from = date '2026-01-01'
     and min_weight_kg <= 99.99
     and (max_weight_kg is null or max_weight_kg > 99.99);
  assert v_num = 0.00, format('TC-23: 99.99 kg landed in the band starting at %s', v_num);

  -- The same set again is a retry: no second copy, no error.
  assert fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01', v_bands) = 2,
    'TC-23: the replayed set did not return cleanly';
  select count(*) into v_n from smoke_fee_tiers where effective_from = date '2026-01-01';
  assert v_n = 2, format('TC-23: the replay left %s rows at that date', v_n);

  -- A different set on the same date is a correction, and there is no answer for one.
  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01', '[
      {"min_weight_kg": 0, "max_weight_kg": null, "rate_thb": 99, "rate_basis": "FLAT"}]'::jsonb);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_DUPLICATE_DATE%';
  end;
  assert v_ok, format('TC-23: a same-day band-set correction was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-24
  -- A new set at a new date leaves the old one complete. Nothing is closed off, because
  -- closing a row off means updating it (ADR-006).
  perform fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-06-01', '[
    {"min_weight_kg": 0,   "max_weight_kg": 120,  "rate_thb": 14, "rate_basis": "PER_KG"},
    {"min_weight_kg": 120, "max_weight_kg": null, "rate_thb": 11, "rate_basis": "PER_KG"}]'::jsonb);

  select count(*) into v_n from smoke_fee_tiers where effective_from = date '2026-01-01';
  assert v_n = 2, format('TC-24: the January set now has %s bands', v_n);

  -- Resolving for March still reads the January set, whole.
  select rate_thb into v_num
    from smoke_fee_tiers
   where effective_from = (select max(effective_from) from smoke_fee_tiers
                            where effective_from <= date '2026-03-01')
     and min_weight_kg <= 150 and (max_weight_kg is null or max_weight_kg > 150);
  assert v_num = 10, format('TC-24: a March dispatch priced at %s, expected the January 10', v_num);

  --------------------------------------------------------------------------------- TC-25
  -- The price setter. Same date, different price → refused. Different date → two rows.
  v_id := fn_set_product_price(gen_random_uuid(), v_prod, date '2026-01-01', 350.00);
  v_ok := false; v_err := null;
  begin
    perform fn_set_product_price(gen_random_uuid(), v_prod, date '2026-01-01', 360.00);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_DUPLICATE_DATE%';
  end;
  assert v_ok, format('TC-25: a same-day price correction was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  v_again := fn_set_product_price(gen_random_uuid(), v_prod, date '2026-01-01', 350.00);
  assert v_id = v_again, 'TC-25: the price retry did not return the original id';

  perform fn_set_product_price(gen_random_uuid(), v_prod, date '2026-06-01', 380.00);
  select count(*) into v_n from product_prices where product_id = v_prod;
  assert v_n = 2, format('TC-25: expected 2 dated prices, found %s', v_n);

  select price_thb into v_num from product_prices
   where product_id = v_prod and effective_from = date '2026-01-01';
  assert v_num = 350.00, format('TC-25: the January price is now %s', v_num);

  --------------------------------------------------------------------------------- TC-26
  -- A zero full-stock level. R9 says zero means "not configured"; the CHECK says zero is
  -- unstorable. Both are satisfied by refusing it here, by name: "not configured" is the
  -- absence of a row, and v_material_alerts must return null rather than 0 (^ref-50).
  v_ok := false; v_err := null;
  begin
    perform fn_set_packaging_full_stock(gen_random_uuid(), v_item, date '2026-01-01', 0);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%FULL_STOCK_NOT_POSITIVE%';
  end;
  assert v_ok, format('TC-26: a zero full-stock level was not refused by name (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-31
  -- Two GLOBAL rows for one item on one date. The unique index does NOT refuse this —
  -- location_id is nullable and NULLs are distinct — so the function has to.
  v_id := fn_set_packaging_full_stock(gen_random_uuid(), v_item, date '2026-01-01', 1000);
  v_ok := false; v_err := null;
  begin
    perform fn_set_packaging_full_stock(gen_random_uuid(), v_item, date '2026-01-01', 2000);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_DUPLICATE_DATE%';
  end;
  assert v_ok, format('TC-31: a second global row on one date was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from packaging_full_stock
   where packaging_item_id = v_item and location_id is null
     and effective_from = date '2026-01-01';
  assert v_n = 1, format('TC-31: %s global rows exist for one item on one date', v_n);

  -- The retry still returns the original id, and a branch-scoped row is a different row.
  assert fn_set_packaging_full_stock(gen_random_uuid(), v_item, date '2026-01-01', 1000) = v_id,
    'TC-31: the full-stock retry did not return the original id';
  perform fn_set_packaging_full_stock(gen_random_uuid(), v_item, date '2026-01-01', 500, v_branch);
  select count(*) into v_n from packaging_full_stock where packaging_item_id = v_item;
  assert v_n = 2, format('TC-31: expected a global and a branch row, found %s', v_n);

  --------------------------------------------------------------------------------- TC-27
  -- Every setter's write is audited by ^ref-06's generic trigger, in the same transaction.
  -- No setter writes its own audit row — that would audit every rate change twice (R32).
  select count(*) into v_n from audit_log
   where table_name = 'config_settings' and action = 'INSERT'
     and actor_id = v_owner
     and after ->> 'key' = 'brine_pct_of_meat';
  assert v_n = 2, format('TC-27: %s audit row(s) for the two brine writes, expected 2', v_n);

  select count(*) into v_n from audit_log
   where table_name in ('smoke_fee_tiers', 'product_prices', 'packaging_full_stock')
     and actor_id is distinct from v_owner;
  assert v_n = 0, format('TC-27: %s config audit row(s) name the wrong actor', v_n);

  --------------------------------------------------------------------------------- TC-28
  -- This card grants EXECUTE on four functions and SELECT on nothing. The config tables
  -- stay deny-all until ^ref-12 builds a role-scoped read path (ADR-004, R20).
  select string_agg(format('%s:%s:%s', grantee, table_name, privilege_type), ', '), count(*)
    into v_txt, v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and grantee in ('anon', 'authenticated')
     and table_name in ('config_settings', 'product_prices', 'smoke_fee_tiers',
                        'packaging_full_stock', 'products', 'packaging_items');
  assert v_n = 0, format('TC-28: %s grant(s) leaked on a config table: %s', v_n, v_txt);

  -- And the two read helpers are not an endpoint either: a session that could call
  -- fn_config_value would read every price in the system straight past R20.
  select string_agg(p.proname, ', '), count(*) into v_txt, v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_config_value', 'fn_config_numeric')
     and (has_function_privilege('authenticated', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute'));
  assert v_n = 0, format('TC-28: %s read helper(s) reachable from a session: %s', v_n, v_txt);

  -- The four setters ARE reachable — the function is the boundary, not the table (ADR-002).
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_set_config', 'fn_set_smoke_fee_tier',
                       'fn_set_product_price', 'fn_set_packaging_full_stock')
     and has_function_privilege('authenticated', p.oid, 'execute');
  assert v_n = 4, format('TC-28: %s of 4 setters are callable by authenticated', v_n);

  ---------------------------------------------------------------- the uniform RPC contract
  -- A null idempotency key is refused everywhere, so the TypeScript wrapper shape is the
  -- same for every write in the system even though nothing here stores the key (ADR-005).
  v_ok := false; v_err := null;
  begin
    perform fn_set_config(null, 'chilli_paste_tube_weight_g', date '2026-01-01',
                          p_value_numeric => 30);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%IDEMPOTENCY_KEY_REQUIRED%';
  end;
  assert v_ok, format('R4: a null idempotency key was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  raise exception 'CONFIG_WRITERS_TEST_PASSED';   -- the only clean way back out
end $$;
