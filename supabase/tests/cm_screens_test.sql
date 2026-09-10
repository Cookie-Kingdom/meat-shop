-- Card ^ref-30 — the CM 01–05 screens' read surface, queried AS AN L3 SESSION.
--
-- Automates TC-56 from TDD-lots.md, which was "Manual until ^ref-30": an L3 session can read
-- no price and no yield column on anything the CM screens use — verified by querying as L3,
-- not by the nav being hidden (the card's acceptance line; BR15, UAT-15, ADR-004).
--
-- What the screens read: v_operator_lots (260) and v_smoke_log_day (261), both added by this
-- card, and v_lot_pending_work (100) and v_lot_progress (110) from ^ref-26/^ref-27. What they
-- write through is fn_record_lot_receipt, fn_upsert_smoke_daily_log, fn_record_lot_bags and
-- fn_close_lot; fn_close_lot's response body is TC-57 in lot_close_test.sql, and the other
-- three return a uuid or an integer, so no RPC here can carry a price.
--
-- Assumes from unmerged lanes: lane E's ^ref-31/^ref-32 contract that v_lot_yield and
-- v_lot_cost give an L3 session nothing (TC-56h runs only once those views exist), and lane
-- I's ...0024 seed rows, which are cleared first so this file sets its own two keys.
--
-- ONE do $$ BLOCK, for production_test.sql's reason: the harness pipes each file into psql
-- without --single-transaction, and only the closing raise rolls the fixtures back.
--
-- Run:  psql "$DATABASE_URL" -f supabase/tests/cm_screens_test.sql

do $$
declare
  v_n      bigint;
  v_txt    text;
  v_ok     boolean;
  v_err    text;
  v_kg     numeric;
  v_view   text;
  v_tab    text;
  v_day    date := date '2026-05-04';
  v_owner  uuid := gen_random_uuid();
  v_l2     uuid := gen_random_uuid();
  v_l3     uuid := gen_random_uuid();
  v_l3c    uuid := gen_random_uuid();
  v_chef   uuid;
  v_branch uuid;
  v_sup    uuid;
  v_po     uuid;
  v_lotA   uuid;
  v_lotB   uuid;
  v_lotT   uuid;
  v_lotO   uuid;
  v_src    jsonb;
begin
  -------------------------------------------------------------------------------- TC-56a
  -- The column sweep. Nothing any CM screen reads has a column whose NAME says price, cost,
  -- yield or loss. A name sweep, not a type sweep: a yield is a numeric like every weight, so
  -- the only thing that tells them apart is what the column is called — which is exactly what
  -- a later card widening a view would have to change. The four views must all exist first,
  -- or a renamed view would pass the sweep by being absent.
  select count(distinct table_name) into v_n
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('v_operator_lots', 'v_smoke_log_day',
                        'v_lot_pending_work', 'v_lot_progress');
  assert v_n = 4, format('TC-56a: expected the 4 CM views, found %s', v_n);

  select count(*), string_agg(table_name || '.' || column_name, ', ')
    into v_n, v_txt
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('v_operator_lots', 'v_smoke_log_day',
                        'v_lot_pending_work', 'v_lot_progress')
     and column_name ~ '(_thb$|price|cost|yield|loss|fee|freight|margin|profit|pct)';
  assert v_n = 0, format('TC-56a: a CM view exposes a price or yield column (BR15): %s', v_txt);

  -------------------------------------------------------------------------------- TC-56b
  -- The two new views hold exactly one grant, SELECT to authenticated, and nothing to anon
  -- (^ref-64, TC-36's shape).
  foreach v_view in array array['v_operator_lots', 'v_smoke_log_day']
  loop
    select count(*) into v_n
      from information_schema.role_table_grants
     where table_schema = 'public' and table_name = v_view and grantee = 'anon';
    assert v_n = 0, format('TC-56b: anon holds %s grant(s) on %s', v_n, v_view);

    select count(*), string_agg(privilege_type, ', ') into v_n, v_txt
      from information_schema.role_table_grants
     where table_schema = 'public' and table_name = v_view and grantee = 'authenticated';
    assert v_n = 1 and v_txt = 'SELECT',
      format('TC-56b: authenticated holds [%s] on %s, expected SELECT only', v_txt, v_view);
  end loop;

  ------------------------------------------------------------------------------- fixtures
  -- Lane I's seed rows may already carry the two receipt keys at a date this file would
  -- collide with (CONFIG_DUPLICATE_DATE). Guarded, because is_seed arrives with ...0024.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'config_settings'
                and column_name = 'is_seed') then
    execute 'delete from config_settings where is_seed';
  end if;

  insert into auth.users (id) values (v_owner), (v_l2), (v_l3), (v_l3c);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',               'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',            'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานคนที่หนึ่ง',   'L3_CM_OPERATOR',  true),
    (v_l3c,   'ผู้ปฏิบัติงานคนที่สอง',    'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind) values ('CH30', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('BR30', 'สาขาศาลาแดง', 'BRANCH')
    returning id into v_branch;

  -- Two operators at the SAME chef house, so every scope assertion below is an assignment
  -- test (CM 01) and not a location test.
  insert into user_locations (profile_id, location_id) values
    (v_l3, v_chef), (v_l3c, v_chef), (v_l2, v_branch);

  insert into suppliers (name) values ('ฟู้ดดีว่า') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_text => 'true');

  v_po   := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);
  v_lotA := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotB := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotT := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);

  -- The dispatch leg is ^ref-22's, not this card's. A is v_l3's and will be smoked; B is the
  -- other operator's; T is v_l3's and still on the truck, with no receipt — the row
  -- v_lot_pending_work cannot show and CM 01 must.
  update lots set state = 'IN_TRANSIT', assigned_operator_id = v_l3  where id in (v_lotA, v_lotT);
  update lots set state = 'IN_TRANSIT', assigned_operator_id = v_l3c where id = v_lotB;

  -- An opening lot (^ref-62's shape: no PO, no round, no dispatch weight, no chef house),
  -- assigned to v_l3 on purpose, so its absence from v_operator_lots is the opening filter
  -- and not the assignment test.
  insert into lots (lot_code, is_opening, state, event_date, assigned_operator_id)
       values ('OPEN-CM30', true, 'LOT_CLOSED', v_day, v_l3)
    returning id into v_lotO;

  -- The work, through the RPCs the screens call, as the operators who own it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotA, v_day, 98.00, 96.50);
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotA, v_day,
            jsonb_build_array(jsonb_build_object('lot_id', v_lotA, 'input_weight_kg', 40.00)),
            p_brine_used_kg => 4.00);
  perform fn_record_lot_bags(gen_random_uuid(), v_lotA, v_day, array[0.50, 0.40]::numeric[]);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3c)::text, true);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotB, v_day, 100.00);

  -------------------------------------------------------------------------------- TC-56c
  -- AS AN L3 SESSION — the authenticated role and v_l3's claims, which is what PostgREST
  -- hands a signed-in operator. CM 01 reads own assigned lots only: A and T, never the other
  -- operator's B, never the opening lot O.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  set local role authenticated;

  select count(*), string_agg(lot_code, ',' order by lot_code) into v_n, v_txt
    from v_operator_lots;
  assert v_n = 2, format('TC-56c: an L3 read %s lot(s) from v_operator_lots: %s', v_n, v_txt);
  assert not exists (select 1 from v_operator_lots where lot_id in (v_lotB, v_lotO)),
    'TC-56c: an L3 read a lot that is not theirs, or the opening lot';

  -- The declared weight IS on CM 01 (v0.2 line 78) and the receipt rides along.
  select foodiva_sent_weight_kg + received_weight_kg into v_kg
    from v_operator_lots where lot_id = v_lotA;
  assert v_kg = 198.00, format('TC-56c: lot A reads %s, expected 100.00 + 98.00', v_kg);
  select count(*) into v_n from v_operator_lots
   where lot_id = v_lotT and received_weight_kg is null and state = 'IN_TRANSIT';
  assert v_n = 1, 'TC-56c: the lot still on the truck is missing from CM 01';

  -------------------------------------------------------------------------------- TC-56d
  -- CM 04's re-open: the day's log with its sources naming their lot (D05), and the bags
  -- under that smoke date from the group roll-up — own lots only.
  select count(*) into v_n from v_smoke_log_day;
  assert v_n = 1, format('TC-56d: an L3 read %s log(s), expected lot A''s one', v_n);

  select sources, packed_weight_kg + bag_count into v_src, v_kg
    from v_smoke_log_day where lot_id = v_lotA and event_date = v_day;
  assert jsonb_array_length(v_src) = 1
     and (v_src -> 0 ->> 'lot_id')::uuid = v_lotA
     and (v_src -> 0 ->> 'input_weight_kg')::numeric = 40.00,
    format('TC-56d: the sources array reads %s', v_src);
  assert v_kg = 2.90, format('TC-56d: packed 0.90 + 2 bags expected, read %s', v_kg);

  -------------------------------------------------------------------------------- TC-56e
  -- The tables behind the views stay refused to the same session — the views are the only
  -- read path, so a price column on lots or a fee on config_settings is out of reach too.
  foreach v_tab in array array['lots', 'lot_receipts', 'smoke_daily_logs',
                               'smoke_daily_log_sources', 'smoke_date_groups', 'lot_bags',
                               'purchase_orders', 'config_settings', 'smoke_fee_tiers',
                               'notifications', 'stock_ledger']
  loop
    v_ok := false; v_err := null;
    begin
      execute format('select count(*) from public.%I', v_tab) into v_n;
      v_err := format('%s row(s)', v_n);
    exception when insufficient_privilege then
      v_ok := true;
    end;
    assert v_ok, format('TC-56e: an L3 session could select from %s (%s)', v_tab, v_err);
  end loop;

  -------------------------------------------------------------------------------- TC-56h
  -- The F7 views, once lane E lands them: an L3 session reads nothing from either, whether
  -- by a WHERE that filters it out or by a refused grant (^ref-31, ^ref-32 acceptance).
  foreach v_view in array array['v_lot_yield', 'v_lot_cost']
  loop
    continue when to_regclass('public.' || v_view) is null;
    v_n := 0;
    begin
      execute format('select count(*) from public.%I', v_view) into v_n;
    exception when insufficient_privilege then
      v_n := 0;
    end;
    assert v_n = 0, format('TC-56h: an L3 session read %s row(s) from %s', v_n, v_view);
  end loop;

  -------------------------------------------------------------------------------- TC-56f
  -- An L2 session reads nothing from either new view — F6 is not a branch feature (R34).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  select (select count(*) from v_operator_lots) + (select count(*) from v_smoke_log_day)
    into v_n;
  assert v_n = 0, format('TC-56f: an L2 session read %s row(s) from the CM views', v_n);

  -------------------------------------------------------------------------------- TC-56g
  -- L1 reads every lot the fixture made — and still never the opening lot, which never
  -- passes through a CM screen.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_operator_lots where lot_id in (v_lotA, v_lotB, v_lotT);
  assert v_n = 3, format('TC-56g: L1 read %s of the 3 fixture lots', v_n);
  assert not exists (select 1 from v_operator_lots where lot_id = v_lotO),
    'TC-56g: the opening lot is in v_operator_lots';

  reset role;

  raise exception 'CM_SCREENS_TEST_PASSED';   -- the only clean way back out
end $$;
