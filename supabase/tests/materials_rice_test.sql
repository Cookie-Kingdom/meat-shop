-- Failure-case tests for card ^ref-48 — fn_record_rice.
--
-- Covers TC-10 ... TC-30 from TDD-materials.md. TC-31 (a morning and an evening write racing on
-- one report) needs two sessions and lives in materials_concurrency_test.sh.
--
-- Assumes lane C's ...0018: fn_guard_report_closed raises REPORT_CLOSED on a rice_records
-- write against a CLOSED report and admits an UNLOCKED one (PLAN-sales.md T1 §3). TC-28 fails
-- until lane C merges; nothing else here depends on it.
--
-- Each assert is a way this function fails silently rather than loudly:
--   * the evening visit erases the morning's received weight, and the day's rice cost is wrong
--   * a replayed morning call overwrites a figure corrected since
--   * the carry-in reads 0 where nobody has recorded rice, and "no history" reads as "none left"
--   * a SELF_COOK figure lands on an EXTERNAL_COOKED day and belongs to no process
--   * an Owner's noon model change makes the evening write fail on a constraint name
--   * an Owner edits branch rice that v0.2:58 gives them view-only rights on
--   * rice posts a ledger row, and the branch has two rice balances
--
-- Errors are captured into v_err and asserted after the block, never inside the handler.
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/materials_rice_test.sql

do $$
declare
  v_owner   uuid := '48484848-4848-4848-4848-484848484801';   -- L1
  v_adm_a   uuid := '48484848-4848-4848-4848-484848484802';   -- L2 at A (EXTERNAL_COOKED) and C (no model)
  v_adm_b   uuid := '48484848-4848-4848-4848-484848484803';   -- L2 at B (SELF_COOK)
  v_cm      uuid := '48484848-4848-4848-4848-484848484804';   -- L3, also a member of A
  v_bra     uuid;
  v_brb     uuid;
  v_brc     uuid;
  v_hist    uuid;
  v_rep_a   uuid;
  v_rep_b   uuid;
  v_rep_c   uuid;
  v_rep_old uuid;
  v_k_am    uuid := gen_random_uuid();
  v_k_pm    uuid := gen_random_uuid();
  v_res     json;
  v_err     text;
  v_id      uuid;
  v_row     rice_records;
  v_n       bigint;
  v_ledger  bigint;
  v_audit   bigint;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_adm_a), (v_adm_b), (v_cm);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',        'L1_OWNER',        true),
    (v_adm_a, 'ผู้ดูแลมีนบุรี',  'L2_BRANCH_ADMIN', true),
    (v_adm_b, 'ผู้ดูแลศาลาแดง', 'L2_BRANCH_ADMIN', true),
    (v_cm,    'ผู้ปฏิบัติ CM',   'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind, rice_model)
       values ('R48A', 'มีนบุรีทดสอบ', 'BRANCH', 'EXTERNAL_COOKED') returning id into v_bra;
  insert into locations (code, name_th, kind, rice_model)
       values ('R48B', 'ศาลาแดงทดสอบ', 'BRANCH', 'SELF_COOK') returning id into v_brb;
  insert into locations (code, name_th, kind)
       values ('R48C', 'สาขายังไม่ตั้งโมเดลข้าว', 'BRANCH') returning id into v_brc;

  insert into user_locations (profile_id, location_id) values
    (v_adm_a, v_bra), (v_adm_a, v_brc), (v_adm_b, v_brb),
    -- The L3 IS a member of A, so TC-13 is refused on role and not on membership.
    (v_cm, v_bra);

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);

  -- Branch A's rice history: a day two days back, left with 3.00 kg cooked. It is inserted while
  -- the report is OPEN and closed afterwards, because lane C's guard refuses a child row on a
  -- CLOSED report, and one OPEN report per branch leaves room for today's.
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_bra, current_date - 2, now() - interval '2 days', v_adm_a) returning id into v_hist;
  insert into rice_records (daily_report_id, location_id, event_date, model, cooked_remaining_kg, created_by)
       values (v_hist, v_bra, current_date - 2, 'EXTERNAL_COOKED', 3.00, v_adm_a);
  update daily_reports set status = 'CLOSED', closed_by = v_adm_a, closed_at = now() where id = v_hist;

  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_bra, current_date, now(), v_adm_a) returning id into v_rep_a;
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_brb, current_date, now(), v_adm_b) returning id into v_rep_b;
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_brc, current_date, now(), v_adm_a) returning id into v_rep_c;

  --------------------------------------------------------------------------------- TC-10
  v_err := null;
  begin
    perform fn_record_rice(null, v_rep_a, p_cooked_received_kg => 10.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'IDEMPOTENCY_KEY_REQUIRED%',
    format('TC-10: expected IDEMPOTENCY_KEY_REQUIRED, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-11
  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), gen_random_uuid(), p_cooked_received_kg => 10.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_NOT_FOUND%',
    format('TC-11: expected REPORT_NOT_FOUND, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-12
  -- v0.2:58: the Owner views and configures supporting stock; the branch edits it. If the Owner
  -- overrules this, this assert and one preamble line change together (TDD Open question 1).
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_a, p_cooked_received_kg => 10.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-12: an L1 Owner wrote branch rice, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-13
  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_a, p_cooked_received_kg => 10.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-13: an L3 with a membership row wrote branch rice, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-14
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_a, p_cooked_received_kg => 10.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN_LOCATION%',
    format('TC-14: an L2 of branch B wrote branch A''s rice, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-15
  update profiles set is_active = false where id = v_adm_a;
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_a, p_cooked_received_kg => 10.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'NO_ACTOR%',
    format('TC-15: expected NO_ACTOR for a deactivated admin, got [%s]', coalesce(v_err, 'no error at all'));
  update profiles set is_active = true where id = v_adm_a;

  --------------------------------------------------------------------------------- TC-16
  -- The CHECK allows a BRANCH with no model, and the day still opens. Rice cannot be recorded
  -- until the Owner picks one, and the function must not guess.
  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_c, p_cooked_remaining_kg => 1.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'RICE_MODEL_NOT_SET%',
    format('TC-16: expected RICE_MODEL_NOT_SET, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-17
  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_a, p_cooked_received_kg => -1.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'RICE_WEIGHT_INVALID%' and v_err like '%cooked_received_kg%',
    format('TC-17: expected RICE_WEIGHT_INVALID naming cooked_received_kg, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-18
  -- Both directions. M7A never cooks; M7B never receives cooked rice.
  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_a, p_raw_purchased_kg => 5.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'RICE_FIELD_NOT_FOR_MODEL%' and v_err like '%raw_purchased_kg%',
    format('TC-18: an EXTERNAL_COOKED branch took a raw purchase, got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_b, p_cooked_received_kg => 5.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'RICE_FIELD_NOT_FOR_MODEL%' and v_err like '%cooked_received_kg%',
    format('TC-18: a SELF_COOK branch took a cooked-rice receipt, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-19
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_a);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'RICE_VALUES_REQUIRED%',
    format('TC-19: expected RICE_VALUES_REQUIRED, got [%s]', coalesce(v_err, 'no error at all'));

  select count(*) into v_n from rice_records where daily_report_id in (v_rep_a, v_rep_b, v_rep_c);
  assert v_n = 0, format('TC-10..19: %s rice row(s) written by calls that all raised', v_n);

  ---------------------------------------------------------------------- the happy path
  select count(*) into v_ledger from stock_ledger;
  select count(*) into v_audit  from audit_log where table_name = 'rice_records';

  --------------------------------------------------------------------------------- TC-20
  -- M7A, the morning (BR 03): cooked rice received.
  v_res := fn_record_rice(v_k_am, v_rep_a, p_cooked_received_kg => 10.00);
  v_id  := (v_res ->> 'rice_record_id')::uuid;
  select * into v_row from rice_records where id = v_id;

  assert v_row.daily_report_id = v_rep_a and v_row.location_id = v_bra
     and v_row.event_date = current_date,
    'TC-20: the rice row is not on this report, branch and business date';
  assert v_row.model = 'EXTERNAL_COOKED',
    format('TC-20: model snapshot is [%s], the branch is EXTERNAL_COOKED', v_row.model);
  assert v_row.cooked_received_kg = 10.00,
    format('TC-20: cooked_received_kg is [%s], sent 10.00', v_row.cooked_received_kg);
  -- The most recent row strictly before the report date, as fn_open_daily_report reads it.
  assert v_row.carried_in_cooked_kg = 3.00 and (v_res ->> 'carried_in_cooked_kg')::numeric = 3.00,
    format('TC-20: carried_in_cooked_kg is [%s], expected 3.00 from two days back', v_row.carried_in_cooked_kg);
  assert v_row.created_by = v_adm_a, 'TC-20: created_by is not the actor';
  assert v_row.cooked_price_thb_per_kg is null and v_row.raw_price_thb_per_kg is null,
    'TC-20: an L2 write set a price column (R20)';
  assert v_row.idempotency_key = v_k_am, 'TC-20: the morning key was not stamped on the row';
  assert (v_res::jsonb ? 'cooked_price_thb_per_kg') is false,
    'TC-20: the response carries a price field to an L2 caller (R20)';

  --------------------------------------------------------------------------------- TC-21
  -- M7A, the evening (BR 07), under a fresh key. Same row. The morning's figure survives
  -- because the evening sent nothing for it.
  v_res := fn_record_rice(v_k_pm, v_rep_a, p_cooked_remaining_kg => 2.00);
  assert (v_res ->> 'rice_record_id')::uuid = v_id,
    'TC-21: the evening visit returned a different rice row';
  select * into v_row from rice_records where id = v_id;
  assert v_row.cooked_received_kg = 10.00,
    format('TC-21: the evening erased the morning''s receipt — cooked_received_kg is [%s]', v_row.cooked_received_kg);
  assert v_row.cooked_remaining_kg = 2.00,
    format('TC-21: cooked_remaining_kg is [%s], sent 2.00', v_row.cooked_remaining_kg);
  assert v_row.idempotency_key = v_k_pm,
    'TC-21: the row does not hold the most recent write''s key (R39)';
  select count(*) into v_n from rice_records where daily_report_id = v_rep_a;
  assert v_n = 1, format('TC-21: %s rice rows for one report', v_n);

  --------------------------------------------------------------------------------- TC-22
  -- The morning call replayed after the evening, carrying a different figure. The key has been
  -- seen, so this is a dropped connection and not a correction: nothing moves (R4).
  v_res := fn_record_rice(v_k_am, v_rep_a, p_cooked_received_kg => 99.00);
  assert (v_res ->> 'rice_record_id')::uuid = v_id, 'TC-22: a replay returned a different row';
  select * into v_row from rice_records where id = v_id;
  assert v_row.cooked_received_kg = 10.00,
    format('TC-22: a replayed key rewrote cooked_received_kg to [%s]', v_row.cooked_received_kg);
  assert v_row.idempotency_key = v_k_pm, 'TC-22: a replay re-stamped the older key on the row';

  --------------------------------------------------------------------------------- TC-23
  -- Branch B has no rice history: NULL, never 0.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_res := fn_record_rice(gen_random_uuid(), v_rep_b, p_raw_purchased_kg => 5.00);
  assert (v_res ->> 'carried_in_cooked_kg') is null,
    format('TC-23: carried_in_cooked_kg is [%s] with no history — must be null, not 0', v_res ->> 'carried_in_cooked_kg');
  v_id := (v_res ->> 'rice_record_id')::uuid;

  --------------------------------------------------------------------------------- TC-24
  -- M7B's evening: cooked today, raw left, cooked left. The morning's purchase stays.
  perform fn_record_rice(gen_random_uuid(), v_rep_b,
                         p_cooked_today_kg => 12.00, p_raw_remaining_kg => 1.00,
                         p_cooked_remaining_kg => 4.00);
  select * into v_row from rice_records where id = v_id;
  assert v_row.model = 'SELF_COOK'
     and v_row.raw_purchased_kg = 5.00 and v_row.cooked_today_kg = 12.00
     and v_row.raw_remaining_kg = 1.00 and v_row.cooked_remaining_kg = 4.00,
    format('TC-24: M7B row is [%s/%s/%s/%s], expected 5.00/12.00/1.00/4.00',
           v_row.raw_purchased_kg, v_row.cooked_today_kg, v_row.raw_remaining_kg, v_row.cooked_remaining_kg);

  --------------------------------------------------------------------------------- TC-25
  -- The Owner switches branch B to EXTERNAL_COOKED at noon. Today's row was written as
  -- SELF_COOK, and that snapshot is what the next write is validated against (R29) — both ways.
  update locations set rice_model = 'EXTERNAL_COOKED' where id = v_brb;

  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_b, p_cooked_today_kg => 13.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err is null,
    format('TC-25: a SELF_COOK day refused a SELF_COOK field after the branch''s model changed: [%s]', v_err);
  select cooked_today_kg into v_row.cooked_today_kg from rice_records where id = v_id;
  assert v_row.cooked_today_kg = 13.00, 'TC-25: the correction did not land';

  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_b, p_cooked_received_kg => 1.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'RICE_FIELD_NOT_FOR_MODEL%',
    format('TC-25: the day was validated against the new model, not its own snapshot, got [%s]', coalesce(v_err, 'no error at all'));

  update locations set rice_model = 'SELF_COOK' where id = v_brb;

  --------------------------------------------------------------------------------- TC-26
  -- Rice's balance is rice_records. A ledger row would be a second balance for the same rice.
  select count(*) into v_n from stock_ledger;
  assert v_n = v_ledger, format('TC-26: recording rice wrote %s ledger row(s)', v_n - v_ledger);

  --------------------------------------------------------------------------------- TC-27
  -- Five writes changed a row (TC-20, 21, 23, 24, 25); the replay changed nothing. One audit
  -- row each, all from ^ref-06's trigger (R32).
  select count(*) into v_n from audit_log where table_name = 'rice_records';
  assert v_n = v_audit + 5,
    format('TC-27: audit_log gained %s rice rows for five writes and one replay, expected 5', v_n - v_audit);

  --------------------------------------------------------------------------------- TC-28
  -- Lane C's trigger, not this function, refuses a closed day (PLAN Finding 4).
  update daily_reports set status = 'CLOSED', closed_by = v_adm_a, closed_at = now() where id = v_rep_a;
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_a, p_cooked_remaining_kg => 1.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like '%REPORT_CLOSED%',
    format('TC-28: a closed day took a rice write, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-29
  -- R28's window, once the opening window is shut. A day ten back, UNLOCKED so lane C's guard
  -- admits it and the window is the only thing left to refuse it.
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by)
       values (v_bra, current_date - 10, now() - interval '10 days', 'UNLOCKED', v_adm_a)
    returning id into v_rep_old;
  insert into opening_balance_close (closed_by, closed_idempotency_key) values (v_owner, gen_random_uuid());
  insert into config_settings (key, value_numeric, effective_from, created_by)
       values ('unlock_max_days_back', 3, date '2026-01-01', v_owner);

  v_err := null;
  begin
    perform fn_record_rice(gen_random_uuid(), v_rep_old, p_cooked_remaining_kg => 1.00);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'BACKDATE_NOT_ALLOWED%',
    format('TC-29: a day ten back took a rice write with a 3-day window, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-30
  assert has_function_privilege('authenticated',
           'public.fn_record_rice(uuid, uuid, numeric, numeric, numeric, numeric, numeric)', 'EXECUTE'),
    'TC-30: authenticated cannot execute fn_record_rice';
  assert not has_function_privilege('anon',
           'public.fn_record_rice(uuid, uuid, numeric, numeric, numeric, numeric, numeric)', 'EXECUTE'),
    'TC-30: anon can execute fn_record_rice';

  raise exception 'MATERIALS_RICE_TEST_PASSED';   -- the only clean way back out
end $$;
