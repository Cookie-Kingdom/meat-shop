-- Card ^ref-65 — the demo dataset. Applied by supabase/demo/reset.sh to meat-shop-demo only:
-- never a migration, never applied to Meat Shop (D1, D11).
--
-- Every value below that the Owner has not confirmed is a demo placeholder (D11). It does not
-- settle ^ref-61. Every transaction goes through its real fn_*, as the persona who would make
-- it, the way the SQL tests do.
--
-- Dates hang off current_date so every reset looks like a fresh week. Backdating is open
-- because opening balances are never closed here (D8; PLAN Finding 3).
--
-- Leaves:  lot A in central stock for the Owner to allocate;
--          lot B mid-smoke for the chef to keep logging;
--          lot C on the truck to Chiang Mai for the chef to receive;
--          both branches empty, for their admins to key opening stock (D8).

begin;

do $$
declare
  d         date := current_date;
  v_owner   uuid;
  v_chef    uuid;
  v_salaeng uuid;
  v_minburi uuid;
  v_central uuid;
  v_cm      uuid;
  v_sld     uuid;
  v_mnb     uuid;
  v_sup     uuid;
  v_po      uuid;
  v_lotA    uuid;
  v_lotB    uuid;
  v_lotC    uuid;
  v_run     uuid;
  v_line    uuid;
  v_gA      uuid;
  v_id      uuid;
begin
  ------------------------------------------------------------------------------ people
  -- The auth users are reset.sh's (Auth Admin API); here they are only looked up.
  select id into v_owner   from auth.users where email = 'demo-owner@demo.local';
  select id into v_chef    from auth.users where email = 'demo-chef@demo.local';
  select id into v_salaeng from auth.users where email = 'demo-salaeng@demo.local';
  select id into v_minburi from auth.users where email = 'demo-minburi@demo.local';
  if v_owner is null or v_chef is null or v_salaeng is null or v_minburi is null then
    raise exception 'DEMO_USERS_MISSING: create the four demo-*@demo.local users first (reset.sh step 2)';
  end if;

  insert into profiles (id, display_name, role, is_active) values
    (v_owner,   'เจ้าของร้าน',          'L1_OWNER',        true),
    (v_chef,    'เชฟเฮาส์ เชียงใหม่',     'L3_CM_OPERATOR',  true),
    (v_salaeng, 'แอดมินสาขาศาลาแดง',    'L2_BRANCH_ADMIN', true),
    (v_minburi, 'แอดมินสาขามีนบุรี',     'L2_BRANCH_ADMIN', true);

  ------------------------------------------------------------------------ master data
  -- No fn_* writes these tables; the SQL test fixtures insert them the same way.
  insert into locations (code, name_th, kind) values ('CEN', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  insert into locations (code, name_th, kind) values ('CM', 'เชฟเฮาส์ เชียงใหม่', 'CHEF_HOUSE')
    returning id into v_cm;
  -- BR 03: ศาลาแดง cooks its own rice, มีนบุรี receives it cooked.
  insert into locations (code, name_th, kind, rice_model)
    values ('SLD', 'สาขาศาลาแดง', 'BRANCH', 'SELF_COOK') returning id into v_sld;
  insert into locations (code, name_th, kind, rice_model)
    values ('MNB', 'สาขามีนบุรี', 'BRANCH', 'EXTERNAL_COOKED') returning id into v_mnb;

  -- The chef's row is fn_require_operator step 3. The Owner needs none, and no row carries
  -- can_receive_central: the Owner receives into central herself (D9).
  insert into user_locations (profile_id, location_id) values
    (v_chef, v_cm), (v_salaeng, v_sld), (v_minburi, v_mnb);

  insert into suppliers (name) values ('Foodiva') returning id into v_sup;

  -- Products are …0018's five SKUs; only their prices are the seed's.

  ---------------------------------------------------------------- config, as the Owner
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  perform fn_set_config(gen_random_uuid(), 'avg_pack_weight_kg', d - 30, p_value_numeric => 0.50);
  perform fn_set_config(gen_random_uuid(), 'brine_cost_thb_per_kg', d - 30, p_value_numeric => 40.00);
  perform fn_set_config(gen_random_uuid(), 'freight_thb_by_vehicle_type', d - 30,
    p_value_json => '{"รถกระบะ": {"ONE_WAY": 4500, "ROUND_TRIP": 8000}}');
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', d - 30, p_value_text => 'BY_LOT_WEIGHT');
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_settlement_method', d - 30,
    p_value_text => 'ตัดส่วนต่างเป็นของเสีย');
  perform fn_set_config(gen_random_uuid(), 'unlock_window_hours', d - 30, p_value_numeric => 24);
  -- The count is true as of the reset day, so branch admins key opening stock dated today (D8).
  perform fn_set_config(gen_random_uuid(), 'opening_cutoff_date', d - 30, p_value_text => d::text);

  perform fn_set_smoke_fee_tier(gen_random_uuid(), d - 30,
    '[{"min_weight_kg": 0,   "max_weight_kg": 100,  "rate_thb": 30, "rate_basis": "PER_KG"},
      {"min_weight_kg": 100, "max_weight_kg": null, "rate_thb": 25, "rate_basis": "PER_KG"}]');

  -- Every active SKU needs a price (v_config_readiness). Box 350 and sealed 320 are v0.2's
  -- (BR 13); chilli, rice and water are placeholders. Rice and water carry a cost too
  -- (product_costs WARN); meat's comes from the lot, chilli's from its config key.
  perform fn_set_product_price(gen_random_uuid(), id, d - 30, 350.00) from products where code = 'MEAT_BOX';
  perform fn_set_product_price(gen_random_uuid(), id, d - 30, 320.00) from products where code = 'MEAT_ADDON_SEALED';
  perform fn_set_product_price(gen_random_uuid(), id, d - 30, 20.00)  from products where code = 'CHILLI_TUBE';
  perform fn_set_product_price(gen_random_uuid(), id, d - 30, 100.00, 40.00) from products where code = 'RICE_KG';
  perform fn_set_product_price(gen_random_uuid(), id, d - 30, 15.00, 7.00)   from products where code = 'WATER_BOTTLE';

  perform fn_seed_packaging_items(gen_random_uuid());
  perform fn_set_packaging_full_stock(gen_random_uuid(), id, d - 30, 100) from packaging_items;

  ------------------------------------------------------------- purchasing, as the Owner
  v_po   := fn_create_po(gen_random_uuid(), v_sup, d - 12, 300.00, 250.00);
  v_lotA := fn_add_po_delivery(gen_random_uuid(), v_po, d - 10, 100.00, v_cm);
  v_lotB := fn_add_po_delivery(gen_random_uuid(), v_po, d - 5,  100.00, v_cm);
  v_lotC := fn_add_po_delivery(gen_random_uuid(), v_po, d - 1,  100.00, v_cm);

  -- CM 01: each lot names the operator who works it, or fn_require_operator refuses every
  -- chef-house step (NOT_ASSIGNED_OPERATOR; ^ref-66).
  perform fn_assign_lot_operator(gen_random_uuid(), l, v_chef)
     from unnest(array[v_lotA, v_lotB, v_lotC]) l;

  -- One truck per lot, Foodiva to Chiang Mai.
  v_run := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', d - 10, 'รถกระบะ', false, 4500.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotA, null, null, v_cm, 100.00);
  v_run := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', d - 5, 'รถกระบะ', false, 4500.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotB, null, null, v_cm, 100.00);
  v_run := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', d - 1, 'รถกระบะ', false, 4500.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotC, null, null, v_cm, 100.00);

  ------------------------------------------------------------ the chef house, as the chef
  perform set_config('request.jwt.claims', json_build_object('sub', v_chef)::text, true);

  -- CM 02 signs the truck and records the measurement in one call (^fix-cm02-sign-line): the
  -- meat moves IN_TRANSIT -> FROZEN at the chef house and leaves OW 02's ค้างรับ.
  -- ponytail: the full 100.00 arrives. A short receipt stays in ค้างรับ as a partial until D06
  -- settlement closes it (^fix-receipt-settlement); use 98.00 once something does.

  -- Lot A: received, smoked in one day, bagged, closed.
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotA, d - 9, 100.00, 96.50);
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotA, d - 9,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotA, 'input_weight_kg', 96.50)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotA, d - 9,
    array(select 0.50::numeric from generate_series(1, 150)));
  perform fn_close_lot(gen_random_uuid(), v_lotA);

  -- Lot B: received, three days logged, still smoking. 80.00 of 96.50 kg logged, so 16.50 kg
  -- is left for the guide's first chef task (D2).
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotB, d - 4, 100.00, 96.50);
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotB, d - 4,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotB, 'input_weight_kg', 30.00)));
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotB, d - 3,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotB, 'input_weight_kg', 30.00)));
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotB, d - 2,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotB, 'input_weight_kg', 20.00)));

  -- Lot C: left on the truck.

  ------------------------------------------- lot A back to central stock, as the Owner
  -- Today, because the close was stamped now() and a pickup cannot precede it (Finding 4).
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_return_pickup_date(gen_random_uuid(), v_lotA, d);
  select id into v_gA from smoke_date_groups where lot_id = v_lotA;
  v_run  := fn_create_transport_run(gen_random_uuid(), 'CM_TO_FOODIVA', d, 'รถกระบะ', false, 4500.00,
                                    array[v_lotA]);
  v_line := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotA, v_gA, v_cm, v_central, 75.00);
  v_id   := fn_confirm_central_intake(gen_random_uuid(), v_line, d, 75.00, p_received_bag_count => 150);
end $$;

commit;

notify pgrst, 'reload schema';
