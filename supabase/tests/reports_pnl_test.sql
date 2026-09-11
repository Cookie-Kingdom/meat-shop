-- Card ^ref-57 — v_pnl, v_pnl_monthly, v_pnl_by_lot. TC-25 ... TC-35 and TC-R3, TC-R5, TC-R6
-- of v.0.1/ready-ref-55-58-reporting/TDD-reporting.md §57.
-- Contract assumed from an unmerged lane: none (everything read is on develop at aec8aec, plus
-- K's own 200 and 210–213).
--
-- F1 AGAIN, BUILT THE SAME WAY AS reports_cost_test.sql: lot A through the real chain (31,100.00,
-- complete, output 75.00), 4.00 kg of it moved to B1 READY by inert TRANSFER rows, then the
-- reference day at B1 on D1 — 12 boxes (−3.00 kg), a −0.60 kg WASTE, 5 chilli tubes, 2.50 kg of
-- rice with no cost set, and 100.00 ICE + 50.00 PACKAGING. D1 is CLOSED, D1 + 1 is an OPEN report
-- with no sales. Lot C is the minimal lot of the cost test: priced, closed by an UPDATE, no
-- transport — its cost can never be complete here.
--
-- ORDER MATTERS BELOW, because later steps consume lot A: TC-33 reads it with stock on hand,
-- TC-30 adds a reversal on a day with no report, TC-34 sells the rest.
--
-- One do $$ block; the transaction aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/reports_pnl_test.sql

do $$
declare
  v_owner   uuid := gen_random_uuid();
  v_l2a     uuid := gen_random_uuid();
  v_l3      uuid := gen_random_uuid();
  v_day     date := date '2026-05-04';
  v_d1      date := date '2026-08-10';
  v_chef    uuid;
  v_central uuid;
  v_b1      uuid;
  v_b2      uuid;
  v_sup     uuid;
  v_po      uuid;
  v_poC     uuid;
  v_lotA    uuid;
  v_lotC    uuid;
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
  v_row     record;
  v_n       bigint;
  v_p220    numeric;
  v_p221    numeric;
  v_p222    numeric;
  v_sum     numeric;
  v_sum2    numeric;
  v_ok      boolean;
  v_view    text;
  v_views   text[] := array['v_pnl', 'v_pnl_monthly', 'v_pnl_by_lot'];
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2a), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',               'L1_OWNER',        true),
    (v_l2a,   'แอดมินสาขาหนึ่ง',        'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',    'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind) values ('K57-CH', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('K57-CEN', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  insert into locations (code, name_th, kind) values ('K57-B1', 'สาขาหนึ่ง', 'BRANCH')
    returning id into v_b1;
  insert into locations (code, name_th, kind) values ('K57-B2', 'สาขาสอง', 'BRANCH')
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

  -- Lot A, the real chain (F1; reports_cost_test.sql's recipe).
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

  select * into v_row from v_lot_unit_cost where lot_id = v_lotA;
  assert v_row.cost_is_complete and v_row.total_cost_thb = 31100.00 and v_row.output_kg = 75.00,
    format('fixture: lot A reads complete=%s, total %s, output %s, missing %s',
           v_row.cost_is_complete, v_row.total_cost_thb, v_row.output_kg, v_row.missing_inputs);

  -- Lot C, minimal: priced, closed by an UPDATE, no transport (so never complete).
  v_poC  := fn_create_po(gen_random_uuid(), v_sup, v_day, 4.00, 250.00);
  v_lotC := fn_add_po_delivery(gen_random_uuid(), v_poC, v_day, 4.00, v_chef);
  update lots set state = 'LOT_CLOSED', closed_at = now(), loss_weight_kg = 1.00 where id = v_lotC;

  -- Inert movements: 4.00 kg of lot A to B1 READY, lot C to B2 READY, chilli to B1.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_central, p_stock_state => 'FROZEN', p_movement_type => 'TRANSFER_OUT',
    p_qty_delta => -4.00, p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 4.00, p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 3.00, p_business_date => v_d1, p_lot_id => v_lotC);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'CHILLI_PASTE',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 10, p_business_date => v_d1, p_product_id => v_chilli);

  -- The reference day, B1 on D1. An OPEN report on D1 + 1 with no sales follows D1's close.
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by) values
    (v_b1, v_d1, v_d1 + time '09:00', 'OPEN', v_owner) returning id into v_r1d1;

  insert into sales_lines (daily_report_id, product_id, lot_id, smoke_date_group_id, qty,
                           unit_price_thb, pack_weight_kg, channel, created_by)
    values (v_r1d1, v_box, v_lotA, v_gA, 12, 350.00, 0.25, 'LINE_MAN', v_owner) returning id into v_sl;
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -3.00,
    p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA,
    p_source_table => 'sales_lines', p_source_id => v_sl);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'WASTE', p_qty_delta => -0.60,
    p_business_date => v_d1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, channel, created_by)
    values (v_r1d1, v_chilli, 5, 25.00, 'LINE_MAN', v_owner) returning id into v_sl;
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'CHILLI_PASTE',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -5,
    p_business_date => v_d1, p_product_id => v_chilli,
    p_source_table => 'sales_lines', p_source_id => v_sl);
  insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, channel, created_by)
    values (v_r1d1, v_rice, 2.50, 60.00, 'LINE_MAN', v_owner);
  insert into branch_expenses (daily_report_id, category, amount_thb, paid_by_person, created_by) values
    (v_r1d1, 'ICE',       100.00, 'สมชาย', v_owner),
    (v_r1d1, 'PACKAGING',  50.00, 'สมชาย', v_owner);
  update daily_reports set status = 'CLOSED', closed_by = v_owner, closed_at = now() where id = v_r1d1;
  -- D1 + 1 opens only now: one OPEN report per branch (daily_reports_one_open).
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by) values
    (v_b1, v_d1 + 1, v_d1 + 1 + time '09:00', 'OPEN', v_owner) returning id into v_r1d2;

  --------------------------------------------------------------------------------- TC-25
  select * into v_row from v_pnl where business_date = v_d1 and location_id = v_b1;
  assert v_row.daily_report_id = v_r1d1 and v_row.report_status = 'CLOSED' and v_row.pnl_month = '2026-08',
    format('TC-25: the F1 row names report %s, status %s, month %s', v_row.daily_report_id,
           v_row.report_status, v_row.pnl_month);
  assert v_row.revenue_thb = 4475.00,
    format('TC-25: revenue reads %s, expected 4475.00', v_row.revenue_thb);
  assert v_row.meat_cost_thb = 1200.00 and v_row.brine_cost_thb = 9.60 and v_row.smoke_fee_thb = 240.00
     and v_row.freight_thb = 43.20 and v_row.opening_stock_cost_thb = 0.00
     and v_row.chilli_paste_cost_thb = 75.00 and v_row.packaging_thb = 50.00
     and v_row.branch_expense_thb = 100.00,
    format('TC-25: parts read meat %s brine %s smoke %s freight %s opening %s chilli %s packaging %s branch %s',
           v_row.meat_cost_thb, v_row.brine_cost_thb, v_row.smoke_fee_thb, v_row.freight_thb,
           v_row.opening_stock_cost_thb, v_row.chilli_paste_cost_thb, v_row.packaging_thb,
           v_row.branch_expense_thb);
  assert v_row.product_cost_thb is null,
    format('TC-25: unpriced rice reads %s — expected null, never 0.00', v_row.product_cost_thb);
  assert v_row.total_cost_thb = 1717.80 and v_row.profit_round_one_thb = 2757.20,
    format('TC-25: total %s, profit %s — expected 1717.80 and 2757.20', v_row.total_cost_thb,
           v_row.profit_round_one_thb);
  assert not v_row.is_complete and 'PRODUCT_COST:RICE_KG' = any (v_row.missing_inputs),
    format('TC-25: complete %s, missing %s — expected false with PRODUCT_COST:RICE_KG',
           v_row.is_complete, v_row.missing_inputs);

  --------------------------------------------------------------------------------- TC-28
  -- Failure case: an OPEN day is never complete, whatever its numbers.
  select * into v_row from v_pnl where business_date = v_d1 + 1 and location_id = v_b1;
  assert v_row.daily_report_id = v_r1d2 and v_row.revenue_thb = 0.00 and not v_row.is_complete
     and 'REPORT_OPEN' = any (v_row.missing_inputs),
    format('TC-28: the open day reads report %s, revenue %s, complete %s, missing %s',
           v_row.daily_report_id, v_row.revenue_thb, v_row.is_complete, v_row.missing_inputs);

  --------------------------------------------------------------------------------- TC-26
  insert into product_prices (product_id, price_thb, cost_thb, effective_from, created_by)
    values (v_rice, 60.00, 20.00, v_d1 - 10, v_owner);
  select * into v_row from v_pnl where business_date = v_d1 and location_id = v_b1;
  assert v_row.product_cost_thb = 50.00 and v_row.total_cost_thb = 1767.80
     and v_row.profit_round_one_thb = 2707.20,
    format('TC-26: with rice at 20.00 the day reads product %s, total %s, profit %s',
           v_row.product_cost_thb, v_row.total_cost_thb, v_row.profit_round_one_thb);
  assert v_row.is_complete and cardinality(v_row.missing_inputs) = 0,
    format('TC-26: a closed, fully priced day reads complete %s, missing %s',
           v_row.is_complete, v_row.missing_inputs);

  --------------------------------------------------------------------------------- TC-27
  -- UAT-17: the scope is on every row's face and in the view's own comment.
  select count(*) into v_n from v_pnl
   where revenue_source is distinct from 'LINE_MAN'
      or scope_excludes is distinct from '{TAX,CENTRAL_OVERHEAD,LABOUR}'::text[];
  assert v_n = 0, format('TC-27: %s v_pnl row(s) do not state round one''s scope', v_n);
  select count(*) into v_n from v_pnl_monthly
   where revenue_source is distinct from 'LINE_MAN'
      or scope_excludes is distinct from '{TAX,CENTRAL_OVERHEAD,LABOUR}'::text[];
  assert v_n = 0, format('TC-27: %s v_pnl_monthly row(s) do not state round one''s scope', v_n);
  assert obj_description('public.v_pnl'::regclass, 'pg_class') like '%D04%',
    'TC-27: v_pnl''s comment does not cite D04';

  --------------------------------------------------------------------------------- TC-33
  -- Lot A with stock on hand: 75.00 − 3.00 − 0.60 = 71.40 remains, and its cost stays on the lot.
  select * into v_row from v_pnl_by_lot where lot_id = v_lotA;
  assert v_row.sold_kg = 3.00 and v_row.wasted_kg = 0.60 and v_row.remaining_kg = 71.40,
    format('TC-33: lot A reads sold %s, wasted %s, remaining %s — expected 3.00, 0.60, 71.40',
           v_row.sold_kg, v_row.wasted_kg, v_row.remaining_kg);
  assert v_row.meat_revenue_thb = 4200.00 and v_row.attributed_cost_thb = 1492.80
     and v_row.lot_total_cost_thb = 31100.00 and v_row.unattributed_cost_thb = 29607.20
     and v_row.profit_round_one_thb = 2707.20,
    format('TC-33: lot A reads revenue %s, attributed %s, total %s, unattributed %s, profit %s',
           v_row.meat_revenue_thb, v_row.attributed_cost_thb, v_row.lot_total_cost_thb,
           v_row.unattributed_cost_thb, v_row.profit_round_one_thb);
  assert v_row.cost_is_complete and not v_row.is_complete
     and 'STOCK_REMAINING' = any (v_row.missing_inputs),
    format('TC-33: lot A with stock left reads cost complete %s, complete %s, missing %s',
           v_row.cost_is_complete, v_row.is_complete, v_row.missing_inputs);

  --------------------------------------------------------------------------------- TC-35
  -- The lot view carries meat lines only: chilli (125.00) and rice (150.00) are on no lot.
  select count(*) into v_n from v_pnl_by_lot where not ('NON_MEAT_LINES' = any (scope_excludes));
  assert v_n = 0, format('TC-35: %s lot row(s) do not exclude NON_MEAT_LINES', v_n);
  select sum(meat_revenue_thb) into v_sum from v_pnl_by_lot;
  select sum(revenue_thb) into v_sum2 from v_daily_sales where item_type = 'SMOKED_MEAT';
  assert v_sum = 4200.00 and v_sum = v_sum2,
    format('TC-35: lots carry %s of revenue, meat sales are %s — expected 4200.00 both', v_sum, v_sum2);

  --------------------------------------------------------------------------------- TC-29
  -- Failure case, M11: 42,000.00 of owner expenses moves no profit anywhere.
  select sum(profit_round_one_thb) into v_p220 from v_pnl;
  select sum(profit_round_one_thb) into v_p221 from v_pnl_monthly;
  select sum(profit_round_one_thb) into v_p222 from v_pnl_by_lot;
  insert into owner_expenses (kind, event_date, expense_month, location_id, amount_thb, detail, created_by) values
    ('INVESTMENT',    v_d1,              null,      null, 30000.00, 'ตู้แช่ใหม่',           v_owner),
    ('MONTHLY_FIXED', date '2026-09-04', '2026-08', v_b1, 12000.00, 'ค่าเช่าที่เดือน ส.ค.', v_owner);
  select count(*) into v_n from v_cost_breakdown
   where category in ('INVESTMENT', 'MONTHLY_FIXED') and not in_pnl_round_one;
  assert v_n = 2, format('fixture: the owner expenses show %s memo row(s) in 213, expected 2', v_n);
  select sum(profit_round_one_thb) into v_sum from v_pnl;
  assert v_sum = v_p220, format('TC-29: owner expenses moved Σ v_pnl profit from %s to %s', v_p220, v_sum);
  select sum(profit_round_one_thb) into v_sum from v_pnl_monthly;
  assert v_sum = v_p221, format('TC-29: owner expenses moved Σ v_pnl_monthly profit from %s to %s', v_p221, v_sum);
  select sum(profit_round_one_thb) into v_sum from v_pnl_by_lot;
  assert v_sum = v_p222, format('TC-29: owner expenses moved Σ v_pnl_by_lot profit from %s to %s', v_p222, v_sum);

  --------------------------------------------------------------------------------- TC-30
  -- Failure case: a WASTE on a day nobody opened, corrected by a reversal. The day still has a
  -- row, says why it is incomplete, and its cost is not lost.
  v_led := fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'WASTE', p_qty_delta => -0.20,
    p_business_date => v_d1 + 5, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_reverse_ledger_entry(gen_random_uuid(), v_led, -0.10, 'แก้น้ำหนักทิ้งที่คีย์ผิด');
  select * into v_row from v_pnl where business_date = v_d1 + 5 and location_id = v_b1;
  assert v_row.location_id = v_b1 and v_row.daily_report_id is null
     and 'NO_DAILY_REPORT' = any (v_row.missing_inputs) and not v_row.is_complete,
    format('TC-30: the unreported day reads report %s, complete %s, missing %s',
           v_row.daily_report_id, v_row.is_complete, v_row.missing_inputs);
  assert v_row.meat_cost_thb > 0 and v_row.total_cost_thb > 0 and v_row.revenue_thb = 0.00,
    format('TC-30: the unreported day''s 0.10 kg costs meat %s, total %s (revenue %s) — its cost was lost',
           v_row.meat_cost_thb, v_row.total_cost_thb, v_row.revenue_thb);

  --------------------------------------------------------------------------------- TC-34
  -- Failure case: a sold-out lot is complete only when its cost is. Lot C (no freight) sells
  -- out and stays incomplete; lot A (cost complete) sells out and becomes complete, with every
  -- baht attributed.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -3.00,
    p_business_date => v_d1 + 2, p_lot_id => v_lotC);
  select * into v_row from v_pnl_by_lot where lot_id = v_lotC;
  assert v_row.remaining_kg = 0.00 and not v_row.cost_is_complete and not v_row.is_complete
     and not ('STOCK_REMAINING' = any (v_row.missing_inputs)),
    format('TC-34: sold-out lot C with no freight reads remaining %s, cost complete %s, complete %s, missing %s',
           v_row.remaining_kg, v_row.cost_is_complete, v_row.is_complete, v_row.missing_inputs);

  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_central, p_stock_state => 'FROZEN', p_movement_type => 'TRANSFER_OUT',
    p_qty_delta => -71.00, p_business_date => v_d1 + 6, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 71.00, p_business_date => v_d1 + 6, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -71.00,
    p_business_date => v_d1 + 6, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -0.30,
    p_business_date => v_d1 + 6, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  select * into v_row from v_pnl_by_lot where lot_id = v_lotA;
  assert v_row.remaining_kg = 0.00 and v_row.is_complete and cardinality(v_row.missing_inputs) = 0
     and v_row.attributed_cost_thb = 31100.00 and v_row.unattributed_cost_thb = 0.00,
    format('TC-34: sold-out lot A reads remaining %s, complete %s, missing %s, attributed %s, unattributed %s',
           v_row.remaining_kg, v_row.is_complete, v_row.missing_inputs, v_row.attributed_cost_thb,
           v_row.unattributed_cost_thb);

  --------------------------------------------------------------------------------- TC-31
  -- The month is the sum of its days, column by column, with the same null rule (a part unknown
  -- on any day is unknown for the month).
  select count(*) into v_n
    from v_pnl_monthly m
    join (select p.pnl_month, p.location_id,
                 sum(p.revenue_thb) as rev,
                 case when bool_and(p.meat_cost_thb          is not null) then sum(p.meat_cost_thb)          end as meat,
                 case when bool_and(p.brine_cost_thb         is not null) then sum(p.brine_cost_thb)         end as brine,
                 case when bool_and(p.smoke_fee_thb          is not null) then sum(p.smoke_fee_thb)          end as smoke,
                 case when bool_and(p.freight_thb            is not null) then sum(p.freight_thb)            end as freight,
                 case when bool_and(p.opening_stock_cost_thb is not null) then sum(p.opening_stock_cost_thb) end as opening,
                 case when bool_and(p.chilli_paste_cost_thb  is not null) then sum(p.chilli_paste_cost_thb)  end as chilli,
                 case when bool_and(p.product_cost_thb       is not null) then sum(p.product_cost_thb)       end as product,
                 case when bool_and(p.packaging_thb          is not null) then sum(p.packaging_thb)          end as packaging,
                 case when bool_and(p.branch_expense_thb     is not null) then sum(p.branch_expense_thb)     end as branch_exp,
                 sum(p.total_cost_thb) as total,
                 sum(p.profit_round_one_thb) as profit
            from v_pnl p
           group by p.pnl_month, p.location_id) d
      on d.pnl_month = m.pnl_month and d.location_id = m.location_id
   where m.revenue_thb            is distinct from d.rev
      or m.meat_cost_thb          is distinct from d.meat
      or m.brine_cost_thb         is distinct from d.brine
      or m.smoke_fee_thb          is distinct from d.smoke
      or m.freight_thb            is distinct from d.freight
      or m.opening_stock_cost_thb is distinct from d.opening
      or m.chilli_paste_cost_thb  is distinct from d.chilli
      or m.product_cost_thb       is distinct from d.product
      or m.packaging_thb          is distinct from d.packaging
      or m.branch_expense_thb     is distinct from d.branch_exp
      or m.total_cost_thb         is distinct from d.total
      or m.profit_round_one_thb   is distinct from d.profit;
  assert v_n = 0, format('TC-31: %s monthly row(s) differ from the sum of their days', v_n);
  select count(*) into v_n from v_pnl_monthly;
  select count(*) into v_sum from (select distinct pnl_month, location_id from v_pnl) x;
  assert v_n = v_sum, format('TC-31: %s monthly rows for %s (month, branch) pairs', v_n, v_sum);
  select * into v_row from v_pnl_monthly where pnl_month = '2026-08' and location_id = v_b1;
  assert v_row.days_reported = 2 and v_row.days_closed = 1 and not v_row.is_complete,
    format('TC-31: B1''s August reads %s reported, %s closed, complete %s',
           v_row.days_reported, v_row.days_closed, v_row.is_complete);

  --------------------------------------------------------------------------------- TC-32
  -- Cross-dimension reconcile: the lots and the days are the same atoms, grouped two ways.
  -- Known parts on both sides: attributed_cost_thb is 212's sum of known parts, and lot C's day
  -- carries a null (unknown) freight part that must not drop the whole row from the sum.
  select sum(attributed_cost_thb) into v_sum from v_pnl_by_lot;
  select sum(coalesce(meat_cost_thb, 0) + coalesce(brine_cost_thb, 0) + coalesce(smoke_fee_thb, 0)
             + coalesce(freight_thb, 0) + coalesce(opening_stock_cost_thb, 0))
    into v_sum2 from v_pnl;
  assert v_sum = v_sum2,
    format('TC-32: Σ lot attributed cost %s <> Σ day meat-side cost %s', v_sum, v_sum2);
  select sum(meat_revenue_thb) into v_sum from v_pnl_by_lot;
  select sum(revenue_thb) into v_sum2 from v_daily_sales where item_type = 'SMOKED_MEAT';
  assert v_sum = v_sum2, format('TC-32: Σ lot meat revenue %s <> Σ meat sales %s', v_sum, v_sum2);

  -------------------------------------------------------------------- RLS, as `authenticated`
  set local role authenticated;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_pnl where location_id = v_b1;
  assert v_n >= 3, format('TC-R1: the Owner reads %s B1 P&L row(s) as authenticated', v_n);

  -- TC-R3: a branch admin reads no profit at all.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  foreach v_view in array v_views loop
    execute format('select count(*) from %I', v_view) into v_n;
    assert v_n = 0, format('TC-R3: B1''s admin reads %s row(s) from %s', v_n, v_view);
  end loop;

  -- TC-R5: nor does the chef-house operator.
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

  raise exception 'REPORTS_PNL_TEST_PASSED';   -- the only clean way back out
end $$;
