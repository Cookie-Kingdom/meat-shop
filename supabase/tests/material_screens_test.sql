-- Failure-case tests for card ^ref-52 — v_rice_day (view 270) and v_branch_expenses (view 271).
--
-- Covers TC-01 ... TC-12 from v.0.1/ref-47-52-branch-materials/PLAN-material-screens.md.
--
-- Assumes no unmerged lane's contract. Lanes C and D are merged, and this file writes its
-- rice_records and branch_expenses fixtures directly (as the test's superuser), against OPEN or
-- UNLOCKED reports, both of which lane C's fn_guard_report_closed admits. Every count is filtered
-- to this file's own locations, so a seeded branch cannot move one.
--
-- Each view is queried AS EACH ROLE, because the scope is the view's WHERE, not the screen's
-- filter (ADR-004, R34). The failure cases are the rows a role must NOT see, and the carry-in
-- that must stay null instead of reading as 0.00:
--   * a day with no rice yet reads "no rice left" (null ≠ 0, the lane D stub's rule)
--   * the carry-in is recomputed over a stored figure, so a closed day's number moves
--   * a switched rice_model rewrites a day already recorded (R29)
--   * another branch's L2, an L3 or a deactivated L2 reads a branch's rice or money
--   * anon holds SELECT on either view
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/material_screens_test.sql

do $$
declare
  v_owner uuid := '52525252-5252-5252-5252-525252525001';   -- L1
  v_adm_a uuid := '52525252-5252-5252-5252-525252525002';   -- L2 at A
  v_adm_b uuid := '52525252-5252-5252-5252-525252525003';   -- L2 at B
  v_cm    uuid := '52525252-5252-5252-5252-525252525004';   -- L3, also a member of A
  v_gone  uuid := '52525252-5252-5252-5252-525252525005';   -- L2 at A, deactivated
  v_bra   uuid;
  v_brb   uuid;
  v_d3    uuid;   -- A, three days back: rice row, cooked_remaining 3.00
  v_d2    uuid;   -- A, two days back: no rice row
  v_d1    uuid;   -- A, yesterday: rice row, cooked_remaining 0.00, stored carry-in 2.50
  v_d0    uuid;   -- A, today (OPEN): no rice row; two expenses
  v_b0    uuid;   -- B, today (OPEN): its first day; one expense
  v_r     record;
  v_n     bigint;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_adm_a), (v_adm_b), (v_cm), (v_gone);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',            'L1_OWNER',        true),
    (v_adm_a, 'ผู้ดูแลสาขา ก',      'L2_BRANCH_ADMIN', true),
    (v_adm_b, 'ผู้ดูแลสาขา ข',      'L2_BRANCH_ADMIN', true),
    (v_cm,    'ผู้ปฏิบัติ CM',       'L3_CM_OPERATOR',  true),
    (v_gone,  'ผู้ดูแลที่ถูกปิดบัญชี', 'L2_BRANCH_ADMIN', false);

  insert into locations (code, name_th, kind, rice_model)
       values ('J52A', 'สาขาข้าว ก', 'BRANCH', 'EXTERNAL_COOKED') returning id into v_bra;
  insert into locations (code, name_th, kind, rice_model)
       values ('J52B', 'สาขาข้าว ข', 'BRANCH', 'SELF_COOK') returning id into v_brb;
  insert into user_locations (profile_id, location_id) values
    (v_adm_a, v_bra), (v_adm_b, v_brb), (v_cm, v_bra), (v_gone, v_bra);

  -- daily_reports_one_open (...0009) is partial on status = 'OPEN', so the past days are
  -- UNLOCKED: one OPEN day per branch, and every day writable for the fixtures below.
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by, status)
       values (v_bra, current_date - 3, now() - interval '3 days', v_adm_a, 'UNLOCKED')
    returning id into v_d3;
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by, status)
       values (v_bra, current_date - 2, now() - interval '2 days', v_adm_a, 'UNLOCKED')
    returning id into v_d2;
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by, status)
       values (v_bra, current_date - 1, now() - interval '1 day', v_adm_a, 'UNLOCKED')
    returning id into v_d1;
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_bra, current_date, now(), v_adm_a) returning id into v_d0;
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_brb, current_date, now(), v_adm_b) returning id into v_b0;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  insert into rice_records (daily_report_id, location_id, event_date, model,
                            carried_in_cooked_kg, cooked_received_kg, cooked_remaining_kg, created_by)
       values (v_d3, v_bra, current_date - 3, 'EXTERNAL_COOKED', null, 10.00, 3.00, v_adm_a);
  -- A stored carry-in that differs from what a recompute would give (3.00): the day carried
  -- what was stored when it was written, and the view must not re-derive it.
  insert into rice_records (daily_report_id, location_id, event_date, model,
                            carried_in_cooked_kg, cooked_received_kg, cooked_remaining_kg, created_by)
       values (v_d1, v_bra, current_date - 1, 'EXTERNAL_COOKED', 2.50, 8.00, 0.00, v_adm_a);

  insert into branch_expenses (daily_report_id, category, amount_thb, paid_by_person, detail, created_by) values
    (v_d0, 'PACKAGING', 120.50, 'สมศรี', 'ถุงซิปเนื้อ 1 แพ็ค', v_adm_a),
    (v_d0, 'OTHER',      40.00, 'สมชาย', null,                 v_adm_a),
    (v_b0, 'RICE',       85.00, 'มานี',  'ข้าวดิบ 2 กก.',       v_adm_b);

  --------------------------------------------------------------------------------- TC-01
  select count(*) into v_n from v_rice_day where location_id = v_bra;
  assert v_n = 4, format('TC-01: branch A has 4 days and v_rice_day returns %s — a day with no rice row went missing', v_n);

  --------------------------------------------------------------------------------- TC-02
  -- No row on D-2: the carry-in is the most recent earlier row's cooked_remaining (D-3, 3.00).
  select * into v_r from v_rice_day where daily_report_id = v_d2;
  assert v_r.carried_in_cooked_kg = 3.00,
    format('TC-02: D-2 carries [%s], expected 3.00 from the most recent earlier row', v_r.carried_in_cooked_kg);
  assert v_r.rice_record_id is null and v_r.cooked_received_kg is null and v_r.cooked_remaining_kg is null
     and v_r.raw_purchased_kg is null and v_r.cooked_today_kg is null and v_r.raw_remaining_kg is null,
    'TC-02: a day with no rice row reads figures of its own — nothing recorded must read null';
  assert v_r.model = 'EXTERNAL_COOKED', format('TC-02: D-2 model [%s], expected the branch''s', v_r.model);

  -- The stored figure wins where a row exists.
  select * into v_r from v_rice_day where daily_report_id = v_d1;
  assert v_r.carried_in_cooked_kg = 2.50,
    format('TC-02: D-1 reads carry-in [%s] — the stored 2.50 was recomputed', v_r.carried_in_cooked_kg);

  --------------------------------------------------------------------------------- TC-03
  -- Today: yesterday's row says 0.00 left. That is "no rice left", a real 0, and must not be null.
  select * into v_r from v_rice_day where daily_report_id = v_d0;
  assert v_r.carried_in_cooked_kg is not null and v_r.carried_in_cooked_kg = 0.00,
    format('TC-03: today carries [%s], expected 0.00 from yesterday''s row', v_r.carried_in_cooked_kg);

  --------------------------------------------------------------------------------- TC-04
  -- B's first day: nobody has recorded rice there. Null, never a coalesced 0.
  select * into v_r from v_rice_day where daily_report_id = v_b0;
  assert found, 'TC-04: branch B''s day is missing from v_rice_day';
  assert v_r.carried_in_cooked_kg is null,
    format('TC-04: a first day carries [%s] — "no data" read as a number', v_r.carried_in_cooked_kg);
  assert v_r.model = 'SELF_COOK', format('TC-04: B reads model [%s]', v_r.model);

  --------------------------------------------------------------------------------- TC-05
  -- R29: the Owner switches A to SELF_COOK. A recorded day keeps its snapshot; a day with no row
  -- reads the branch's model as it is now.
  update locations set rice_model = 'SELF_COOK' where id = v_bra;
  select * into v_r from v_rice_day where daily_report_id = v_d3;
  assert v_r.model = 'EXTERNAL_COOKED',
    format('TC-05: a recorded day reads model [%s] after the switch — the snapshot was rewritten (R29)', v_r.model);
  select * into v_r from v_rice_day where daily_report_id = v_d2;
  assert v_r.model = 'SELF_COOK',
    format('TC-05: a day with no row reads model [%s], expected the branch''s new SELF_COOK', v_r.model);

  --------------------------------------------------------------------------------- TC-06
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  select count(*) into v_n from v_rice_day where location_id = v_bra;
  assert v_n = 0, format('TC-06: branch B''s L2 reads %s of branch A''s rice days', v_n);
  select count(*) into v_n from v_rice_day where location_id = v_brb;
  assert v_n = 1, format('TC-06: branch B''s L2 reads %s of its own 1 day', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  select count(*) into v_n from v_rice_day where location_id in (v_bra, v_brb);
  assert v_n = 0, format('TC-06: an L3 reads %s rice day(s)', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_gone)::text, true);
  select count(*) into v_n from v_rice_day where location_id in (v_bra, v_brb);
  assert v_n = 0, format('TC-06: a deactivated L2 still holding A reads %s rice day(s) (R31)', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_rice_day where location_id in (v_bra, v_brb);
  assert v_n = 5, format('TC-06: the Owner reads %s of 5 rice days across both branches', v_n);

  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'v_rice_day'
     and (column_name like '%price%' or column_name like '%\_thb');
  assert v_n = 0, format('TC-06: v_rice_day carries %s price column(s) (R20)', v_n);

  --------------------------------------------------------------------------------- TC-07
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  select count(*) into v_n from v_branch_expenses where daily_report_id = v_d0;
  assert v_n = 2, format('TC-07: A''s L2 reads %s of its 2 expenses today', v_n);
  select * into v_r from v_branch_expenses where daily_report_id = v_d0 and category = 'PACKAGING';
  assert v_r.report_date = current_date and v_r.location_id = v_bra and v_r.amount_thb = 120.50
     and v_r.paid_by_person = 'สมศรี' and v_r.detail = 'ถุงซิปเนื้อ 1 แพ็ค',
    format('TC-07: the PACKAGING row reads date [%s] amount [%s] payer [%s]',
           v_r.report_date, v_r.amount_thb, v_r.paid_by_person);

  --------------------------------------------------------------------------------- TC-08
  select count(*) into v_n from v_branch_expenses where location_id = v_brb;
  assert v_n = 0, format('TC-08: A''s L2 reads %s of branch B''s expenses', v_n);

  --------------------------------------------------------------------------------- TC-09
  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  select count(*) into v_n from v_branch_expenses where location_id in (v_bra, v_brb);
  assert v_n = 0, format('TC-09: an L3 reads %s expense row(s) — no money reaches L3 (R20)', v_n);

  --------------------------------------------------------------------------------- TC-10
  perform set_config('request.jwt.claims', json_build_object('sub', v_gone)::text, true);
  select count(*) into v_n from v_branch_expenses where location_id in (v_bra, v_brb);
  assert v_n = 0, format('TC-10: a deactivated L2 still holding A reads %s expense row(s) (R31)', v_n);

  --------------------------------------------------------------------------------- TC-11
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_branch_expenses where location_id in (v_bra, v_brb);
  assert v_n = 3, format('TC-11: the Owner reads %s of 3 expenses', v_n);

  --------------------------------------------------------------------------------- TC-12
  assert has_table_privilege('authenticated', 'public.v_rice_day', 'SELECT'),
    'TC-12: authenticated cannot read v_rice_day';
  assert not has_table_privilege('anon', 'public.v_rice_day', 'SELECT'),
    'TC-12: anon can read v_rice_day';
  assert has_table_privilege('authenticated', 'public.v_branch_expenses', 'SELECT'),
    'TC-12: authenticated cannot read v_branch_expenses';
  assert not has_table_privilege('anon', 'public.v_branch_expenses', 'SELECT'),
    'TC-12: anon can read v_branch_expenses';

  raise exception 'MATERIAL_SCREENS_TEST_PASSED';   -- the only clean way back out
end $$;
