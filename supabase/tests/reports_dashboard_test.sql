-- Card ^ref-58 — v_yield_loss_daily, v_owner_exceptions, v_sales_trace. TC-36 ... TC-41 and
-- TC-R3, TC-R5 (all fourteen K views), TC-R6 of v.0.1/ready-ref-55-58-reporting/TDD-reporting.md §58.
-- Contract assumed from an unmerged lane: none (080/090 lane F, 150 lane C, 160/161 lane D,
-- 170/171 lane E — all on develop at aec8aec).
--
-- FIXTURES ARE MINIMAL WHERE THE CHAIN IS NOT UNDER TEST. The yield lots (F4) are real POs and
-- deliveries closed by one UPDATE each (state, closed_at, loss_weight_kg), with the YIELD_ALERT
-- fn_close_lot would have written inserted directly. The transport lines go through the real
-- dispatch and receipt RPCs, because the variance reason is fn_confirm_transport_receipt's rule.
-- Counts and packaging rows are inserted directly (an ad-hoc count has no daily report, so
-- fn_guard_report_closed does not apply). Ledger rows go through fn_post_ledger as the Owner.
--
-- One do $$ block; the transaction aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/reports_dashboard_test.sql

do $$
declare
  v_owner   uuid := gen_random_uuid();
  v_l2a     uuid := gen_random_uuid();
  v_l3      uuid := gen_random_uuid();
  v_day     date := date '2026-05-04';
  v_d       date := date '2026-08-20';
  v_chef    uuid;
  v_central uuid;
  v_b1      uuid;
  v_b2      uuid;
  v_sup     uuid;
  v_po      uuid;
  v_y1      uuid;
  v_y2      uuid;
  v_y3      uuid;
  v_gY2     uuid;
  v_t1      uuid;
  v_t2      uuid;
  v_t3      uuid;
  v_run     uuid;
  v_ln1     uuid;
  v_ln2     uuid;
  v_ln3     uuid;
  v_lotO    uuid;
  v_note    uuid;
  v_rep     uuid;
  v_box     uuid;
  v_rice    uuid;
  v_sl1     uuid;
  v_sl2     uuid;
  v_pk      uuid;
  v_cnt1    uuid;
  v_cnt2    uuid;
  v_row     record;
  v_exp     record;
  v_n       bigint;
  v_view    text;
  v_mine    text[] := array['v_yield_loss_daily', 'v_owner_exceptions', 'v_sales_trace'];
  v_all     text[] := array['v_daily_sales', 'v_daily_sales_qty', 'v_monthly_summary',
                            'v_monthly_summary_qty', 'v_meat_consumption', 'v_lot_unit_cost',
                            'v_meat_cost_attribution', 'v_cost_breakdown', 'v_pnl',
                            'v_pnl_monthly', 'v_pnl_by_lot', 'v_yield_loss_daily',
                            'v_owner_exceptions', 'v_sales_trace'];
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2a), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',               'L1_OWNER',        true),
    (v_l2a,   'แอดมินสาขาหนึ่ง',        'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',    'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind) values ('K58-CH', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('K58-CEN', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  insert into locations (code, name_th, kind) values ('K58-B1', 'สาขาหนึ่ง', 'BRANCH')
    returning id into v_b1;
  insert into locations (code, name_th, kind) values ('K58-B2', 'สาขาสอง', 'BRANCH')
    returning id into v_b2;
  insert into user_locations (profile_id, location_id) values (v_l2a, v_b1), (v_l3, v_chef);
  insert into suppliers (name) values ('ฟู้ดดีว่า') returning id into v_sup;

  select id into v_box  from products where code = 'MEAT_BOX';
  select id into v_rice from products where code = 'RICE_KG';

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', date '2026-01-01',
                        p_value_text => 'BY_LOT_WEIGHT');
  perform fn_set_config(gen_random_uuid(), 'yield_alert_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);

  v_po := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);

  ----------------------------------------------------------------- F4: three lots close
  v_y1 := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_y2 := fn_add_po_delivery(gen_random_uuid(), v_po, v_day,  50.00, v_chef);
  v_y3 := fn_add_po_delivery(gen_random_uuid(), v_po, v_day,  40.00, v_chef);
  -- Y2's smoke-date group exists before it closes (fn_guard_lot_closed); TC-41 sells from it.
  insert into smoke_date_groups (lot_id, smoke_date) values (v_y2, date '2026-08-18')
    returning id into v_gY2;
  -- Y1 and Y2 close on 20 Aug in Bangkok. Y1 is back at central with its cost incomplete.
  update lots set state = 'CENTRAL_STOCK', closed_at = timestamptz '2026-08-20 03:00:00+00',
                  loss_weight_kg = 25.00 where id = v_y1;
  update lots set state = 'LOT_CLOSED', closed_at = timestamptz '2026-08-20 04:00:00+00',
                  loss_weight_kg = 5.00 where id = v_y2;
  -- Y3 closes at 18:30 UTC on 9 Sep, which is 01:30 on 10 Sep in Bangkok.
  update lots set state = 'LOT_CLOSED', closed_at = timestamptz '2026-09-09 18:30:00+00',
                  loss_weight_kg = 8.00 where id = v_y3;
  -- The alert fn_close_lot writes past threshold: Y1 lost 25%.
  insert into notifications (kind, target_role, lot_id, payload)
    values ('YIELD_ALERT', 'L1_OWNER', v_y1, jsonb_build_object('loss_pct', 25.00))
    returning id into v_note;

  --------------------------------------------------------------------- transport lines
  v_t1 := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_t2 := fn_add_po_delivery(gen_random_uuid(), v_po, v_day,  50.00, v_chef);
  v_t3 := fn_add_po_delivery(gen_random_uuid(), v_po, v_day,  40.00, v_chef);
  update lots set assigned_operator_id = v_l3 where id in (v_t1, v_t2, v_t3);
  v_run := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', v_day + 1,
                                   'รถห้องเย็น', false, 1900.00);
  v_ln1 := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_t1, null, null, v_chef, 100.00);
  v_ln2 := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_t2, null, null, v_chef,  50.00);
  v_ln3 := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_t3, null, null, v_chef,  40.00);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  -- T1: exactly what was sent, no reason. T2: 30% short, so a reason is required and given.
  -- T3: never received.
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_ln1, v_day + 2, 100.00);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_ln2, v_day + 2, 35.00,
                                       'น้ำแข็งละลายระหว่างทาง');
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------- the branches on day D
  insert into lots (lot_code, is_opening, state, event_date)
    values ('K58-OPEN', true, 'CENTRAL_STOCK', v_d - 40) returning id into v_lotO;

  -- B1: 10 kg of Y2 thawed in, and 6 kg sold (5.00 of Y2, 1.00 of opening lot O out of 2.00
  -- moved in) → ready_in 12, out 6, 50% off: OVER_THRESHOLD.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'FROZEN', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 10.00, p_business_date => v_d, p_lot_id => v_y2, p_smoke_date_group_id => v_gY2);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'FROZEN', p_movement_type => 'THAW_OUT',
    p_qty_delta => -10.00, p_business_date => v_d, p_lot_id => v_y2, p_smoke_date_group_id => v_gY2);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'THAW_IN',
    p_qty_delta => 10.00, p_business_date => v_d, p_lot_id => v_y2, p_smoke_date_group_id => v_gY2);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 2.00, p_business_date => v_d, p_lot_id => v_lotO);

  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by)
    values (v_b1, v_d, v_d + time '09:00', 'OPEN', v_owner) returning id into v_rep;
  insert into sales_lines (daily_report_id, product_id, lot_id, smoke_date_group_id, qty,
                           unit_price_thb, pack_weight_kg, channel, created_by)
    values (v_rep, v_box, v_y2, v_gY2, 20, 350.00, 0.25, 'LINE_MAN', v_owner) returning id into v_sl1;
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -5.00,
    p_business_date => v_d, p_lot_id => v_y2, p_smoke_date_group_id => v_gY2,
    p_source_table => 'sales_lines', p_source_id => v_sl1);
  insert into sales_lines (daily_report_id, product_id, lot_id, qty, unit_price_thb,
                           pack_weight_kg, channel, created_by)
    values (v_rep, v_box, v_lotO, 4, 350.00, 0.25, 'LINE_MAN', v_owner) returning id into v_sl2;
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b1, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -1.00,
    p_business_date => v_d, p_lot_id => v_lotO, p_source_table => 'sales_lines', p_source_id => v_sl2);
  insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, channel, created_by)
    values (v_rep, v_rice, 1.00, 60.00, 'LINE_MAN', v_owner);

  -- B2: 10 kg of Y3 in, 9 sold → 10% off: WITHIN, not an exception.
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 10.00, p_business_date => v_d, p_lot_id => v_y3);
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_b2, p_stock_state => 'READY', p_movement_type => 'SALE', p_qty_delta => -9.00,
    p_business_date => v_d, p_lot_id => v_y3);

  -- A packaging material, configured at B1 only (full 1,000; the seeded ratio 0.20 → alert
  -- below 200). B1 counts 150 against a system 0: low, and an open variance. B2 counts 500
  -- against 500: matched, and unconfigured there, so is_low is null.
  insert into packaging_items (code, name_th, unit) values ('K58-BOX', 'กล่องทดสอบ', 'ใบ')
    returning id into v_pk;
  insert into packaging_full_stock (packaging_item_id, location_id, full_stock_qty, effective_from, created_by)
    values (v_pk, v_b1, 1000, date '2026-01-01', v_owner);
  insert into physical_counts (location_id, event_date, item_type, packaging_item_id,
                               counted_qty, system_qty, created_by)
    values (v_b1, v_d, 'PACKAGING', v_pk, 150, 0, v_owner) returning id into v_cnt1;
  insert into physical_counts (location_id, event_date, item_type, packaging_item_id,
                               counted_qty, system_qty, created_by)
    values (v_b2, v_d, 'PACKAGING', v_pk, 500, 500, v_owner) returning id into v_cnt2;

  --------------------------------------------------------------------------- TC-36, TC-37
  select * into v_row from v_yield_loss_daily where close_date = date '2026-08-20';
  assert v_row.lots_closed = 2 and v_row.foodiva_sent_weight_kg = 150.00
     and v_row.loss_weight_kg = 30.00 and v_row.yield_alert_lot_count = 1,
    format('TC-36: 20 Aug reads %s lots, %s kg sent, %s kg lost, %s alert(s) — expected 2, 150.00, 30.00, 1',
           v_row.lots_closed, v_row.foodiva_sent_weight_kg, v_row.loss_weight_kg, v_row.yield_alert_lot_count);
  -- ADR-011, failure case: weighted on the dispatch base, never a mean of the lots' percentages.
  assert v_row.loss_pct = 20.00,
    format('TC-37: 20 Aug reads %s%% — expected 20.00 (30 / 150), never 17.50 ((25 + 10) / 2)', v_row.loss_pct);

  --------------------------------------------------------------------------------- TC-38
  select * into v_row from v_yield_loss_daily where close_date = date '2026-09-10';
  assert v_row.lots_closed = 1 and v_row.loss_pct = 20.00,
    format('TC-38: 10 Sep (Bangkok) reads %s lot(s) at %s%% — expected 1 at 20.00', v_row.lots_closed, v_row.loss_pct);
  select count(*) into v_n from v_yield_loss_daily where close_date = date '2026-09-09';
  assert v_n = 0, format('TC-38: %s row(s) on 9 Sep — a 01:30 Bangkok close was dated by UTC', v_n);

  --------------------------------------------------------------------------------- TC-39
  -- One exception per source, each pointing at the row that raised it.
  for v_exp in
    select * from (values ('YIELD_ALERT',         v_note),
                          ('DIFF_OVER_THRESHOLD', v_rep),
                          ('MATERIAL_LOW',        v_pk),
                          ('COUNT_VARIANCE_OPEN', v_cnt1),
                          ('RECEIPT_VARIANCE',    v_ln2),
                          ('RECEIPT_OUTSTANDING', v_ln3),
                          ('LOT_COST_INCOMPLETE', v_y1)) e(kind, ref)
  loop
    select count(*) into v_n from v_owner_exceptions
     where exception_kind = v_exp.kind and ref_id = v_exp.ref;
    assert v_n = 1, format('TC-39: %s has %s row(s) for its source, expected 1', v_exp.kind, v_n);
  end loop;
  select count(distinct exception_kind) into v_n from v_owner_exceptions;
  assert v_n = 7, format('TC-39: %s exception kind(s) present, expected all 7', v_n);

  select * into v_row from v_owner_exceptions where exception_kind = 'DIFF_OVER_THRESHOLD';
  assert v_row.location_id = v_b1 and v_row.occurred_on = v_d
     and v_row.detail ->> 'verdict' = 'OVER_THRESHOLD' and (v_row.detail ->> 'ready_in_kg')::numeric = 12.00,
    format('TC-39: the Diff exception reads %s on %s with %s', v_row.location_id, v_row.occurred_on, v_row.detail);
  select * into v_row from v_owner_exceptions where exception_kind = 'RECEIPT_VARIANCE';
  assert v_row.detail ->> 'variance_reason' = 'น้ำแข็งละลายระหว่างทาง' and v_row.lot_id = v_t2,
    format('TC-39: the receipt variance reads %s', v_row.detail);
  select * into v_row from v_owner_exceptions where exception_kind = 'MATERIAL_LOW';
  assert v_row.location_id = v_b1 and (v_row.detail ->> 'remaining_qty')::numeric = 150,
    format('TC-39: the material alert reads %s at %s', v_row.detail, v_row.location_id);

  --------------------------------------------------------------------------------- TC-40
  -- Failure case: nothing within tolerance is an exception. B2's Diff is WITHIN, its count is
  -- MATCHED, its material is unconfigured (is_low null); T1 was received exactly with no
  -- reason; Y2 and Y3 are closed but not back at central.
  select count(*) into v_n from v_owner_exceptions where location_id = v_b2;
  assert v_n = 0, format('TC-40: B2 (all within tolerance or unconfigured) raised %s exception(s)', v_n);
  select count(*) into v_n from v_owner_exceptions where ref_id in (v_ln1, v_cnt2);
  assert v_n = 0, format('TC-40: an exact receipt or a matched count raised %s exception(s)', v_n);
  select count(*) into v_n from v_owner_exceptions
   where exception_kind = 'LOT_COST_INCOMPLETE' and lot_id in (v_y2, v_y3, v_t1, v_t2, v_t3);
  assert v_n = 0, format('TC-40: %s lot(s) not yet back at central read as a cost exception', v_n);
  select count(*) into v_n from v_owner_exceptions where exception_kind = 'MATERIAL_LOW';
  assert v_n = 1, format('TC-40: %s MATERIAL_LOW row(s) — an unconfigured or uncounted item is never low', v_n);

  --------------------------------------------------------------------------------- TC-41
  -- The trace, sale to supplier; an opening lot stops at the lot.
  select * into v_row from v_sales_trace where sales_line_id = v_sl1;
  assert v_row.lot_id = v_y2 and v_row.lot_code = (select lot_code from lots where id = v_y2)
     and v_row.smoke_date = date '2026-08-18' and v_row.smoke_date_group_id = v_gY2
     and v_row.po_number = (select po_number from purchase_orders where id = v_po)
     and v_row.supplier_name = 'ฟู้ดดีว่า' and not v_row.is_opening
     and v_row.sold_qty = 20 and v_row.pack_weight_kg = 0.25 and v_row.business_date = v_d,
    format('TC-41: the Y2 line traces to lot %s, smoked %s, PO %s, supplier %s',
           v_row.lot_code, v_row.smoke_date, v_row.po_number, v_row.supplier_name);
  select * into v_row from v_sales_trace where sales_line_id = v_sl2;
  assert v_row.is_opening and v_row.lot_id = v_lotO and v_row.po_id is null
     and v_row.po_number is null and v_row.supplier_name is null,
    format('TC-41: the opening-lot line reads opening %s, PO %s, supplier %s',
           v_row.is_opening, v_row.po_number, v_row.supplier_name);
  select count(*) into v_n from v_sales_trace where location_id = v_b1;
  assert v_n = 2, format('TC-41: B1 has %s trace row(s), expected 2 (rice carries no lot)', v_n);

  -------------------------------------------------------------------- RLS, as `authenticated`
  set local role authenticated;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_owner_exceptions;
  assert v_n >= 7, format('TC-R1: the Owner reads %s exception(s) as authenticated', v_n);

  -- TC-R3: a branch admin reads none of the dashboard sources.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  foreach v_view in array v_mine loop
    execute format('select count(*) from %I', v_view) into v_n;
    assert v_n = 0, format('TC-R3: B1''s admin reads %s row(s) from %s', v_n, v_view);
  end loop;

  -- TC-R5 (R20, BR15, UAT-15): the chef-house operator reads no row from ANY of K's fourteen
  -- views — the _qty views included.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  foreach v_view in array v_all loop
    execute format('select count(*) from %I', v_view) into v_n;
    assert v_n = 0, format('TC-R5: the L3 reads %s row(s) from %s', v_n, v_view);
  end loop;

  -- TC-R6, failure case: a deactivated Owner reads nothing.
  reset role;
  update profiles set is_active = false where id = v_owner;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  foreach v_view in array v_mine loop
    execute format('select count(*) from %I', v_view) into v_n;
    assert v_n = 0, format('TC-R6: a deactivated Owner reads %s row(s) from %s', v_n, v_view);
  end loop;

  reset role;

  raise exception 'REPORTS_DASHBOARD_TEST_PASSED';   -- the only clean way back out
end $$;
