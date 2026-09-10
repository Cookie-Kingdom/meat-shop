-- Failure-case tests for card ^ref-39 — fn_open_daily_report and fn_require_branch.
--
-- Covers TC-10 ... TC-32 from TDD-branch-daily-open.md. TC-33 and TC-34 need two sessions
-- and live in branch_daily_concurrency_test.sh — the one-open-day index cannot be caught
-- from a single session, which is exactly what makes a one-session test useless there.
--
-- Each assert is a way this function fails silently rather than loudly:
--   * a replay re-opens a day that was closed with ready stock at zero (R13)
--   * two dates are open at one branch, and ADR-014 has no implementation left
--   * an L3 with a user_locations row at the branch is let through on membership alone
--   * a deactivated admin reads as FORBIDDEN, hiding the real state from whoever debugs it
--   * the rice carry-forward reads yesterday instead of the most recent row, and a branch
--     that sold no rice on Tuesday loses Monday's remainder on Wednesday
--   * null and 0 are collapsed, and "nobody has recorded rice here" becomes "no rice left"
--   * opening a day writes a ledger row, or a second audit row
--
-- Errors are captured into v_err and asserted after the block, rather than asserting inside
-- an exception handler: `assert false` in a `when others` handler catches its own failure
-- and reports the wrong message.
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/branch_daily_test.sql

do $$
declare
  v_owner   uuid := '99999999-9999-9999-9999-999999999901';   -- L1
  v_adm_a   uuid := '99999999-9999-9999-9999-999999999902';   -- L2 at branch A
  v_adm_b   uuid := '99999999-9999-9999-9999-999999999903';   -- L2 at branch B
  v_cm      uuid := '99999999-9999-9999-9999-999999999904';   -- L3, also a member of A
  v_bra     uuid;
  v_brb     uuid;
  v_ch      uuid;
  v_today   date := current_date;
  v_d1      date := current_date - 1;
  v_d2      date := current_date - 2;
  v_d3      date := current_date - 3;
  v_d7      date := current_date - 7;
  v_key     uuid := gen_random_uuid();
  v_res     json;
  v_err     text;
  v_id      uuid;
  v_id2     uuid;
  v_n       bigint;
  v_ledger  bigint;
  v_audit   bigint;
  v_ts      timestamptz;
  v_rep_a   uuid;
  v_rep_b7  uuid;
  v_rep_b2  uuid;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_adm_a), (v_adm_b), (v_cm);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',        'L1_OWNER',        true),
    (v_adm_a, 'ผู้ดูแลสาขา ก',  'L2_BRANCH_ADMIN', true),
    (v_adm_b, 'ผู้ดูแลสาขา ข',  'L2_BRANCH_ADMIN', true),
    (v_cm,    'ผู้ปฏิบัติ CM',   'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind, rice_model)
       values ('BRA', 'สาขาทดสอบ ก', 'BRANCH', 'EXTERNAL_COOKED') returning id into v_bra;
  insert into locations (code, name_th, kind, rice_model)
       values ('BRB', 'สาขาทดสอบ ข', 'BRANCH', 'SELF_COOK') returning id into v_brb;
  insert into locations (code, name_th, kind)
       values ('CHT', 'โรงรมทดสอบ', 'CHEF_HOUSE') returning id into v_ch;

  insert into user_locations (profile_id, location_id) values
    (v_adm_a, v_bra),
    -- Deliberately a member of the chef house too. Without it TC-26 would be refused on
    -- membership and never reach the kind check it is written to exercise.
    (v_adm_a, v_ch),
    (v_adm_b, v_brb),
    -- The L3 IS a member of branch A. TC-23 is only a real test because of this row:
    -- membership alone must not be a role check.
    (v_cm,    v_bra);

  ------------------------------------------------------------------- guards, before any row
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);

  --------------------------------------------------------------------------------- TC-17
  v_err := null;
  begin
    perform fn_open_daily_report(null, v_bra, v_today);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'IDEMPOTENCY_KEY_REQUIRED%',
    format('TC-17: expected IDEMPOTENCY_KEY_REQUIRED, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-18
  -- D3. No default: a defaulted business date is inherited silently by every call site and
  -- is wrong on the one shift that starts at 00:30.
  v_err := null;
  begin
    perform fn_open_daily_report(gen_random_uuid(), v_bra, null);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_DATE_REQUIRED%',
    format('TC-18: expected REPORT_DATE_REQUIRED, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-21
  -- A future date is a typo, and R5's unique key would make it permanent.
  v_err := null;
  begin
    perform fn_open_daily_report(gen_random_uuid(), v_bra, v_today + 1);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_DATE_FUTURE%',
    format('TC-21: expected REPORT_DATE_FUTURE, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-26
  -- The FK accepts CENTRAL and CHEF_HOUSE and neither runs a branch shift. The caller is a
  -- member here, so this is the kind check firing and not the membership check.
  v_err := null;
  begin
    perform fn_open_daily_report(gen_random_uuid(), v_ch, v_today);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'LOCATION_KIND_INVALID%',
    format('TC-26: expected LOCATION_KIND_INVALID, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-22
  -- L1 is refused. Opening a shift is the branch's act (API_DATA_MODEL.md RPC table). This
  -- is Open Question 1 in the TDD — if the Owner overrules it, this assert is what changes.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_err := null;
  begin
    perform fn_open_daily_report(gen_random_uuid(), v_bra, v_today);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-22: an L1 Owner opened a branch day, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-23
  -- The L3 holds a user_locations row at this very branch. Refused on the ROLE, so
  -- membership alone is not a role check.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  v_err := null;
  begin
    perform fn_open_daily_report(gen_random_uuid(), v_bra, v_today);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-23: an L3 with a membership row opened a branch day, got [%s]', coalesce(v_err, 'no error at all'));
  assert v_err not like 'FORBIDDEN_LOCATION%',
    'TC-23: the L3 was refused on membership, not on role — the role check is not doing the work';

  --------------------------------------------------------------------------------- TC-24
  -- Right role, wrong branch. A role check alone is not membership.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_err := null;
  begin
    perform fn_open_daily_report(gen_random_uuid(), v_bra, v_today);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN_LOCATION%',
    format('TC-24: an L2 at branch B opened branch A, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-25
  -- Deactivated mid-session, live token. NO_ACTOR and not FORBIDDEN: fn_current_role()
  -- folds is_active in and goes null, so asking the role first would report a real Owner
  -- as forbidden and hide the real state from whoever reads the error (R31).
  update profiles set is_active = false where id = v_adm_a;
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_err := null;
  begin
    perform fn_open_daily_report(gen_random_uuid(), v_bra, v_today);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'NO_ACTOR%',
    format('TC-25: expected NO_ACTOR for a deactivated admin, got [%s]', coalesce(v_err, 'no error at all'));
  update profiles set is_active = true where id = v_adm_a;

  ---------------------------------------------------------------------- the happy path, once
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);

  select count(*) into v_ledger from stock_ledger;
  select count(*) into v_audit  from audit_log where table_name = 'daily_reports';

  v_res := fn_open_daily_report(v_key, v_bra, v_today);
  v_id  := (v_res ->> 'daily_report_id')::uuid;

  --------------------------------------------------------------------------------- TC-10
  select count(*) into v_n from daily_reports where id = v_id and status = 'OPEN'
     and location_id = v_bra and report_date = v_today and opened_by = v_adm_a;
  assert v_n = 1, 'TC-10: the open did not produce one OPEN row at this branch and date, opened by the actor';

  --------------------------------------------------------------------------------- TC-11
  -- D4. Set from the transaction clock, never a parameter — a typed shift time is a
  -- back-date with no reason attached.
  select shift_started_at into v_ts from daily_reports where id = v_id;
  assert v_ts is not null, 'TC-11: shift_started_at is null — ADR-014 is undecidable for this row';
  assert v_ts <= now() and v_ts > now() - interval '1 minute',
    format('TC-11: shift_started_at is [%s], not the transaction clock', v_ts);

  --------------------------------------------------------------------------------- TC-12
  -- The third clock, taking its default. Nothing was passed in for it and nothing can be.
  select count(*) into v_n from daily_reports where id = v_id and created_at is not null;
  assert v_n = 1, 'TC-12: created_at is null on a row the function just wrote (ADR-007)';

  --------------------------------------------------------------------------------- TC-19
  -- Opening a day moves no stock. The tempting mistake here, the same way it was at
  -- ^ref-19: the location and the date are both in hand.
  select count(*) into v_n from stock_ledger;
  assert v_n = v_ledger,
    format('TC-19: opening a day wrote %s ledger rows — a shift open is not a stock movement', v_n - v_ledger);

  --------------------------------------------------------------------------------- TC-20
  -- Exactly one, written by ^ref-06's trigger. Two means the function inserted its own on
  -- top of the trigger's and every shift open is audited twice (R32).
  select count(*) into v_n from audit_log where table_name = 'daily_reports';
  assert v_n = v_audit + 1,
    format('TC-20: audit_log gained %s rows for one open, expected exactly 1 (R32)', v_n - v_audit);

  --------------------------------------------------------------------------------- TC-27
  -- Branch A has no rice history at all. NULL, never 0. Zero means "the branch has no rice
  -- left"; null means "nobody has recorded rice here yet", and BR 01 renders them
  -- differently. A coalesce(…, 0) anywhere on this path is the failure BR23 and ADR-006
  -- exist to prevent.
  assert (v_res ->> 'carried_in_cooked_kg') is null,
    format('TC-27: carried_in_cooked_kg is [%s] with no rice history — it must be null, not 0',
           v_res ->> 'carried_in_cooked_kg');

  --------------------------------------------------------------------------------- TC-30
  assert (v_res ->> 'rice_model') = 'EXTERNAL_COOKED',
    format('TC-30: rice_model returned [%s], locations says EXTERNAL_COOKED', v_res ->> 'rice_model');

  --------------------------------------------------------------------------------- TC-13
  -- Finding 5. R5's unique (location_id, report_date) IS the payload — a retry sends the
  -- same branch and date by construction. Same id, one row, no raise (R4).
  v_res := fn_open_daily_report(v_key, v_bra, v_today);
  assert (v_res ->> 'daily_report_id')::uuid = v_id,
    'TC-13: a replay returned a different daily_report_id';
  select count(*) into v_n from daily_reports where location_id = v_bra and report_date = v_today;
  assert v_n = 1, format('TC-13: a replay produced %s rows for one branch-day', v_n);

  -- And with a fresh key, since the key is not what carries idempotency here.
  v_res := fn_open_daily_report(gen_random_uuid(), v_bra, v_today);
  assert (v_res ->> 'daily_report_id')::uuid = v_id,
    'TC-13: the same branch-day under a new key returned a different id — the natural key is not carrying the retry';

  --------------------------------------------------------------------------------- TC-15
  -- Finding 4, from one session. A DIFFERENT date while today is OPEN. The message must
  -- name the open date, because that is what puts the branch in front of the close screen.
  -- Never auto-close: BR21 and ADR-014 both say close is pressed by a human, and R13 makes
  -- it a gate with a real precondition.
  v_err := null;
  begin
    perform fn_open_daily_report(gen_random_uuid(), v_bra, v_d1);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_STILL_OPEN%',
    format('TC-15: a second date opened while one was already OPEN, got [%s]', coalesce(v_err, 'no error at all'));
  assert v_err like '%' || v_today::text || '%',
    format('TC-15: REPORT_STILL_OPEN did not name the open date (%s), said [%s]', v_today, v_err);

  --------------------------------------------------------------------------------- TC-14
  -- Not idempotency, and it must not be treated as it. Returning the row would let a
  -- replayed call reverse a close that R13 gated on ready stock being zero.
  update daily_reports set status = 'CLOSED', closed_by = v_adm_a, closed_at = now()
   where id = v_id;
  v_err := null;
  begin
    perform fn_open_daily_report(v_key, v_bra, v_today);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_ALREADY_CLOSED%',
    format('TC-14: a replay after close was accepted, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-16
  -- D2, the index predicate as a contract. UNLOCKED is a past day reopened under R28 and
  -- must coexist with a new open day — a `status <> 'CLOSED'` predicate would make
  -- unlocking yesterday impossible the moment today is open, which is the only time anyone
  -- wants to. ^ref-08 builds against this.
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by)
       values (v_bra, v_d3, now() - interval '3 days', 'UNLOCKED', v_adm_a)
    returning id into v_rep_a;

  v_res := fn_open_daily_report(gen_random_uuid(), v_bra, v_d1);
  v_id2 := (v_res ->> 'daily_report_id')::uuid;
  select count(*) into v_n from daily_reports
   where location_id = v_bra and status in ('OPEN', 'UNLOCKED');
  assert v_n = 2,
    format('TC-16: expected an UNLOCKED past day and an OPEN new day to coexist, found %s such rows', v_n);

  ------------------------------------------------------- the carry-forward, on branch B
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);

  -- Two past days to hang rice rows off. rice_records.daily_report_id is NOT NULL, and
  -- neither day may be OPEN, or daily_reports_one_open refuses the opens below.
  --
  -- They are inserted UNLOCKED and each is closed only once its rice row is in. ^ref-42's R8
  -- guard (fn_guard_report_closed, migration ...0018) refuses a child row against a CLOSED
  -- day. UNLOCKED is not OPEN, so it still coexists with the opens below.
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by)
       values (v_brb, v_d7, now() - interval '7 days', 'UNLOCKED', v_adm_b)
    returning id into v_rep_b7;
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by)
       values (v_brb, v_d2, now() - interval '2 days', 'UNLOCKED', v_adm_b)
    returning id into v_rep_b2;

  insert into rice_records (daily_report_id, location_id, event_date, model, cooked_remaining_kg, created_by)
       values (v_rep_b7, v_brb, v_d7, 'SELF_COOK', 3.00, v_adm_b);
  update daily_reports set status = 'CLOSED', closed_by = v_adm_b, closed_at = now()
   where id = v_rep_b7;

  --------------------------------------------------------------------------------- TC-28
  -- Rice seven days back, nothing since, opening a day three days back. THE MOST RECENT
  -- ROW STRICTLY BEFORE, not yesterday's. A branch that sold no rice on Tuesday must not
  -- have Monday's remainder vanish on Wednesday — the same shape as R12's config
  -- resolution, and for the same reason.
  v_res := fn_open_daily_report(gen_random_uuid(), v_brb, v_d3);
  assert (v_res ->> 'carried_in_cooked_kg')::numeric = 3.00,
    format('TC-28: carried [%s], expected 3.00 from the row seven days back',
           v_res ->> 'carried_in_cooked_kg');
  update daily_reports set status = 'CLOSED', closed_by = v_adm_b, closed_at = now()
   where id = (v_res ->> 'daily_report_id')::uuid;

  --------------------------------------------------------------------------------- TC-29
  -- Now two candidate rows. The nearer one wins, and `order by event_date desc limit 1` is
  -- what makes that true — a `= p_report_date - 1` lookup would return nothing here.
  insert into rice_records (daily_report_id, location_id, event_date, model, cooked_remaining_kg, created_by)
       values (v_rep_b2, v_brb, v_d2, 'SELF_COOK', 7.00, v_adm_b);
  update daily_reports set status = 'CLOSED', closed_by = v_adm_b, closed_at = now()
   where id = v_rep_b2;

  v_res := fn_open_daily_report(gen_random_uuid(), v_brb, v_today);
  assert (v_res ->> 'carried_in_cooked_kg')::numeric = 7.00,
    format('TC-29: carried [%s], expected 7.00 — the nearest row before the report date',
           v_res ->> 'carried_in_cooked_kg');
  assert (v_res ->> 'rice_model') = 'SELF_COOK',
    format('TC-29: rice_model returned [%s] for branch B, expected SELF_COOK', v_res ->> 'rice_model');

  --------------------------------------------------------------------------------- TC-31
  -- fn_require_branch is a preamble, not an endpoint. Granted to nobody — a caller able to
  -- execute it directly learns which locations a uuid belongs to, one probe at a time.
  assert not has_function_privilege('authenticated', 'public.fn_require_branch(uuid)', 'EXECUTE'),
    'TC-31: authenticated can execute fn_require_branch — it is a preamble, not an endpoint';
  assert not has_function_privilege('anon', 'public.fn_require_branch(uuid)', 'EXECUTE'),
    'TC-31: anon can execute fn_require_branch';

  --------------------------------------------------------------------------------- TC-32
  assert has_function_privilege('authenticated', 'public.fn_open_daily_report(uuid, uuid, date)', 'EXECUTE'),
    'TC-32: authenticated cannot execute fn_open_daily_report — the branch cannot open its day';
  assert not has_function_privilege('anon', 'public.fn_open_daily_report(uuid, uuid, date)', 'EXECUTE'),
    'TC-32: anon can execute fn_open_daily_report';

  raise exception 'BRANCH_DAILY_TEST_PASSED';   -- the only clean way back out
end $$;
