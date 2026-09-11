-- Card ^ref-41 — the RLS half of the acceptance line: "an L2 session sees only its own branch
-- and no final financials — enforced by RLS" (TDD-thaw.md TC-36 ... TC-40, PLAN T10).
--
-- Proved by querying every view BR 01 / BR 02 / BR 05 reads AS EACH ROLE, ^ref-07's precedent:
-- v_my_branches (141), v_daily_reports (142), v_outstanding_receipts (090, amended here),
-- v_branch_frozen_available (140) and v_stock_balance (010). The screens mirror these views; if
-- a screen's filter were deleted, this file is what would still hold.
--
-- Contract assumed from an unmerged lane: none. fn_allocate_to_branch (^ref-36) is merged.
-- transport_test.sql's TC-38/TC-39 over v_outstanding_receipts are the regression check for the
-- amendment and are not repeated here; TC-38 below asserts only the two appended columns and
-- that they are the LAST two.
--
-- ONE do $$ BLOCK, rolled back by the closing raise. Nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/branch_screens_test.sql

do $$
declare
  v_owner   uuid := gen_random_uuid();
  v_off     uuid := gen_random_uuid();
  v_l3      uuid := gen_random_uuid();
  v_l2a     uuid := gen_random_uuid();
  v_l2b     uuid := gen_random_uuid();
  v_today   date := current_date;
  v_chef    uuid;
  v_central uuid;
  v_bra     uuid;
  v_brb     uuid;
  v_brx     uuid;   -- an inactive branch
  v_sup     uuid;
  v_po      uuid;
  v_lot1    uuid;
  v_lot2    uuid;
  v_g1      uuid;
  v_g2      uuid;
  v_line    uuid;
  v_lineB   uuid;   -- to B, never received (TC-40)
  v_rep     uuid;
  v_prev    uuid;   -- A's day before, closed, nothing thawed
  v_ids     uuid[];
  v_id      uuid;
  v_n       bigint;
  v_n2      bigint;
  v_kg      numeric;
  v_txt     text;
  v_view    text;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_off), (v_l3), (v_l2a), (v_l2b);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',               'L1_OWNER',        true),
    (v_off,   'แอดมินที่ปิดบัญชีแล้ว',      'L2_BRANCH_ADMIN', false),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',     'L3_CM_OPERATOR',  true),
    (v_l2a,   'แอดมินสาขาเอ',           'L2_BRANCH_ADMIN', true),
    (v_l2b,   'แอดมินสาขาบี',           'L2_BRANCH_ADMIN', true);

  insert into locations (code, name_th, kind) values ('CH41', 'โรงรม', 'CHEF_HOUSE') returning id into v_chef;
  insert into locations (code, name_th, kind) values ('CEN41', 'คลังกลาง', 'CENTRAL') returning id into v_central;
  insert into locations (code, name_th, kind, rice_model) values ('BRA41', 'สาขาเอ', 'BRANCH', 'SELF_COOK') returning id into v_bra;
  insert into locations (code, name_th, kind) values ('BRB41', 'สาขาบี', 'BRANCH') returning id into v_brb;
  insert into locations (code, name_th, kind, is_active) values ('BRX41', 'สาขาที่ปิดแล้ว', 'BRANCH', false) returning id into v_brx;
  -- The deactivated admin still holds A's assignment: is_active alone must shut them out.
  insert into user_locations (profile_id, location_id) values
    (v_l3, v_chef), (v_l2a, v_bra), (v_l2b, v_brb), (v_off, v_bra);
  insert into suppliers (name) values ('Foodiva') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', v_today - 60, p_value_text => 'BY_LOT_WEIGHT');
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', v_today - 60, p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', v_today - 60, p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', v_today - 60, p_value_text => 'true');

  v_po   := fn_create_po(gen_random_uuid(), v_sup, v_today - 20, 1000.00, 250.00);
  v_lot1 := fn_add_po_delivery(gen_random_uuid(), v_po, v_today - 20, 100.00, v_chef);
  v_lot2 := fn_add_po_delivery(gen_random_uuid(), v_po, v_today - 20, 100.00, v_chef);
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lot1, v_today - 9) returning id into v_g1;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lot2, v_today - 8) returning id into v_g2;
  update lots set state = 'CENTRAL_STOCK' where id in (v_lot1, v_lot2);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_central, 'FROZEN', 'TRANSFER_IN', 20.00, v_today - 5,
                         p_lot_id => v_lot1, p_smoke_date_group_id => v_g1);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_central, 'FROZEN', 'TRANSFER_IN', 20.00, v_today - 5,
                         p_lot_id => v_lot2, p_smoke_date_group_id => v_g2);

  -- 10.00 kg in 10 bags to A; 5.00 of the later date to B, received; 2.00 more to B, left on the truck.
  v_line  := fn_allocate_to_branch(gen_random_uuid(), v_bra, v_today - 3, v_g1, 10.00, 10);
  v_id    := fn_allocate_to_branch(gen_random_uuid(), v_brb, v_today - 3, v_g2, 5.00, 5, 'ทดสอบ');
  v_lineB := fn_allocate_to_branch(gen_random_uuid(), v_brb, v_today - 3, v_g2, 2.00, 2, 'ทดสอบ');

  --------------------------------------------------------------------------------- TC-38
  -- Before A signs: the line is outstanding, and BR 02 can show what was loaded.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  select bag_count, smoke_date into v_n, v_txt from v_outstanding_receipts where line_id = v_line;
  assert v_n = 10 and v_txt::date = v_today - 9,
    format('TC-38: A''s outstanding line reads %s bag(s), smoke date %s', v_n, v_txt);
  select string_agg(column_name, ',' order by ordinal_position desc) into v_txt
    from (select column_name, ordinal_position from information_schema.columns
           where table_schema = 'public' and table_name = 'v_outstanding_receipts'
           order by ordinal_position desc limit 2) c;
  assert v_txt = 'smoke_date,bag_count',
    format('TC-38: the view''s last two columns are %s — ^ref-41 appends, it does not reorder', v_txt);

  -- A signs for its line; B signs for the first of its two.
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line, v_today - 2, 10.00, p_received_bag_count => 10);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_id, v_today - 2, 5.00, p_received_bag_count => 5);
  perform fn_open_daily_report(gen_random_uuid(), v_brb, v_today);

  -- A's day before, closed with nothing thawed; then today, open, with one 3.00 kg thaw.
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by, closed_by, closed_at)
    values (v_bra, v_today - 1, now() - interval '1 day', 'CLOSED', v_l2a, v_l2a, now() - interval '12 hours')
    returning id into v_prev;
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_rep := (fn_open_daily_report(gen_random_uuid(), v_bra, v_today) ->> 'daily_report_id')::uuid;
  perform fn_record_thaw(gen_random_uuid(), v_rep, v_lot1, v_g1, 3.00);

  --------------------------------------------------------------------------------- TC-36
  foreach v_id in array array[v_owner, v_l2a, v_l2b, v_l3, v_off] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
    select coalesce(array_agg(id order by code), '{}') into v_ids from v_my_branches;
    assert v_ids = case v_id when v_owner then array[v_bra, v_brb]
                             when v_l2a   then array[v_bra]
                             when v_l2b   then array[v_brb]
                             else '{}'::uuid[] end,
      format('TC-36: %s reads branches %s', (select display_name from profiles where id = v_id), v_ids);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_my_branches where id in (v_chef, v_central, v_brx);
  assert v_n = 0, format('TC-36: %s chef-house, central or inactive row(s) offered as a branch', v_n);

  --------------------------------------------------------------------------------- TC-37
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  select thawed_kg into v_kg from v_daily_reports where id = v_rep;
  assert v_kg = 3.00, format('TC-37: today''s thawed_kg reads %s, expected 3.00', v_kg);
  select thawed_kg into v_kg from v_daily_reports where id = v_prev;
  assert v_kg = 0.00, format('TC-37: a day with no thaw reads %s, expected 0.00 (not null)', v_kg);
  select count(*), count(*) filter (where location_id <> v_bra) into v_n, v_n2 from v_daily_reports;
  assert v_n = 2 and v_n2 = 0, format('TC-37: A''s admin reads %s day(s), %s not A''s', v_n, v_n2);
  foreach v_id in array array[v_l3, v_off] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
    select count(*) into v_n from v_daily_reports;
    assert v_n = 0, format('TC-37: %s reads %s day(s)', (select display_name from profiles where id = v_id), v_n);
  end loop;

  --------------------------------------------------------------------------------- TC-39
  -- No final financials in any view a branch screen reads: no cost, price, THB, yield, loss or
  -- freight column, whatever the role (R20).
  select string_agg(table_name || '.' || column_name, ', ') into v_txt
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('v_my_branches', 'v_daily_reports', 'v_outstanding_receipts',
                        'v_branch_frozen_available', 'v_stock_balance')
     and (column_name like '%cost%' or column_name like '%price%' or column_name like '%thb%'
       or column_name like '%yield%' or column_name like '%loss%' or column_name like '%freight%');
  assert v_txt is null, format('TC-39: a branch screen''s view carries %s (R20)', v_txt);

  --------------------------------------------------------------------------------- TC-40
  -- A's admin asks each view for branch B by name and gets nothing. The Owner, asking the same,
  -- gets B's rows — so the filter is "own branch", not "deny everyone".
  foreach v_view in array array['v_my_branches', 'v_daily_reports', 'v_outstanding_receipts',
                                'v_branch_frozen_available', 'v_stock_balance'] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
    execute format('select count(*) from public.%I where %I = $1', v_view,
                   case v_view when 'v_my_branches' then 'id'
                               when 'v_outstanding_receipts' then 'to_location_id'
                               else 'location_id' end)
      into v_n using v_brb;
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
    execute format('select count(*) from public.%I where %I = $1', v_view,
                   case v_view when 'v_my_branches' then 'id'
                               when 'v_outstanding_receipts' then 'to_location_id'
                               else 'location_id' end)
      into v_n2 using v_brb;
    assert v_n = 0 and v_n2 > 0,
      format('TC-40: %s gives A''s admin %s of B''s row(s) and the Owner %s', v_view, v_n, v_n2);
  end loop;

  -- The line still on the truck to B is B's to see, not A's, even though it is outstanding.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  select count(*) into v_n from v_outstanding_receipts where line_id = v_lineB;
  assert v_n = 1, format('TC-40: B''s admin sees %s of its own outstanding line(s)', v_n);

  raise exception 'BRANCH_SCREENS_TEST_PASSED';
end $$;
