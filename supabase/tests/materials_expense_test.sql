-- Failure-case tests for card ^ref-51 — fn_record_branch_expense.
--
-- Covers TC-74 ... TC-86 from TDD-materials.md.
--
-- Assumes lane C's ...0018: fn_guard_report_closed raises REPORT_CLOSED on a branch_expenses
-- insert against a CLOSED report (PLAN-sales.md T1 §3). TC-84 fails until lane C merges;
-- nothing else here depends on it.
--
-- Each assert is a way this function fails silently rather than loudly:
--   * an expense lands with nobody behind it, and nobody can be reimbursed (the card's acceptance)
--   * a zero or negative "expense" becomes a P&L row
--   * a retried save books the same cash twice
--   * an Owner, or an L3, types a branch's expenses
--   * an expense posts a ledger row, and money becomes stock
--
-- Errors are captured into v_err and asserted after the block, never inside the handler.
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/materials_expense_test.sql

do $$
declare
  v_owner   uuid := '51515151-5151-5151-5151-515151515101';   -- L1
  v_adm_a   uuid := '51515151-5151-5151-5151-515151515102';   -- L2 at A
  v_adm_b   uuid := '51515151-5151-5151-5151-515151515103';   -- L2 at B
  v_cm      uuid := '51515151-5151-5151-5151-515151515104';   -- L3, also a member of A
  v_bra     uuid;
  v_brb     uuid;
  v_rep_a   uuid;
  v_rep_old uuid;
  v_key     uuid := gen_random_uuid();
  v_id      uuid;
  v_id2     uuid;
  v_err     text;
  v_n       bigint;
  v_ledger  bigint;
  v_amt     numeric;
  v_row     branch_expenses;
  v_txt     text;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_adm_a), (v_adm_b), (v_cm);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',       'L1_OWNER',        true),
    (v_adm_a, 'ผู้ดูแลสาขา ก', 'L2_BRANCH_ADMIN', true),
    (v_adm_b, 'ผู้ดูแลสาขา ข', 'L2_BRANCH_ADMIN', true),
    (v_cm,    'ผู้ปฏิบัติ CM',  'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind, rice_model)
       values ('E51A', 'สาขาค่าใช้จ่าย ก', 'BRANCH', 'EXTERNAL_COOKED') returning id into v_bra;
  insert into locations (code, name_th, kind, rice_model)
       values ('E51B', 'สาขาค่าใช้จ่าย ข', 'BRANCH', 'SELF_COOK') returning id into v_brb;
  insert into user_locations (profile_id, location_id) values
    (v_adm_a, v_bra), (v_adm_b, v_brb), (v_cm, v_bra);

  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_bra, current_date, now(), v_adm_a) returning id into v_rep_a;

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);

  --------------------------------------------------------------------------------- TC-74
  v_err := null;
  begin
    perform fn_record_branch_expense(null, v_rep_a, 'ค่าน้ำแข็ง', 40.00, 'สมชาย');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'IDEMPOTENCY_KEY_REQUIRED%',
    format('TC-74: expected IDEMPOTENCY_KEY_REQUIRED, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-75
  v_err := null;
  begin
    perform fn_record_branch_expense(gen_random_uuid(), gen_random_uuid(), 'ค่าน้ำแข็ง', 40.00, 'สมชาย');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_NOT_FOUND%',
    format('TC-75: expected REPORT_NOT_FOUND, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-76
  -- v0.2:59: the branch enters its expenses; the Owner reads every cost; L3 has no access.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_err := null;
  begin
    perform fn_record_branch_expense(gen_random_uuid(), v_rep_a, 'ค่าน้ำแข็ง', 40.00, 'สมชาย');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-76: an L1 Owner entered a branch expense, got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  v_err := null;
  begin
    perform fn_record_branch_expense(gen_random_uuid(), v_rep_a, 'ค่าน้ำแข็ง', 40.00, 'สมชาย');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-76: an L3 with a membership row entered a branch expense, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-77
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_err := null;
  begin
    perform fn_record_branch_expense(gen_random_uuid(), v_rep_a, 'ค่าน้ำแข็ง', 40.00, 'สมชาย');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN_LOCATION%',
    format('TC-77: an L2 of branch B entered branch A''s expense, got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);

  --------------------------------------------------------------------------------- TC-78
  foreach v_txt in array array[null, '   '] loop
    v_err := null;
    begin
      perform fn_record_branch_expense(gen_random_uuid(), v_rep_a, v_txt, 40.00, 'สมชาย');
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'EXPENSE_CATEGORY_REQUIRED%',
      format('TC-78: category [%s] got [%s]', coalesce(v_txt, 'null'), coalesce(v_err, 'no error at all'));
  end loop;

  --------------------------------------------------------------------------------- TC-79
  foreach v_amt in array array[null, 0, -5]::numeric[] loop
    v_err := null;
    begin
      perform fn_record_branch_expense(gen_random_uuid(), v_rep_a, 'ค่าน้ำแข็ง', v_amt, 'สมชาย');
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'EXPENSE_AMOUNT_INVALID%',
      format('TC-79: amount [%s] got [%s]', coalesce(v_amt::text, 'null'), coalesce(v_err, 'no error at all'));
  end loop;

  --------------------------------------------------------------------------------- TC-80
  -- The card's acceptance, by name: no expense without the person who fronted the cash.
  foreach v_txt in array array[null, '   '] loop
    v_err := null;
    begin
      perform fn_record_branch_expense(gen_random_uuid(), v_rep_a, 'ค่าน้ำแข็ง', 40.00, v_txt);
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'PAID_BY_REQUIRED%',
      format('TC-80: payer [%s] got [%s]', coalesce(v_txt, 'null'), coalesce(v_err, 'no error at all'));
  end loop;

  select count(*) into v_n from branch_expenses where daily_report_id = v_rep_a;
  assert v_n = 0, format('TC-74..80: %s expense row(s) written by calls that all raised', v_n);

  ---------------------------------------------------------------------- the happy path
  select count(*) into v_ledger from stock_ledger;

  --------------------------------------------------------------------------------- TC-81
  -- PACKAGING is lane K's convention for packaging spend (PLAN, ^ref-52 stub); stored as sent.
  v_id := fn_record_branch_expense(v_key, v_rep_a, ' PACKAGING ', 120.50, '  สมชาย ใจดี  ',
                                   'ซื้อกล่องสกรีนด่วน');
  select * into v_row from branch_expenses where id = v_id;
  assert v_row.daily_report_id = v_rep_a and v_row.category = 'PACKAGING'
     and v_row.amount_thb = 120.50 and v_row.paid_by_person = 'สมชาย ใจดี'
     and v_row.detail = 'ซื้อกล่องสกรีนด่วน',
    format('TC-81: stored [%s | %s | %s | %s]', v_row.category, v_row.amount_thb, v_row.paid_by_person, v_row.detail);
  assert v_row.created_by = v_adm_a, 'TC-81: created_by is not the actor';
  assert v_row.idempotency_key = v_key, 'TC-81: the key was not stamped on the row';

  v_id2 := fn_record_branch_expense(gen_random_uuid(), v_rep_a, 'ค่าน้ำแข็ง', 40.00, 'สมหญิง', '   ');
  select detail into v_txt from branch_expenses where id = v_id2;
  assert v_txt is null, format('TC-81: a blank detail was stored as [%s], not null', v_txt);

  --------------------------------------------------------------------------------- TC-82
  -- The key wins over a different payload (R4). One row, the original figure.
  assert fn_record_branch_expense(v_key, v_rep_a, 'ค่าแก๊ส', 999.00, 'คนอื่น') = v_id,
    'TC-82: a replay returned a different expense id';
  select count(*) into v_n from branch_expenses where idempotency_key = v_key;
  assert v_n = 1, format('TC-82: the key holds %s expense rows', v_n);
  select amount_thb into v_amt from branch_expenses where id = v_id;
  assert v_amt = 120.50, format('TC-82: a replay rewrote the amount to [%s]', v_amt);

  --------------------------------------------------------------------------------- TC-83
  select count(*) into v_n from stock_ledger;
  assert v_n = v_ledger, format('TC-83: recording an expense wrote %s ledger row(s) — money is not stock', v_n - v_ledger);

  --------------------------------------------------------------------------------- TC-84
  -- Lane C's trigger, not this function, refuses a closed day (PLAN Finding 4).
  update daily_reports set status = 'CLOSED', closed_by = v_adm_a, closed_at = now() where id = v_rep_a;
  v_err := null;
  begin
    perform fn_record_branch_expense(gen_random_uuid(), v_rep_a, 'ค่าน้ำแข็ง', 40.00, 'สมชาย');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like '%REPORT_CLOSED%',
    format('TC-84: a closed day took an expense, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-85
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by)
       values (v_bra, current_date - 10, now() - interval '10 days', 'UNLOCKED', v_adm_a)
    returning id into v_rep_old;
  insert into opening_balance_close (closed_by, closed_idempotency_key) values (v_owner, gen_random_uuid());
  insert into config_settings (key, value_numeric, effective_from, created_by)
       values ('unlock_max_days_back', 3, date '2026-01-01', v_owner);

  v_err := null;
  begin
    perform fn_record_branch_expense(gen_random_uuid(), v_rep_old, 'ค่าน้ำแข็ง', 40.00, 'สมชาย');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'BACKDATE_NOT_ALLOWED%',
    format('TC-85: a day ten back took an expense with a 3-day window, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-86
  assert has_function_privilege('authenticated',
           'public.fn_record_branch_expense(uuid, uuid, text, numeric, text, text)', 'EXECUTE'),
    'TC-86: authenticated cannot execute fn_record_branch_expense';
  assert not has_function_privilege('anon',
           'public.fn_record_branch_expense(uuid, uuid, text, numeric, text, text)', 'EXECUTE'),
    'TC-86: anon can execute fn_record_branch_expense';

  raise exception 'MATERIALS_EXPENSE_TEST_PASSED';   -- the only clean way back out
end $$;
