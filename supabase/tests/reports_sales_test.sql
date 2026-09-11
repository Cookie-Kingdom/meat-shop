-- Card ^ref-55 — v_daily_sales, v_daily_sales_qty, v_monthly_summary, v_monthly_summary_qty.
-- TC-01 ... TC-09 and TC-R1 ... TC-R7 of v.0.1/ready-ref-55-58-reporting/TDD-reporting.md §55.
-- Contract assumed from an unmerged lane: none (sales_lines with C's …0018 columns, the five SKUs
-- …0018 seeds, and fn_record_sales's channel = 'LINE_MAN' are all on develop at aec8aec).
--
-- SALES LINES ARE INSERTED DIRECTLY while each report is OPEN, and the report is closed by an
-- UPDATE afterwards. fn_record_sales is sales_test.sql's subject, and a view reads rows, not how
-- they were written. fn_guard_report_closed refuses a child insert under a CLOSED report, which
-- is why the close comes last. Meat lines name an opening lot inserted directly, as cost_test.sql
-- does: R21's trigger wants a lot_id, and nothing in these four views reads the ledger.
--
-- ROLE READS RUN AS `authenticated` with each profile's JWT (TC-R1 ... TC-R7).
-- One do $$ block; the transaction aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/reports_sales_test.sql

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_l2a    uuid := gen_random_uuid();   -- branch B1
  v_l2b    uuid := gen_random_uuid();   -- branch B2
  v_l2ab   uuid := gen_random_uuid();   -- both branches (TC-R7)
  v_l3     uuid := gen_random_uuid();
  v_d1     date := date '2026-08-10';
  v_d2     date := date '2026-08-11';
  v_b1     uuid;
  v_b2     uuid;
  v_chef   uuid;
  v_lot    uuid;
  v_r1d1   uuid;
  v_r1d2   uuid;
  v_r2d1   uuid;
  v_r2d2   uuid;
  v_box    uuid;
  v_addon  uuid;
  v_chilli uuid;
  v_rice   uuid;
  v_row    record;
  v_n      bigint;
  v_ok     boolean;
  v_state  text;
  v_view   text;
  v_all    text[] := array['v_daily_sales', 'v_daily_sales_qty',
                           'v_monthly_summary', 'v_monthly_summary_qty'];
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2a), (v_l2b), (v_l2ab), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',               'L1_OWNER',        true),
    (v_l2a,   'แอดมินสาขาหนึ่ง',        'L2_BRANCH_ADMIN', true),
    (v_l2b,   'แอดมินสาขาสอง',          'L2_BRANCH_ADMIN', true),
    (v_l2ab,  'แอดมินสองสาขา',          'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',    'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind) values ('K55-B1', 'สาขาหนึ่ง', 'BRANCH')
    returning id into v_b1;
  insert into locations (code, name_th, kind) values ('K55-B2', 'สาขาสอง', 'BRANCH')
    returning id into v_b2;
  insert into locations (code, name_th, kind) values ('K55-CH', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into user_locations (profile_id, location_id) values
    (v_l2a, v_b1), (v_l2b, v_b2), (v_l2ab, v_b1), (v_l2ab, v_b2), (v_l3, v_chef);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  select id into v_box    from products where code = 'MEAT_BOX';
  select id into v_addon  from products where code = 'MEAT_ADDON_SEALED';
  select id into v_chilli from products where code = 'CHILLI_TUBE';
  select id into v_rice   from products where code = 'RICE_KG';
  assert v_box is not null and v_addon is not null and v_chilli is not null and v_rice is not null,
    'fixture: …0018''s SKUs are missing';

  insert into lots (lot_code, is_opening, state, event_date)
    values ('K55-OPEN', true, 'LOT_CLOSED', v_d1 - 30) returning id into v_lot;

  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by) values
    (v_b1, v_d1, v_d1 + time '09:00', 'OPEN', v_owner) returning id into v_r1d1;
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by) values
    (v_b2, v_d1, v_d1 + time '09:00', 'OPEN', v_owner) returning id into v_r2d1;

  -- B1, D1 (F1's sales half). MEAT_BOX in two lines, so the grain is proved to sum them.
  insert into sales_lines (daily_report_id, product_id, lot_id, qty, unit_price_thb,
                           pack_weight_kg, channel, created_by) values
    (v_r1d1, v_box,    v_lot, 7,    350.00, 0.25, 'LINE_MAN', v_owner),
    (v_r1d1, v_box,    v_lot, 5,    350.00, 0.25, 'LINE_MAN', v_owner),
    (v_r1d1, v_addon,  v_lot, 3,    320.00, 0.25, 'LINE_MAN', v_owner),
    (v_r1d1, v_chilli, null,  5,     25.00, null, 'LINE_MAN', v_owner),
    (v_r1d1, v_rice,   null,  2.50,  60.00, null, 'LINE_MAN', v_owner);
  -- B2, D1: two rice lines at 33.33 (TC-03).
  insert into sales_lines (daily_report_id, product_id, lot_id, qty, unit_price_thb,
                           pack_weight_kg, channel, created_by) values
    (v_r2d1, v_rice,   null,  2.50,  33.33, null, 'LINE_MAN', v_owner),
    (v_r2d1, v_rice,   null,  2.50,  33.33, null, 'LINE_MAN', v_owner);

  update daily_reports set status = 'CLOSED', closed_by = v_owner, closed_at = now()
   where id in (v_r1d1, v_r2d1);

  -- D2 opens only now: one OPEN report per branch (daily_reports_one_open).
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by) values
    (v_b1, v_d2, v_d2 + time '09:00', 'OPEN', v_owner) returning id into v_r1d2;
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by) values
    (v_b2, v_d2, v_d2 + time '09:00', 'OPEN', v_owner) returning id into v_r2d2;
  -- B1, D2 stays OPEN (TC-04, TC-08).
  insert into sales_lines (daily_report_id, product_id, lot_id, qty, unit_price_thb,
                           pack_weight_kg, channel, created_by) values
    (v_r1d2, v_box,    v_lot, 2,    350.00, 0.25, 'LINE_MAN', v_owner);
  -- B2, D2: a reported day with no sales (TC-09).
  update daily_reports set status = 'CLOSED', closed_by = v_owner, closed_at = now()
   where id = v_r2d2;

  --------------------------------------------------------------------------------- TC-01
  select * into v_row from v_daily_sales
   where location_id = v_b1 and business_date = v_d1 and product_code = 'MEAT_BOX';
  assert v_row.revenue_thb = 4200.00 and v_row.sold_qty = 12 and v_row.line_count = 2,
    format('TC-01: MEAT_BOX reads %s THB, %s boxes over %s lines — expected 4200.00, 12, 2',
           v_row.revenue_thb, v_row.sold_qty, v_row.line_count);
  assert v_row.report_status = 'CLOSED' and v_row.sales_month = '2026-08'
     and v_row.location_name_th = 'สาขาหนึ่ง' and v_row.daily_report_id = v_r1d1,
    format('TC-01: MEAT_BOX row carries status %s, month %s, branch %s',
           v_row.report_status, v_row.sales_month, v_row.location_name_th);

  select * into v_row from v_daily_sales
   where location_id = v_b1 and business_date = v_d1 and product_code = 'CHILLI_TUBE';
  assert v_row.revenue_thb = 125.00 and v_row.sold_qty = 5,
    format('TC-01: CHILLI_TUBE reads %s THB, %s tubes — expected 125.00, 5', v_row.revenue_thb, v_row.sold_qty);

  select * into v_row from v_daily_sales
   where location_id = v_b1 and business_date = v_d1 and product_code = 'RICE_KG';
  assert v_row.revenue_thb = 150.00 and v_row.sold_qty = 2.50,
    format('TC-01: RICE_KG reads %s THB, %s kg — expected 150.00, 2.50', v_row.revenue_thb, v_row.sold_qty);

  --------------------------------------------------------------------------------- TC-02
  -- D03.1: the add-on bag is its own SKU and never folds into the box.
  select * into v_row from v_daily_sales
   where location_id = v_b1 and business_date = v_d1 and product_code = 'MEAT_ADDON_SEALED';
  assert v_row.revenue_thb = 960.00 and v_row.sold_qty = 3,
    format('TC-02: the add-on reads %s THB, %s bags — expected 960.00, 3', v_row.revenue_thb, v_row.sold_qty);
  select count(*) into v_n from v_daily_sales where location_id = v_b1 and business_date = v_d1;
  assert v_n = 4, format('TC-02: B1 on D1 has %s rows, expected 4 (one per SKU)', v_n);

  --------------------------------------------------------------------------------- TC-03
  -- Per line, then summed: 2 × round(83.325) = 166.66, never round(166.65) = 166.65.
  select * into v_row from v_daily_sales
   where location_id = v_b2 and business_date = v_d1 and product_code = 'RICE_KG';
  assert v_row.revenue_thb = 166.66,
    format('TC-03: two lines of 2.50 × 33.33 read %s, expected 166.66 (rounded per line)', v_row.revenue_thb);

  --------------------------------------------------------------------------------- TC-04
  select * into v_row from v_daily_sales
   where location_id = v_b1 and business_date = v_d2 and product_code = 'MEAT_BOX';
  assert v_row.report_status = 'OPEN' and v_row.revenue_thb = 700.00,
    format('TC-04: the open day reads status %s, %s THB — expected OPEN, 700.00',
           v_row.report_status, v_row.revenue_thb);

  --------------------------------------------------------------------------------- TC-05
  -- BR23, failure case: a later price row cannot move a closed day.
  insert into product_prices (product_id, price_thb, effective_from, created_by)
    values (v_box, 400.00, v_d1 + 1, v_owner);
  select revenue_thb into v_row from v_daily_sales
   where location_id = v_b1 and business_date = v_d1 and product_code = 'MEAT_BOX';
  assert v_row.revenue_thb = 4200.00,
    format('TC-05: a 400.00 price dated D1 + 1 moved D1 to %s, expected 4200.00', v_row.revenue_thb);

  --------------------------------------------------------------------------------- TC-06
  select count(*) into v_n from v_daily_sales where revenue_source is distinct from 'LINE_MAN';
  assert v_n = 0, format('TC-06: %s row(s) name a revenue source other than LINE_MAN (D04)', v_n);
  select count(*) into v_n from v_monthly_summary where revenue_source is distinct from 'LINE_MAN';
  assert v_n = 0, format('TC-06: %s monthly row(s) name a revenue source other than LINE_MAN', v_n);

  --------------------------------------------------------------------------------- TC-07
  -- The month is the sum of its days, money and quantity, for every row.
  select count(*) into v_n
    from v_monthly_summary m
    left join (select d.sales_month, d.location_id, d.product_id,
                      sum(d.revenue_thb) as revenue_thb, sum(d.sold_qty) as sold_qty
                 from v_daily_sales d
                group by d.sales_month, d.location_id, d.product_id) s
      on s.sales_month = m.sales_month and s.location_id = m.location_id
     and s.product_id  = m.product_id
   where m.location_id in (v_b1, v_b2)
     and (m.revenue_thb is distinct from s.revenue_thb or m.sold_qty is distinct from s.sold_qty);
  assert v_n = 0, format('TC-07: %s monthly row(s) differ from the sum of their days', v_n);
  select * into v_row from v_monthly_summary
   where location_id = v_b1 and sales_month = '2026-08' and product_code = 'MEAT_BOX';
  assert v_row.revenue_thb = 4900.00 and v_row.sold_qty = 14 and v_row.days_with_sales = 2,
    format('TC-07: B1''s August MEAT_BOX reads %s THB, %s boxes, %s days — expected 4900.00, 14, 2',
           v_row.revenue_thb, v_row.sold_qty, v_row.days_with_sales);

  --------------------------------------------------------------------------------- TC-08
  assert v_row.days_reported = 2 and v_row.days_closed = 1 and not v_row.is_complete,
    format('TC-08: B1''s August reads %s reported, %s closed, complete %s — expected 2, 1, false',
           v_row.days_reported, v_row.days_closed, v_row.is_complete);

  --------------------------------------------------------------------------------- TC-09
  -- A reported day with no sales counts as reported and adds no row of its own.
  select * into v_row from v_monthly_summary
   where location_id = v_b2 and sales_month = '2026-08' and product_code = 'RICE_KG';
  assert v_row.days_reported = 2 and v_row.days_closed = 2 and v_row.is_complete
     and v_row.days_with_sales = 1,
    format('TC-09: B2''s August reads %s reported, %s closed, complete %s, %s sales day(s)',
           v_row.days_reported, v_row.days_closed, v_row.is_complete, v_row.days_with_sales);
  select count(*) into v_n from v_daily_sales where location_id = v_b2 and business_date = v_d2;
  assert v_n = 0, format('TC-09: the no-sales day produced %s row(s), expected none', v_n);
  select count(*) into v_n from v_monthly_summary where location_id = v_b2;
  assert v_n = 1, format('TC-09: B2 has %s monthly row(s), expected 1 (rice only)', v_n);

  -- The quantity views agree with the money views on every quantity.
  select count(*) into v_n
    from v_monthly_summary m
    full join v_monthly_summary_qty q
      on q.sales_month = m.sales_month and q.location_id = m.location_id and q.product_id = m.product_id
   where coalesce(m.location_id, q.location_id) in (v_b1, v_b2)
     and (m.sold_qty is distinct from q.sold_qty or m.days_reported is distinct from q.days_reported);
  assert v_n = 0, format('TC-09: %s row(s) where v_monthly_summary_qty disagrees with v_monthly_summary', v_n);

  -------------------------------------------------------------------- RLS, as `authenticated`
  set local role authenticated;

  -- TC-R1: the Owner reads both branches from both day views.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(distinct location_id) into v_n from v_daily_sales where location_id in (v_b1, v_b2);
  assert v_n = 2, format('TC-R1: the Owner reads %s branch(es) from v_daily_sales, expected 2', v_n);
  select count(distinct location_id) into v_n from v_daily_sales_qty where location_id in (v_b1, v_b2);
  assert v_n = 2, format('TC-R1: the Owner reads %s branch(es) from v_daily_sales_qty, expected 2', v_n);

  -- TC-R2: each L2 reads only their own branch, from both quantity views.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  select count(*) into v_n from v_daily_sales_qty where location_id = v_b2;
  assert v_n = 0, format('TC-R2: B1''s admin reads %s B2 row(s) from v_daily_sales_qty', v_n);
  select count(*) into v_n from v_daily_sales_qty where location_id = v_b1;
  assert v_n = 5, format('TC-R2: B1''s admin reads %s of B1''s 5 day rows', v_n);
  select count(*) into v_n from v_monthly_summary_qty where location_id = v_b2;
  assert v_n = 0, format('TC-R2: B1''s admin reads %s B2 row(s) from v_monthly_summary_qty', v_n);
  select count(*) into v_n from v_monthly_summary_qty where location_id = v_b1;
  assert v_n = 4, format('TC-R2: B1''s admin reads %s of B1''s 4 month rows', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  select count(*) into v_n from v_daily_sales_qty where location_id = v_b1;
  assert v_n = 0, format('TC-R2: B2''s admin reads %s B1 row(s) from v_daily_sales_qty', v_n);
  select count(*) into v_n from v_monthly_summary_qty where location_id = v_b2;
  assert v_n = 1, format('TC-R2: B2''s admin reads %s of B2''s 1 month row', v_n);

  -- TC-R3: an L2 reads no money: zero rows from both money views.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  select count(*) into v_n from v_daily_sales;
  assert v_n = 0, format('TC-R3: B1''s admin reads %s v_daily_sales row(s)', v_n);
  select count(*) into v_n from v_monthly_summary;
  assert v_n = 0, format('TC-R3: B1''s admin reads %s v_monthly_summary row(s)', v_n);

  -- TC-R4, the ^ref-55 acceptance line: selecting the money column errors, by SQLSTATE.
  foreach v_view in array array['v_daily_sales_qty', 'v_monthly_summary_qty'] loop
    v_ok := false; v_state := null;
    begin
      execute format('select revenue_thb from %I', v_view);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      v_ok := v_state = '42703';
    end;
    assert v_ok, format('TC-R4: select revenue_thb from %s as L2 gave SQLSTATE %s, expected 42703',
                        v_view, coalesce(v_state, 'none — it read a column'));
  end loop;

  -- TC-R5: the chef-house operator reads no row from any of the four.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  foreach v_view in array v_all loop
    execute format('select count(*) from %I', v_view) into v_n;
    assert v_n = 0, format('TC-R5: the L3 reads %s row(s) from %s', v_n, v_view);
  end loop;

  -- TC-R7: an L2 over two branches sees both in the quantity view and still no money.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2ab)::text, true);
  select count(distinct location_id) into v_n from v_daily_sales_qty where location_id in (v_b1, v_b2);
  assert v_n = 2, format('TC-R7: the two-branch admin reads %s branch(es), expected 2', v_n);
  select count(*) into v_n from v_daily_sales;
  assert v_n = 0, format('TC-R7: the two-branch admin reads %s v_daily_sales row(s)', v_n);

  -- TC-R6, failure case: a deactivated Owner reads nothing (R31 folds is_active).
  reset role;
  update profiles set is_active = false where id = v_owner;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  foreach v_view in array v_all loop
    execute format('select count(*) from %I', v_view) into v_n;
    assert v_n = 0, format('TC-R6: a deactivated Owner reads %s row(s) from %s', v_n, v_view);
  end loop;

  reset role;

  raise exception 'REPORTS_SALES_TEST_PASSED';   -- the only clean way back out
end $$;
