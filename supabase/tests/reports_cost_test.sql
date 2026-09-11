-- Card ^ref-56 — v_meat_consumption, v_lot_unit_cost, v_meat_cost_attribution, v_cost_breakdown.
-- TC-10 ... TC-24 and TC-R3, TC-R5, TC-R6 of v.0.1/ready-ref-55-58-reporting/TDD-reporting.md §56.
-- Contract assumed from an unmerged lane: none (170/171 lane E, 191 lane I, fn_record_sales's
-- SALE shape lane C — all on develop at aec8aec).
--
-- LOT A IS BUILT THROUGH THE REAL CHAIN, cost_test.sql's recipe (F1): PO at 250.00, dispatch
-- 100.00 on a 600.00 outbound run, CM receipt of the full 100.00 (so nothing is left IN_TRANSIT to
-- disturb TC-33's balance), 150 bags of 0.50 = 75.00, fn_close_lot, a 300.00 return run received
-- at central. 171 then reads 25,000.00 / 200.00 / 5,000.00 / 900.00 = 31,100.00, complete, and
-- 170 reads output 75.00. TC-11 and TC-12 compare 211 to both rather than trusting them.
--
-- LOTS C, O AND O2 ARE MINIMAL. Lot C (F2) is a real PO and delivery, then one UPDATE standing in
-- for the close (state, closed_at, loss 1.00) — no transport, so its freight is honestly missing.
-- O and O2 are opening lots inserted directly, as cost_test.sql does, with one OPENING ledger row
-- each; O has an opening_costs row (300.00/kg), O2 has none (TC-17's failure half).
--
-- MOVEMENTS GO THROUGH fn_post_ledger as the Owner, in the shapes the writers use: SALE with
-- source_table 'sales_lines', WASTE, TRANSFER_OUT/IN, THAW_OUT/IN, ADJUSTMENT. Those writers are
-- other files' subjects; these views read the rows. Sales lines are inserted directly while their
-- report is OPEN (fn_guard_report_closed).
--
-- NOTHING IS DELETED. The config seed (…0024) pre-fills chilli_paste_cost_thb_per_tube = 15.00
-- from 2000-01-01, so TC-18's "no rate" case is a chilli sale dated 1999-12-31, before any row.
--
-- One do $$ block; the transaction aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/reports_cost_test.sql

do $$
declare
  v_owner   uuid := gen_random_uuid();
  v_l2a     uuid := gen_random_uuid();
  v_l3      uuid := gen_random_uuid();
  v_day     date := date '2026-05-04';    -- PO and truck dates, as cost_test.sql
  v_d1      date := date '2026-08-10';    -- the reference business day
  v_chef    uuid;
  v_central uuid;
  v_b1      uuid;
  v_b2      uuid;
  v_sup     uuid;
  v_po      uuid;
  v_poC     uuid;
  v_lotA    uuid;
  v_lotC    uuid;
  v_lotO    uuid;
  v_lotO2   uuid;
  v_gA      uuid;
  v_run     uuid;
  v_line    uuid;
  v_ret     uuid;
  v_closed  date;
  v_r1d1    uuid;
  v_r1d2    uuid;
  v_box     uuid;
  v_chilli  uuid;
  v_rice    uuid;
  v_sl      uuid;
  v_led     uuid;
  v_inv     uuid;
  v_mfx     uuid;
  v_staff   uuid;
  v_row     record;
  v_cost    record;
  v_exp     record;
  v_n       bigint;
  v_sum     numeric;
  v_amt     numeric;
  v_view    text;
  v_views   text[] := array['v_meat_consumption', 'v_lot_unit_cost',
                            'v_meat_cost_attribution', 'v_cost_breakdown'];
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2a), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',               'L1_OWNER',        true),
    (v_l2a,   'แอดมินสาขาหนึ่ง',        'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',    'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind) values ('K56-CH', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('K56-CEN', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  insert into locations (code, name_th, kind) values ('K56-B1', 'สาขาหนึ่ง', 'BRANCH')
    returning id into v_b1;
  insert into locations (code, name_th, kind) values ('K56-B2', 'สาขาสอง', 'BRANCH')
    returning id into v_b2;
  insert into user_locations (profile_id, location_id) values (v_l2a, v_b1), (v_l3, v_chef);
  insert into suppliers (name) values ('ฟู้ดดีว่า') returning id into v_sup;

  select id into v_box    from products where code = 'MEAT_BOX';
  select id into v_chilli from products where code = 'CHILLI_TUBE';
  select id into v_rice   from products where code = 'RICE_KG';

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'yield_alert_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', date '2026-01-01',
                        p_value_text => 'BY_LOT_WEIGHT');
  perform fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'brine_pct_of_meat', date '2026-01-01',
                        p_value_numeric => 10.00);
  perform fn_set_config(gen_random_uuid(), 'brine_cost_thb_per_kg', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01',
    '[{"min_weight_kg": 0, "max_weight_kg": null, "rate_thb": 50.00, "rate_basis": "PER_KG"}]'::jsonb);
  perform fn_set_config(gen_random_uuid(), 'chilli_paste_cost_thb_per_tube', v_d1 - 30,
                        p_value_numeric => 15.00);

  ---------------------------------------------------------------- lot A, the real chain (F1)
  v_po   := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);
  v_lotA := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  update lots set assigned_operator_id = v_l3 where id = v_lotA;

  v_run  := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', v_day + 1,
                                    'รถห้องเย็น', false, 600.00);
  v_line := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotA, null, null, v_chef, 100.00);
  perform fn_allocate_freight(gen_random_uuid(), v_run);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line, v_day + 2, 100.00);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotA, v_day + 2, 100.00, 96.50);
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotA, v_day + 3,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotA, 'input_weight_kg', 96.50)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotA, v_day + 3,
                             array(select 0.50::numeric from generate_series(1, 150)));
  perform fn_close_lot(gen_random_uuid(), v_lotA);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select closed_at::date into v_closed from lots where id = v_lotA;
  perform fn_set_return_pickup_date(gen_random_uuid(), v_lotA, v_closed);
  v_run := fn_create_transport_run(gen_random_uuid(), 'CM_TO_FOODIVA', v_day + 5,
                                   'รถห้องเย็น', false, 300.00, array[v_lotA]);
  select id into v_gA from smoke_date_groups where lot_id = v_lotA;
  v_ret := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotA, v_gA, v_chef, v_central, 75.00);
  perform fn_allocate_freight(gen_random_uuid(), v_run);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_ret, v_day + 6, 75.00);

  select * into v_cost from v_lot_cost where lot_id = v_lotA;
  assert v_cost.is_complete and v_cost.total_cost_thb = 31100.00,
    format('fixture: lot A reads complete=%s, total %s, missing %s — expected true, 31100.00, {}',
           v_cost.is_complete, v_cost.total_cost_thb, v_cost.missing_inputs);

  --------------------------------------------------------------- lot C, minimal (F2)
  v_poC  := fn_create_po(gen_random_uuid(), v_sup, v_day, 4.00, 250.00);
  v_lotC := fn_add_po_delivery(gen_random_uuid(), v_poC, v_day, 4.00, v_chef);
  update lots set state = 'LOT_CLOSED', closed_at = now(), loss_weight_kg = 1.00 where id = v_lotC;

  --------------------------------------------------------------- lots O and O2, opening (F3)
  insert into lots (lot_code, is_opening, state, event_date)
    values ('K56-OPEN', true, 'CENTRAL_STOCK', v_d1 - 40) returning id into v_lotO;
  insert into lots (lot_code, is_opening, state, event_date)
    values ('K56-OPEN2', true, 'CENTRAL_STOCK', v_d1 - 40) returning id into v_lotO2;
  v_led := fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
                          p_location_id => v_central, p_stock_state => 'FROZEN',
                          p_movement_type => 'OPENING', p_qty_delta => 10.00,
                          p_business_date => v_d1 - 40, p_lot_id => v_lotO);
  insert into opening_costs (ledger_id, cost_thb_per_kg, set_by) values (v_led, 300.00, v_owner);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
                         p_location_id => v_central, p_stock_state => 'FROZEN',
                         p_movement_type => 'OPENING', p_qty_delta => 1.00,
                         p_business_date => v_d1 - 40, p_lot_id => v_lotO2);

  ------------------------------------------------ inert movements to the branches (TC-10b)
  -- Lot A: central → B1 FROZEN → thawed to READY, then an ADJUSTMENT in and out.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_central, p_stock_state => 'FROZEN', p_movement_type => 'TRANSFER_OUT',
    p_qty_delta => -3.60, p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'FROZEN', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 3.60, p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'FROZEN', p_movement_type => 'THAW_OUT',
    p_qty_delta => -3.60, p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'THAW_IN',
    p_qty_delta => 3.60, p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'ADJUSTMENT',
    p_qty_delta => 0.10, p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'ADJUSTMENT',
    p_qty_delta => -0.10, p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  -- Lots O and O2: central → B1 READY. Lot C: straight onto B2 READY.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_central, p_stock_state => 'FROZEN', p_movement_type => 'TRANSFER_OUT',
    p_qty_delta => -3.00, p_business_date => v_d1, p_lot_id => v_lotO);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 3.00, p_business_date => v_d1, p_lot_id => v_lotO);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_central, p_stock_state => 'FROZEN', p_movement_type => 'TRANSFER_OUT',
    p_qty_delta => -1.00, p_business_date => v_d1, p_lot_id => v_lotO2);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 1.00, p_business_date => v_d1, p_lot_id => v_lotO2);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 3.00, p_business_date => v_d1, p_lot_id => v_lotC);
  -- Chilli onto both branches.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'CHILLI_PASTE',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 10, p_business_date => v_d1, p_product_id => v_chilli);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'CHILLI_PASTE',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 5, p_business_date => v_d1, p_product_id => v_chilli);

  --------------------------------------------------------------------------- TC-10, TC-10b
  -- ADR-025, failure case: PRODUCTION (lot A's close), INTAKE, TRANSFER_*, THAW_*, ADJUSTMENT and
  -- OPENING rows all exist, nothing has been sold, and nothing is consumed. Zero rows — not 0.00.
  select count(*) into v_n from stock_ledger where lot_id = v_lotA and movement_type = 'PRODUCTION';
  assert v_n >= 2, format('fixture: lot A has %s PRODUCTION row(s) after close', v_n);
  select count(*) into v_n from v_meat_consumption where lot_id in (v_lotA, v_lotC, v_lotO, v_lotO2);
  assert v_n = 0, format('TC-10: %s consumption row(s) before any sale — PRODUCTION or a seed/transfer type leaked', v_n);
  select count(*) into v_n from v_meat_cost_attribution where lot_id in (v_lotA, v_lotC, v_lotO, v_lotO2);
  assert v_n = 0, format('TC-10: %s attribution row(s) before any sale', v_n);

  ----------------------------------------------------------------------- the reference day
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by) values
    (v_b1, v_d1, v_d1 + time '09:00', 'OPEN', v_owner) returning id into v_r1d1;
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by) values
    (v_b1, v_d1 + 1, v_d1 + 1 + time '09:00', 'OPEN', v_owner) returning id into v_r1d2;

  -- 12 boxes of lot A at 0.25 kg: SALE −3.00 kg.
  insert into sales_lines (daily_report_id, product_id, lot_id, smoke_date_group_id, qty,
                           unit_price_thb, pack_weight_kg, channel, created_by)
    values (v_r1d1, v_box, v_lotA, v_gA, 12, 350.00, 0.25, 'LINE_MAN', v_owner) returning id into v_sl;
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -3.00,
    p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA,
    p_source_table => 'sales_lines', p_source_id => v_sl);
  -- A WASTE of −0.60 kg.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'WASTE', p_qty_delta => -0.60,
    p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  -- 5 tubes of chilli.
  insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, channel, created_by)
    values (v_r1d1, v_chilli, 5, 25.00, 'LINE_MAN', v_owner) returning id into v_sl;
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'CHILLI_PASTE',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -5,
    p_business_date => v_d1, p_product_id => v_chilli,
    p_source_table => 'sales_lines', p_source_id => v_sl);
  -- 2.50 kg of rice: priced, no ledger row (not stock-tracked).
  insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, channel, created_by)
    values (v_r1d1, v_rice, 2.50, 60.00, 'LINE_MAN', v_owner);
  -- Two branch expenses.
  insert into branch_expenses (daily_report_id, category, amount_thb, paid_by_person, created_by) values
    (v_r1d1, 'ICE',       100.00, 'สมชาย', v_owner),
    (v_r1d1, 'PACKAGING',  50.00, 'สมชาย', v_owner);

  -- D1 + 1 at B1: 8 boxes of opening lot O (−2.00 kg), and 0.50 kg of uncosted lot O2.
  insert into sales_lines (daily_report_id, product_id, lot_id, qty, unit_price_thb,
                           pack_weight_kg, channel, created_by)
    values (v_r1d2, v_box, v_lotO, 8, 350.00, 0.25, 'LINE_MAN', v_owner) returning id into v_sl;
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -2.00,
    p_business_date => v_d1 + 1, p_lot_id => v_lotO, p_source_table => 'sales_lines', p_source_id => v_sl);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'WASTE', p_qty_delta => -0.50,
    p_business_date => v_d1 + 1, p_lot_id => v_lotO2);

  update daily_reports set status = 'CLOSED', closed_by = v_owner, closed_at = now() where id = v_r1d1;

  -- Lot C at B2: one 1.00 kg SALE on each of D1, D1 + 1, D1 + 2 (F2). Ledger only.
  for v_n in 0 .. 2 loop
    perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
      p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -1.00,
      p_business_date => v_d1 + v_n::integer, p_lot_id => v_lotC);
  end loop;

  --------------------------------------------------------------------------------- TC-11
  -- 211 for a round lot is 171's parts over 170's output, read and not recomputed.
  select * into v_row from v_lot_unit_cost where lot_id = v_lotA;
  assert not v_row.is_opening and v_row.output_kg = 75.00,
    format('TC-11: lot A reads opening %s, output %s — expected false, 75.00', v_row.is_opening, v_row.output_kg);
  assert v_row.meat_cost_thb  = v_cost.meat_cost_thb  and v_row.brine_cost_thb = v_cost.brine_cost_thb
     and v_row.smoke_fee_thb  = v_cost.smoke_fee_thb  and v_row.freight_thb    = v_cost.freight_share_thb
     and v_row.total_cost_thb = v_cost.total_cost_thb and v_row.cost_is_complete = v_cost.is_complete,
    format('TC-11: 211 (%s, %s, %s, %s, %s) differs from 171 (%s, %s, %s, %s, %s)',
           v_row.meat_cost_thb, v_row.brine_cost_thb, v_row.smoke_fee_thb, v_row.freight_thb, v_row.total_cost_thb,
           v_cost.meat_cost_thb, v_cost.brine_cost_thb, v_cost.smoke_fee_thb, v_cost.freight_share_thb,
           v_cost.total_cost_thb);
  assert v_row.meat_cost_thb = 25000.00 and v_row.brine_cost_thb = 200.00
     and v_row.smoke_fee_thb = 5000.00 and v_row.freight_thb = 900.00 and v_row.opening_stock_cost_thb is null,
    format('TC-11: lot A reads %s / %s / %s / %s / opening %s — expected 25000.00 / 200.00 / 5000.00 / 900.00 / null',
           v_row.meat_cost_thb, v_row.brine_cost_thb, v_row.smoke_fee_thb, v_row.freight_thb,
           v_row.opening_stock_cost_thb);

  --------------------------------------------------------------------------------- TC-12
  -- Failure case, cross-lane: lane E's output is the lot's positive PRODUCTION, and opening lots
  -- are in neither 170 nor 171 but are in 211 once each.
  select sum(qty_delta) into v_sum from stock_ledger
   where lot_id = v_lotA and movement_type = 'PRODUCTION' and qty_delta > 0;
  assert v_row.output_kg = v_sum,
    format('TC-12: 211 output %s, Σ positive PRODUCTION %s — 170 and the ledger drifted apart', v_row.output_kg, v_sum);
  select count(*) into v_n from v_lot_yield where lot_id in (v_lotO, v_lotO2);
  assert v_n = 0, format('TC-12: %s opening lot row(s) in v_lot_yield', v_n);
  select count(*) into v_n from v_lot_cost where lot_id in (v_lotO, v_lotO2);
  assert v_n = 0, format('TC-12: %s opening lot row(s) in v_lot_cost', v_n);
  select count(*) into v_n from v_lot_unit_cost where lot_id = v_lotO;
  assert v_n = 1, format('TC-12: opening lot O has %s row(s) in v_lot_unit_cost, expected 1', v_n);

  select * into v_row from v_lot_unit_cost where lot_id = v_lotO;
  assert v_row.is_opening and v_row.output_kg = 10.00 and v_row.opening_stock_cost_thb = 3000.00
     and v_row.total_cost_thb = 3000.00 and v_row.cost_is_complete and cardinality(v_row.missing_inputs) = 0
     and v_row.meat_cost_thb is null,
    format('TC-12: lot O reads output %s, opening cost %s, total %s, complete %s, missing %s',
           v_row.output_kg, v_row.opening_stock_cost_thb, v_row.total_cost_thb,
           v_row.cost_is_complete, v_row.missing_inputs);

  --------------------------------------------------------------------------------- TC-14
  -- Cumulative rounding on lot C (meat 1,000.00, brine 8.00, output 3.00): three 1.00 kg atoms.
  select * into v_row from v_lot_unit_cost where lot_id = v_lotC;
  assert v_row.output_kg = 3.00 and v_row.meat_cost_thb = 1000.00 and v_row.brine_cost_thb = 8.00
     and v_row.freight_thb is null and not v_row.cost_is_complete,
    format('fixture: lot C reads output %s, meat %s, brine %s, freight %s, complete %s',
           v_row.output_kg, v_row.meat_cost_thb, v_row.brine_cost_thb, v_row.freight_thb, v_row.cost_is_complete);
  select string_agg(meat_cost_thb::text || '/' || brine_cost_thb::text, ' ' order by business_date)
    into v_view
    from v_meat_cost_attribution where lot_id = v_lotC;
  assert v_view = '333.33/2.67 333.34/2.66 333.33/2.67',
    format('TC-14: lot C''s atoms read %s — expected 333.33/2.67 333.34/2.66 333.33/2.67', v_view);
  select sum(meat_cost_thb), count(*) filter (where freight_thb is not null)
    into v_sum, v_n from v_meat_cost_attribution where lot_id = v_lotC;
  assert v_sum = 1000.00 and v_n = 0,
    format('TC-14: lot C sums to %s with %s priced freight atom(s) — expected 1000.00 and none', v_sum, v_n);

  --------------------------------------------------------------------------------- TC-15
  -- Failure case: 0.50 kg over-delivered by ADJUSTMENT and sold. The ratio stops at 1.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'ADJUSTMENT', p_qty_delta => 0.50,
    p_business_date => v_d1 + 3, p_lot_id => v_lotC);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -0.25,
    p_business_date => v_d1 + 3, p_lot_id => v_lotC);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -0.25,
    p_business_date => v_d1 + 4, p_lot_id => v_lotC);
  select sum(meat_cost_thb) into v_sum from v_meat_cost_attribution where lot_id = v_lotC;
  assert v_sum = 1000.00,
    format('TC-15: 3.50 kg sold of a 3.00 kg lot costs %s, expected 1000.00 (never 1166.67)', v_sum);
  select count(*) into v_n from v_meat_cost_attribution
   where lot_id = v_lotC and business_date >= v_d1 + 3 and over_consumed and meat_cost_thb = 0.00;
  assert v_n = 2, format('TC-15: %s of the 2 atoms past the output read over_consumed at 0.00', v_n);
  select count(*) into v_n from v_meat_cost_attribution
   where lot_id = v_lotC and business_date < v_d1 + 3 and over_consumed;
  assert v_n = 0, format('TC-15: %s atom(s) within the output read over_consumed', v_n);

  --------------------------------------------------------------------------------- TC-16
  -- F1's breakdown rows at B1 on D1.
  for v_exp in
    select * from (values ('MEAT', 'SALE', 1000.00), ('MEAT', 'WASTE', 200.00),
                          ('BRINE', 'SALE', 8.00), ('BRINE', 'WASTE', 1.60),
                          ('SMOKE_FEE', 'SALE', 200.00), ('SMOKE_FEE', 'WASTE', 40.00),
                          ('TRANSPORT', 'SALE', 36.00), ('TRANSPORT', 'WASTE', 7.20)) e(category, kind, amount)
  loop
    select amount_thb into v_amt from v_cost_breakdown
     where cost_date = v_d1 and location_id = v_b1 and lot_id = v_lotA
       and category = v_exp.category and consumption_kind = v_exp.kind;
    assert v_amt = v_exp.amount,
      format('TC-16: %s on the %s atom reads %s, expected %s', v_exp.category, v_exp.kind, v_amt, v_exp.amount);
  end loop;
  select count(*) into v_n from v_cost_breakdown where lot_id = v_lotA and category = 'OPENING_STOCK';
  assert v_n = 0, format('TC-16: round lot A has %s OPENING_STOCK row(s)', v_n);

  select * into v_row from v_cost_breakdown
   where cost_date = v_d1 and location_id = v_b1 and category = 'CHILLI_PASTE';
  assert v_row.amount_thb = 75.00 and v_row.consumed_tubes = 5 and v_row.is_complete,
    format('TC-16: chilli reads %s THB over %s tubes, complete %s — expected 75.00, 5, true',
           v_row.amount_thb, v_row.consumed_tubes, v_row.is_complete);
  select * into v_row from v_cost_breakdown
   where cost_date = v_d1 and location_id = v_b1 and category = 'PACKAGING';
  assert v_row.amount_thb = 50.00 and v_row.source_table = 'branch_expenses' and v_row.source_id is not null,
    format('TC-16: packaging reads %s from %s', v_row.amount_thb, v_row.source_table);
  select * into v_row from v_cost_breakdown
   where cost_date = v_d1 and location_id = v_b1 and category = 'BRANCH_EXPENSE';
  assert v_row.amount_thb = 100.00 and v_row.source_label = 'ICE' and v_row.in_pnl_round_one,
    format('TC-16: the branch expense reads %s (%s)', v_row.amount_thb, v_row.source_label);

  --------------------------------------------------------------------------------- TC-13
  -- Reconcile to the satang: consume the rest of lot A (71.40 kg) over four more days at two
  -- branches. Every part sums to 171's figure exactly, and D1's atoms do not move.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_central, p_stock_state => 'FROZEN', p_movement_type => 'TRANSFER_OUT',
    p_qty_delta => -71.40, p_business_date => v_d1 + 1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 40.00, p_business_date => v_d1 + 1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 31.40, p_business_date => v_d1 + 1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -20.00,
    p_business_date => v_d1 + 1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -20.00,
    p_business_date => v_d1 + 2, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'WASTE', p_qty_delta => -11.40,
    p_business_date => v_d1 + 3, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -20.00,
    p_business_date => v_d1 + 4, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);

  select sum(consumed_kg) into v_sum from v_meat_cost_attribution where lot_id = v_lotA;
  assert v_sum = 75.00, format('TC-13: lot A''s atoms consume %s kg, expected 75.00', v_sum);
  select sum(meat_cost_thb) as meat, sum(brine_cost_thb) as brine, sum(smoke_fee_thb) as smoke,
         sum(freight_thb) as freight, sum(attributed_cost_thb) as total,
         count(*) filter (where over_consumed) as over_n
    into v_row
    from v_meat_cost_attribution where lot_id = v_lotA;
  assert v_row.meat = 25000.00 and v_row.brine = 200.00 and v_row.smoke = 5000.00
     and v_row.freight = 900.00 and v_row.total = 31100.00 and v_row.over_n = 0,
    format('TC-13: lot A sums to %s / %s / %s / %s = %s (%s over-consumed) — expected 25000.00 / 200.00 / 5000.00 / 900.00 = 31100.00, exactly',
           v_row.meat, v_row.brine, v_row.smoke, v_row.freight, v_row.total, v_row.over_n);
  select meat_cost_thb into v_amt from v_meat_cost_attribution
   where lot_id = v_lotA and business_date = v_d1 and consumption_kind = 'SALE';
  assert v_amt = 1000.00, format('TC-13: later atoms moved D1''s SALE atom to %s', v_amt);

  --------------------------------------------------------------------------------- TC-17
  -- An opening lot: 2.00 kg of a 10.00 kg, 3,000.00 lot is 600.00 of OPENING_STOCK at B1.
  select * into v_row from v_cost_breakdown
   where lot_id = v_lotO and category = 'OPENING_STOCK' and cost_date = v_d1 + 1;
  assert v_row.amount_thb = 600.00 and v_row.location_id = v_b1 and v_row.consumed_kg = 2.00
     and v_row.is_complete,
    format('TC-17: lot O''s OPENING_STOCK reads %s over %s kg, complete %s — expected 600.00, 2.00, true',
           v_row.amount_thb, v_row.consumed_kg, v_row.is_complete);
  select count(*) into v_n from v_cost_breakdown where lot_id = v_lotO and category <> 'OPENING_STOCK';
  assert v_n = 0, format('TC-17: opening lot O carries %s non-opening cost row(s)', v_n);

  -- Failure half: an opening row with no opening_costs row is null and named, never 0.
  select * into v_row from v_cost_breakdown where lot_id = v_lotO2 and category = 'OPENING_STOCK';
  assert v_row.amount_thb is null and v_row.missing_inputs = array['OPENING_COST']::text[]
     and not v_row.is_complete,
    format('TC-17: uncosted lot O2 reads %s, missing %s, complete %s — expected null, {OPENING_COST}, false',
           v_row.amount_thb, v_row.missing_inputs, v_row.is_complete);

  --------------------------------------------------------------------------------- TC-19
  -- Failure case: a SALE of −1.00 corrected to −0.80 through fn_reverse_ledger_entry. The atom
  -- nets to 0.80 and stays a SALE; nothing is filed under REVERSAL.
  v_led := fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -1.00,
    p_business_date => v_d1 + 2, p_lot_id => v_lotO);
  perform fn_reverse_ledger_entry(gen_random_uuid(), v_led, -0.80, 'แก้ยอดขายที่คีย์ผิด');
  select * into v_row from v_meat_consumption
   where lot_id = v_lotO and business_date = v_d1 + 2 and location_id = v_b1;
  assert v_row.consumed_kg = 0.80 and v_row.consumption_kind = 'SALE',
    format('TC-19: the corrected sale reads %s kg as %s — expected 0.80 as SALE', v_row.consumed_kg, v_row.consumption_kind);
  select count(*) into v_n from v_meat_consumption where consumption_kind not in ('SALE', 'WASTE', 'GIVEAWAY');
  assert v_n = 0, format('TC-19: %s consumption row(s) filed under another kind', v_n);

  --------------------------------------------------------------------------------- TC-18
  -- Failure case: a chilli sale dated before any rate exists (the seed starts 2000-01-01) is
  -- null with a named code, never 0.00.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'CHILLI_PASTE',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -1,
    p_business_date => date '1999-12-31', p_product_id => v_chilli);
  select * into v_row from v_cost_breakdown
   where cost_date = date '1999-12-31' and location_id = v_b2 and category = 'CHILLI_PASTE';
  assert v_row.amount_thb is null and v_row.consumed_tubes = 1 and not v_row.is_complete
     and v_row.missing_inputs = array['CONFIG:chilli_paste_cost_thb_per_tube']::text[],
    format('TC-18: a chilli sale with no rate reads %s, complete %s, missing %s',
           v_row.amount_thb, v_row.is_complete, v_row.missing_inputs);

  --------------------------------------------------------------------------------- TC-20
  -- Failure case: rice with no cost_thb is null and named; with 20.00 set it is 50.00.
  select * into v_row from v_cost_breakdown
   where cost_date = v_d1 and location_id = v_b1 and category = 'PRODUCT_COST';
  assert v_row.amount_thb is null and v_row.sold_qty = 2.50 and not v_row.is_complete
     and v_row.missing_inputs = array['PRODUCT_COST:RICE_KG']::text[],
    format('TC-20: unpriced rice reads %s over %s, missing %s', v_row.amount_thb, v_row.sold_qty, v_row.missing_inputs);
  insert into product_prices (product_id, price_thb, cost_thb, effective_from, created_by)
    values (v_rice, 60.00, 20.00, v_d1 - 10, v_owner);
  select * into v_row from v_cost_breakdown
   where cost_date = v_d1 and location_id = v_b1 and category = 'PRODUCT_COST';
  assert v_row.amount_thb = 50.00 and v_row.is_complete and cardinality(v_row.missing_inputs) = 0,
    format('TC-20: rice at 20.00/kg reads %s, complete %s', v_row.amount_thb, v_row.is_complete);

  --------------------------------------------------------------------------------- TC-22
  -- R36: a branch-scoped rate beats a newer global one. B1 gets its own 14.00 dated D1 − 60;
  -- the global 15.00 dated D1 − 30 is newer. B2 has no scoped row and keeps the global.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'CHILLI_PASTE',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -2,
    p_business_date => v_d1, p_product_id => v_chilli);
  perform fn_set_config(gen_random_uuid(), 'chilli_paste_cost_thb_per_tube', v_d1 - 60,
                        p_value_numeric => 14.00, p_scope_location_id => v_b1);
  select amount_thb into v_amt from v_cost_breakdown
   where cost_date = v_d1 and location_id = v_b1 and category = 'CHILLI_PASTE';
  assert v_amt = 70.00, format('TC-22: B1''s 5 tubes read %s, expected 70.00 at its own 14.00', v_amt);
  select amount_thb into v_amt from v_cost_breakdown
   where cost_date = v_d1 and location_id = v_b2 and category = 'CHILLI_PASTE';
  assert v_amt = 30.00, format('TC-22: B2''s 2 tubes read %s, expected 30.00 at the global 15.00', v_amt);

  --------------------------------------------------------------------------------- TC-21
  -- BR23, R12, failure case (on B2, which has no scoped row): a rate dated after D1 moves
  -- nothing; a row dated before D1 but written later does, which is date resolution, not
  -- "latest row wins".
  perform fn_set_config(gen_random_uuid(), 'chilli_paste_cost_thb_per_tube', v_d1 + 1,
                        p_value_numeric => 18.00);
  select amount_thb into v_amt from v_cost_breakdown
   where cost_date = v_d1 and location_id = v_b2 and category = 'CHILLI_PASTE';
  assert v_amt = 30.00, format('TC-21: a rate dated D1 + 1 moved D1 to %s, expected 30.00', v_amt);
  perform fn_set_config(gen_random_uuid(), 'chilli_paste_cost_thb_per_tube', v_d1 - 1,
                        p_value_numeric => 16.00);
  select amount_thb into v_amt from v_cost_breakdown
   where cost_date = v_d1 and location_id = v_b2 and category = 'CHILLI_PASTE';
  assert v_amt = 32.00, format('TC-21: a rate dated D1 − 1 left D1 at %s, expected 32.00', v_amt);

  --------------------------------------------------------------------------------- TC-23
  -- M11, ADR-020: owner expenses are listed and never in round one's profit. A MONTHLY_FIXED
  -- paid in September for August lands on 1 August.
  insert into owner_expenses (kind, event_date, expense_month, amount_thb, detail, created_by)
    values ('INVESTMENT', v_d1, null, 30000.00, 'ตู้แช่ใหม่', v_owner) returning id into v_inv;
  insert into owner_expenses (kind, event_date, expense_month, amount_thb, detail, created_by)
    values ('MONTHLY_FIXED', date '2026-09-04', '2026-08', 12000.00, 'ค่าเช่าที่เดือน ส.ค.', v_owner)
    returning id into v_mfx;
  select * into v_row from v_cost_breakdown where source_id = v_inv;
  assert v_row.category = 'INVESTMENT' and v_row.amount_thb = 30000.00 and v_row.cost_date = v_d1
     and v_row.cost_month = '2026-08' and not v_row.in_pnl_round_one,
    format('TC-23: the investment reads %s %s on %s (%s), in P&L %s',
           v_row.category, v_row.amount_thb, v_row.cost_date, v_row.cost_month, v_row.in_pnl_round_one);
  select * into v_row from v_cost_breakdown where source_id = v_mfx;
  assert v_row.category = 'MONTHLY_FIXED' and v_row.amount_thb = 12000.00
     and v_row.cost_date = date '2026-08-01' and v_row.cost_month = '2026-08' and not v_row.in_pnl_round_one,
    format('TC-23: the monthly fixed cost reads %s %s on %s (%s), in P&L %s',
           v_row.category, v_row.amount_thb, v_row.cost_date, v_row.cost_month, v_row.in_pnl_round_one);
  select count(*) into v_n from v_cost_breakdown
   where category in ('INVESTMENT', 'MONTHLY_FIXED', 'OWNER_OTHER') and in_pnl_round_one;
  assert v_n = 0, format('TC-23: %s owner-expense row(s) marked in_pnl_round_one', v_n);

  --------------------------------------------------------------------------------- TC-24
  -- Failure case: no LABOUR row, ever, even with staff and attendance on file (D04, F17).
  insert into staff (name, location_id, employment_type) values ('พนักงานรายวัน', v_b1, 'DAILY')
    returning id into v_staff;
  insert into attendance (staff_id, location_id, event_date, status, recorded_by)
    values (v_staff, v_b1, v_d1, 'PRESENT', v_owner);
  select count(*) into v_n from v_cost_breakdown where category = 'LABOUR';
  assert v_n = 0, format('TC-24: %s LABOUR row(s)', v_n);
  select count(*) into v_n from v_cost_breakdown
   where category not in ('MEAT', 'BRINE', 'SMOKE_FEE', 'TRANSPORT', 'OPENING_STOCK', 'CHILLI_PASTE',
                          'PRODUCT_COST', 'PACKAGING', 'BRANCH_EXPENSE',
                          'INVESTMENT', 'MONTHLY_FIXED', 'OWNER_OTHER');
  assert v_n = 0, format('TC-24: %s row(s) in a category nobody declared', v_n);

  -------------------------------------------------------------------- RLS, as `authenticated`
  set local role authenticated;

  -- The Owner reads the cost chain as a real session: no view here needs a function grant.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_cost_breakdown where location_id = v_b1 and cost_date = v_d1;
  assert v_n >= 11, format('TC-R1: the Owner reads %s of B1''s D1 cost rows as authenticated', v_n);

  -- TC-R3: a branch admin reads no cost row at all.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  foreach v_view in array v_views loop
    execute format('select count(*) from %I', v_view) into v_n;
    assert v_n = 0, format('TC-R3: B1''s admin reads %s row(s) from %s', v_n, v_view);
  end loop;

  -- TC-R5: nor does the chef-house operator (R20, BR15: no price, no yield).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  foreach v_view in array v_views loop
    execute format('select count(*) from %I', v_view) into v_n;
    assert v_n = 0, format('TC-R5: the L3 reads %s row(s) from %s', v_n, v_view);
  end loop;

  -- TC-R6, failure case: a deactivated Owner reads nothing.
  reset role;
  update profiles set is_active = false where id = v_owner;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  foreach v_view in array v_views loop
    execute format('select count(*) from %I', v_view) into v_n;
    assert v_n = 0, format('TC-R6: a deactivated Owner reads %s row(s) from %s', v_n, v_view);
  end loop;

  reset role;

  raise exception 'REPORTS_COST_TEST_PASSED';   -- the only clean way back out
end $$;
