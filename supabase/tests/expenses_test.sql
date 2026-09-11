-- Failure-case tests for card ^ref-53 — owner_expenses (…0025), fn_record_owner_expense and
-- v_owner_expenses (views/191).
--
-- Assumes from unmerged lanes: nothing.
--
-- Covers TC-01 … TC-24 from v.0.1/ref-53-54-owner-expenses/TDD-owner-expenses.md. Each assert
-- is a way an owner expense goes wrong without anyone noticing:
--   * a dropped connection books the freezer twice, or a second genuine refill is refused as
--     a duplicate (R39) — TC-08 … TC-10, TC-20
--   * an investment lands in a month it was not bought in, and a month reads as good or bad for
--     a reason nobody can see (ADR-020) — TC-03, TC-07, TC-17
--   * an L2 or L3 writes or reads the Owner's accounts (M11 AC, R20) — TC-12, TC-13, TC-23
--   * a row with no detail cannot be matched to the bank transfer it paid for (M11) — TC-16
--   * an asset-life column appears and depreciation creeps back in (ADR-020 closed) — TC-02
--
-- Everything runs in one transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/expenses_test.sql

do $$
declare
  v_owner  uuid := '53535353-5353-5353-5353-535353535301';
  v_l2     uuid := '53535353-5353-5353-5353-535353535302';
  v_l3     uuid := '53535353-5353-5353-5353-535353535303';
  v_gone   uuid := '53535353-5353-5353-5353-535353535304';
  v_branch uuid;
  v_k1     uuid := gen_random_uuid();
  v_k2     uuid := gen_random_uuid();
  v_k3     uuid := gen_random_uuid();
  v_inv    uuid;
  v_inv2   uuid;
  v_mon    uuid;
  v_id     uuid;
  v_again  uuid;
  v_by     uuid;
  v_txt    text;
  v_txt2   text;
  v_num    numeric;
  v_n      bigint;
  v_ok     boolean;
  v_err    text;
  v_amt    numeric;
  v_det    text;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3), (v_gone);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',               'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',            'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',  'L3_CM_OPERATOR',  true),
    (v_gone,  'เจ้าของที่ปิดใช้',        'L1_OWNER',        false);
  insert into locations (code, name_th, kind) values ('EXP-BR', 'สาขามีนบุรี', 'BRANCH')
    returning id into v_branch;
  insert into user_locations (profile_id, location_id) values (v_l2, v_branch);

  --------------------------------------------------------------------------------- TC-01
  select count(*) into v_n
    from pg_indexes
   where schemaname = 'public' and tablename = 'owner_expenses'
     and indexdef ilike 'create unique index%' and indexdef ilike '%(idempotency_key)%';
  assert v_n = 1, 'TC-01: owner_expenses.idempotency_key carries no unique index (R39)';

  --------------------------------------------------------------------------------- TC-02
  -- ADR-020 closed with no depreciation: no asset life, no asset register. The day a column
  -- for one appears, this fails rather than a report quietly spreading a freezer over years.
  select string_agg(column_name, ', ') into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'owner_expenses'
     and (column_name ilike '%life%' or column_name ilike '%depreciat%'
          or column_name ilike '%useful%' or column_name ilike '%salvage%');
  assert v_txt is null, format('TC-02: owner_expenses carries an asset-life column: %s', v_txt);

  --------------------------------------------------------------------------------- TC-03
  -- One month source per kind, held by the schema and not only by the function.
  v_ok := false;
  begin
    insert into owner_expenses (kind, event_date, amount_thb, detail, created_by)
         values ('MONTHLY_FIXED', date '2026-09-28', 12000, 'ค่าเช่า', v_owner);
  exception when check_violation then
    v_ok := true;
  end;
  assert v_ok, 'TC-03: a MONTHLY_FIXED row with no expense_month was stored';

  v_ok := false;
  begin
    insert into owner_expenses (kind, event_date, expense_month, amount_thb, detail, created_by)
         values ('INVESTMENT', date '2026-09-05', '2026-10', 45000, 'ตู้แช่', v_owner);
  exception when check_violation then
    v_ok := true;
  end;
  assert v_ok, 'TC-03: an INVESTMENT carrying a month other than its own was stored (ADR-020)';

  --------------------------------------------------------------------------------- TC-04
  v_ok := false;
  begin
    insert into owner_expenses (kind, event_date, expense_month, amount_thb, detail, created_by)
         values ('MONTHLY_FIXED', date '2026-09-28', '2026-13', 12000, 'ค่าเช่า', v_owner);
  exception when check_violation then
    v_ok := true;
  end;
  assert v_ok, 'TC-04: expense_month 2026-13 was stored';

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-05
  v_inv := fn_record_owner_expense(v_k1, 'INVESTMENT', date '2026-09-05', 45000.00,
                                   'ตู้แช่แข็ง 2 ประตู — โอนจากบัญชีบริษัท 5 ก.ย.');
  select created_by, expense_month into v_by, v_txt from owner_expenses where id = v_inv;
  assert v_by = v_owner, format('TC-05: created_by is %s, expected the caller', v_by);
  assert v_txt is null, format('TC-05: an investment carries expense_month %s', v_txt);

  --------------------------------------------------------------------------------- TC-06
  v_mon := fn_record_owner_expense(v_k2, 'MONTHLY_FIXED', date '2026-09-28', 12000.00,
                                   'ค่าเช่าสาขามีนบุรี เดือน ต.ค. — โอน 28 ก.ย.', '2026-10', v_branch);
  select expense_month into v_txt from owner_expenses where id = v_mon;
  assert v_txt = '2026-10', format('TC-06: the monthly row''s month is %s, expected 2026-10', v_txt);

  --------------------------------------------------------------------- TC-07, distinguishable
  select kind::text, pnl_month into v_txt, v_txt2 from v_owner_expenses where id = v_inv;
  assert v_txt = 'INVESTMENT' and v_txt2 = '2026-09',
    format('TC-07: the investment reads kind=%s pnl_month=%s, expected INVESTMENT / 2026-09', v_txt, v_txt2);
  select kind::text, pnl_month into v_txt, v_txt2 from v_owner_expenses where id = v_mon;
  assert v_txt = 'MONTHLY_FIXED' and v_txt2 = '2026-10',
    format('TC-07: the rent reads kind=%s pnl_month=%s — October rent paid in September must '
           'land in October', v_txt, v_txt2);

  --------------------------------------------------------------------------------- TC-08
  -- The retry: same key, same payload. The original id, and nothing written.
  v_again := fn_record_owner_expense(v_k1, 'INVESTMENT', date '2026-09-05', 45000.00,
                                     'ตู้แช่แข็ง 2 ประตู — โอนจากบัญชีบริษัท 5 ก.ย.');
  assert v_again = v_inv, format('TC-08: the retry returned %s, expected %s', v_again, v_inv);
  select count(*) into v_n from owner_expenses;
  assert v_n = 2, format('TC-08: the retry wrote a row (%s rows, expected 2)', v_n);

  --------------------------------------------------------------------------------- TC-09
  -- Two genuine identical expenses are two rows. A payload key would have refused this.
  v_inv2 := fn_record_owner_expense(gen_random_uuid(), 'INVESTMENT', date '2026-09-05', 45000.00,
                                    'ตู้แช่แข็ง 2 ประตู — โอนจากบัญชีบริษัท 5 ก.ย.');
  assert v_inv2 <> v_inv, 'TC-09: a second genuine expense was folded into the first (R39)';

  --------------------------------------------------------------------------------- TC-10
  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(v_k1, 'INVESTMENT', date '2026-09-05', 45001.00,
                                    'ตู้แช่แข็ง 2 ประตู — โอนจากบัญชีบริษัท 5 ก.ย.');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%EXPENSE_IDEMPOTENCY_CONFLICT%';
  end;
  assert v_ok, format('TC-10: a reused key with a new amount was not refused (%s)',
                      coalesce(v_err, 'no exception at all'));
  select amount_thb into v_num from owner_expenses where id = v_inv;
  assert v_num = 45000.00, format('TC-10: the original row now reads %s', v_num);

  --------------------------------------------------------------------------------- TC-11
  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(null, 'OTHER', date '2026-09-05', 100, 'ค่าแก๊ส');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%IDEMPOTENCY_KEY_REQUIRED%';
  end;
  assert v_ok, format('TC-11: a keyless call was accepted (%s)', coalesce(v_err, 'no exception at all'));

  ------------------------------------------------------------------- TC-12 / TC-13, L2 and L3
  select count(*) into v_n from owner_expenses;

  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(gen_random_uuid(), 'OTHER', date '2026-09-05', 100, 'ค่าแก๊ส');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-12: an L2 recorded an owner expense (%s)', coalesce(v_err, 'no exception at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(gen_random_uuid(), 'OTHER', date '2026-09-05', 100, 'ค่าแก๊ส');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-13: an L3 recorded an owner expense (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-14
  perform set_config('request.jwt.claims', json_build_object('sub', v_gone)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(gen_random_uuid(), 'OTHER', date '2026-09-05', 100, 'ค่าแก๊ส');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%NO_ACTOR%';
  end;
  assert v_ok, format('TC-14: a deactivated Owner was not refused by name (%s)',
                      coalesce(v_err, 'no exception at all'));

  declare v_after bigint;
  begin
    select count(*) into v_after from owner_expenses;
    assert v_after = v_n, format('TC-12/13/14: a refused call still wrote (%s → %s rows)', v_n, v_after);
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-15
  foreach v_amt in array array[0, -5]::numeric[] loop
    v_ok := false; v_err := null;
    begin
      perform fn_record_owner_expense(gen_random_uuid(), 'OTHER', date '2026-09-05', v_amt, 'ค่าแก๊ส');
    exception when others then
      v_err := sqlerrm;
      v_ok  := v_err like '%EXPENSE_AMOUNT_INVALID%';
    end;
    assert v_ok, format('TC-15: amount %s was accepted (%s)', v_amt, coalesce(v_err, 'no exception at all'));
  end loop;
  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(gen_random_uuid(), 'OTHER', date '2026-09-05', null, 'ค่าแก๊ส');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%EXPENSE_AMOUNT_INVALID%';
  end;
  assert v_ok, format('TC-15: a null amount was accepted (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-16
  foreach v_det in array array['', '   '] loop
    v_ok := false; v_err := null;
    begin
      perform fn_record_owner_expense(gen_random_uuid(), 'OTHER', date '2026-09-05', 100, v_det);
    exception when others then
      v_err := sqlerrm;
      v_ok  := v_err like '%EXPENSE_DETAIL_REQUIRED%';
    end;
    assert v_ok, format('TC-16: detail %L was accepted — nothing to match a transfer to (%s)',
                        v_det, coalesce(v_err, 'no exception at all'));
  end loop;
  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(gen_random_uuid(), 'OTHER', date '2026-09-05', 100, null);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%EXPENSE_DETAIL_REQUIRED%';
  end;
  assert v_ok, format('TC-16: a null detail was accepted (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-17
  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(gen_random_uuid(), 'MONTHLY_FIXED', date '2026-09-28', 12000, 'ค่าเช่า');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%EXPENSE_MONTH_REQUIRED%';
  end;
  assert v_ok, format('TC-17: a monthly cost with no month was accepted (%s)', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(gen_random_uuid(), 'INVESTMENT', date '2026-09-05', 45000,
                                    'ตู้แช่', '2026-10');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%EXPENSE_MONTH_NOT_ALLOWED%';
  end;
  assert v_ok, format('TC-17: an investment with a month of its own was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(gen_random_uuid(), 'MONTHLY_FIXED', date '2026-09-28', 12000,
                                    'ค่าเช่า', '2026-13');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%EXPENSE_MONTH_INVALID%';
  end;
  assert v_ok, format('TC-17: month 2026-13 was accepted (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-18
  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(gen_random_uuid(), null, date '2026-09-05', 100, 'ค่าแก๊ส');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%EXPENSE_KIND_REQUIRED%';
  end;
  assert v_ok, format('TC-18: a kindless expense was accepted (%s)', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(gen_random_uuid(), 'OTHER', null, 100, 'ค่าแก๊ส');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%EXPENSE_DATE_REQUIRED%';
  end;
  assert v_ok, format('TC-18: an undated expense was accepted (%s)', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_record_owner_expense(gen_random_uuid(), 'OTHER', date '2026-09-05', 100, 'ค่าแก๊ส',
                                    null, gen_random_uuid());
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%LOCATION_NOT_FOUND%';
  end;
  assert v_ok, format('TC-18: an unknown location was accepted (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-19
  -- Audited by ^ref-06's trigger, with the caller as actor and the key on the row (R32), and
  -- no parameter through which a caller could name somebody else.
  select count(*) into v_n
    from audit_log
   where table_name = 'owner_expenses' and row_id = v_inv and action = 'INSERT'
     and actor_id = v_owner and idempotency_key = v_k1;
  assert v_n = 1, format('TC-19: %s audit row(s) for the investment, expected 1', v_n);

  select pg_get_function_arguments(p.oid) into v_txt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_record_owner_expense';
  assert v_txt not ilike '%created_by%' and v_txt not ilike '%actor%',
    format('TC-19: fn_record_owner_expense exposes an actor parameter: %s', v_txt);

  --------------------------------------------------------------------------------- TC-20
  -- ^fix-numeric-scale reversed this case (PLAN-numeric-scale.md D3, NS-08). It asserted that
  -- 100.005 is stored as 100.01, and that a retry of 100.01 matched it. A third decimal is now
  -- refused by name and nothing is written. The corrected 100.01 then goes in under the SAME
  -- key: a refusal must not burn the key. That row is also the .01 in TC-22's September total.
  v_err := null;
  begin
    perform fn_record_owner_expense(v_k3, 'OTHER', date '2026-09-10', 100.005, 'ค่าแก๊ส 10 ก.ย.');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'TOO_MANY_DECIMALS: p_amount_thb is 100.005 %',
    format('TC-20: 100.005 got [%s]', coalesce(v_err, 'no error at all'));
  select count(*) into v_n from owner_expenses where idempotency_key = v_k3;
  assert v_n = 0, format('TC-20: the refused amount wrote %s row(s)', v_n);
  v_id := fn_record_owner_expense(v_k3, 'OTHER', date '2026-09-10', 100.01, 'ค่าแก๊ส 10 ก.ย.');
  select amount_thb into v_num from owner_expenses where id = v_id;
  assert v_num = 100.01, format('TC-20: the corrected amount was stored as %s', v_num);

  --------------------------------------------------------------------------------- TC-21
  select location_name_th into v_txt from v_owner_expenses where id = v_mon;
  assert v_txt = 'สาขามีนบุรี', format('TC-21: the branch row names location %s', v_txt);
  select location_name_th into v_txt from v_owner_expenses where id = v_inv;
  assert v_txt is null, format('TC-21: a central row names location %s', v_txt);

  --------------------------------------------------------------------------------- TC-22
  -- September: two 45,000.00 investments and a 100.01 refill. The database sums it.
  select month_total_thb into v_num from v_owner_expenses where id = v_inv;
  assert v_num = 90100.01, format('TC-22: September''s total is %s, expected 90100.01', v_num);
  select month_total_thb into v_num from v_owner_expenses where id = v_mon;
  assert v_num = 12000.00, format('TC-22: October''s total is %s, expected 12000.00', v_num);

  --------------------------------------------------------------------------------- TC-23
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  select count(*) into v_n from v_owner_expenses;
  assert v_n = 0, format('TC-23: an L2 reads %s owner expense row(s) (M11 AC, R20)', v_n);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  select count(*) into v_n from v_owner_expenses;
  assert v_n = 0, format('TC-23: an L3 reads %s owner expense row(s) (M11 AC, R20)', v_n);

  --------------------------------------------------------------------------------- TC-24
  -- Reaching past the view must fail, or the WHERE is decoration.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  set local role authenticated;
  v_ok := false;
  begin
    perform 1 from owner_expenses limit 1;
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'TC-24: an authenticated session read owner_expenses directly (ADR-004)';
  select count(*) into v_n from v_owner_expenses;
  assert v_n > 0, 'TC-24: a real authenticated L1 session read 0 rows through the view';
  reset role;

  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'owner_expenses'
     and grantee in ('anon', 'authenticated');
  assert v_n = 0, format('TC-24: %s grant(s) on owner_expenses (ADR-004)', v_n);

  raise exception 'EXPENSES_TEST_PASSED';   -- the only clean way back out
end $$;
