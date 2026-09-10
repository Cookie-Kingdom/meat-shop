-- Failure-case tests for card ^ref-62 — fn_close_opening_balances and fn_backdating_allowed.
--
-- Covers TC-25 ... TC-37 and TC-40 from TDD-opening-balance.md.
--
-- WHY THIS IS ITS OWN FILE, AND WHY EVERY CASE SITS IN A SUB-BLOCK.
-- The house pattern is one transaction per file, aborted on purpose. That is enough
-- everywhere else. It is not enough here: the close is permanent WITHIN a transaction too,
-- so the second case in this file would run against a database the first one already shut.
-- Each case below therefore does its work inside a plpgsql sub-block and leaves it by
-- raising ROLLBACK_TO_OPEN — plpgsql wraps a BEGIN ... EXCEPTION block in an implicit
-- savepoint, so that unwinds the close and the fixtures it needed and hands the next case an
-- open window. Anything that is NOT the sentinel is re-raised, so an assert inside a case
-- still fails the file.
--
-- Each assert is a way the one-way switch stops being one-way, or stops being a switch:
--   * the close succeeds over a costless row, and that row can never be costed and never be
--     re-entered — the ledger refuses UPDATE and the trigger refuses a replacement (Seam 1)
--   * a retry from a dropped connection reads as a second close, on the one operation in the
--     system the Owner cannot undo (R4 against TC-29)
--   * an OPENING row is accepted after the close through fn_post_ledger, which is every
--     write function nobody has written yet (Seam 2)
--   * R28 re-arms by a second mechanism that can disagree with the first (Seam 4)
--   * the back-dating boundary is exclusive on one screen and inclusive on another (R28)
--   * unlock_max_days_back is unset and 3 is assumed (ADR-023, BR23)
--
-- Run:  psql "$DATABASE_URL" -f supabase/tests/opening_close_test.sql

do $$
declare
  v_owner   uuid := '55555555-5555-5555-5555-5555555555e1';
  v_l2      uuid := '55555555-5555-5555-5555-5555555555e2';
  v_central uuid;
  v_brA     uuid;
  v_pack    uuid;
  v_a       uuid;
  v_b       uuid;
  v_c       uuid;
  v_when    timestamptz;
  v_again   timestamptz;
  v_key     uuid;
  v_txt     text;
  v_ok      boolean;
  v_err     text;
  v_n       bigint;
  v_k       integer := 3;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',    'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา', 'L2_BRANCH_ADMIN', true);

  insert into locations (code, name_th, kind) values ('CE5', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  insert into locations (code, name_th, kind) values ('B5A', 'สาขามีนบุรี', 'BRANCH')
    returning id into v_brA;
  insert into user_locations (profile_id, location_id) values (v_l2, v_brA);
  insert into packaging_items (code, name_th, unit) values ('BOX5', 'กล่อง', 'ใบ')
    returning id into v_pack;

  -- ^ref-61: migration …0024 seeds unlock_max_days_back = 3 at 2000-01-01 (v0.2 BR 15).
  -- TC-37 at the foot of this block asserts the key is UNSET and back-dating refuses with
  -- CONFIG_NOT_SET rather than assuming 3, so the seed is taken out of this block's
  -- transaction to restore that precondition. The assert is unchanged, and the seed does not
  -- weaken it: a live project that deletes nothing still reads 3 because v0.2 says 3.
  delete from config_settings where is_seed;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'opening_cutoff_date', date '2026-01-01',
                        p_value_text => '2026-10-01');

  -- Three opening rows at CENTRAL, each on its own lot so the refusal has a lot code to name.
  v_a := fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', v_central, 40.00,
                                   date '2026-09-30', p_smoke_date => date '2026-08-01',
                                   p_lot_code => 'OPEN-CEN-A');
  v_b := fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', v_central, 30.00,
                                   date '2026-09-30', p_smoke_date => date '2026-08-02',
                                   p_lot_code => 'OPEN-CEN-B');
  v_c := fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', v_central, 20.00,
                                   date '2026-09-30', p_smoke_date => date '2026-08-03',
                                   p_lot_code => 'OPEN-CEN-C');

  --------------------------------------------------------------------------------- TC-25
  -- THE CLOSE IS THE COMPLETENESS CHECK (Seam 1). Two of three costed, and the close must
  -- refuse — not warn, not close-and-flag. There is no separate "are all costs entered?"
  -- screen that could drift from this answer, because this computes it.
  perform fn_set_opening_cost(v_a, 200.00);
  perform fn_set_opening_cost(v_b, 210.00);

  v_ok := false; v_err := null;
  begin
    perform fn_close_opening_balances(gen_random_uuid());
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%OPENING_COST_MISSING%';
  end;
  assert v_ok, format('TC-25: the window closed over a costless row (%s)',
                      coalesce(v_err, 'no exception at all'));
  assert v_err like '%1 opening row%',
    format('TC-25: the refusal does not say how many rows are missing a cost (%s)', v_err);
  assert v_err like '%OPEN-CEN-C%',
    format('TC-25: the refusal does not name the offending lot, so nobody can go and find '
           'it (%s)', v_err);

  select count(*) into v_n from opening_balance_close;
  assert v_n = 0, 'TC-25: the close row was written despite the refusal';

  --------------------------------------------------------------------------------- TC-26
  perform fn_set_opening_cost(v_c, 190.00);
  v_key  := gen_random_uuid();
  v_when := fn_close_opening_balances(v_key);
  assert v_when is not null, 'TC-26: the close returned no timestamp';

  select closed_by, closed_at into v_txt, v_when from opening_balance_close;
  assert v_txt = v_owner::text,
    format('TC-26: the close is signed %s, not by the session that made it', v_txt);
  assert v_when is not null, 'TC-26: closed_at is null';

  --------------------------------------------------------------------------------- TC-29
  -- R4 AND TC-29 PULL IN OPPOSITE DIRECTIONS AND THE KEY IS WHAT SEPARATES THEM. A dropped
  -- connection and a deliberate second close are the same statement arriving twice. Catching
  -- unique_violation and re-raising it unconditionally — which the plan drafted — turns
  -- every retry into a permanent-looking refusal on the one operation the Owner cannot undo.
  v_again := fn_close_opening_balances(v_key);
  assert v_again = v_when,
    format('TC-29: a retry with the same key returned %s, not the committed %s', v_again, v_when);

  v_ok := false; v_err := null;
  begin
    perform fn_close_opening_balances(gen_random_uuid());
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%OPENING_ALREADY_CLOSED%';
  end;
  assert v_ok, format('TC-29: a second close was accepted (%s)', coalesce(v_err, 'none'));
  assert v_err not like '%duplicate key%',
    format('TC-29: the refusal is a bare constraint violation, not a named rule (%s)', v_err);

  --------------------------------------------------------------------------------- TC-27
  -- One-way, via the function, FOR L1 TOO. ADR-021 says "by anyone, ever", and the Owner is
  -- the one person who would expect an exception to that.
  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'PACKAGING', v_central, 5.00,
                                      date '2026-09-30', p_packaging_item_id => v_pack);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%OPENING_CLOSED%';
  end;
  assert v_ok, format('TC-27: the Owner recorded an opening balance after the close (%s)',
                      coalesce(v_err, 'none'));

  --------------------------------------------------------------------------------- TC-28
  -- AND VIA THE TRIGGER, INDEPENDENTLY OF THE FUNCTION (Seam 2). This is the assert that
  -- makes the promise an invariant rather than a code path: "ever" includes the write
  -- function somebody adds in 2027 that calls fn_post_ledger directly and never heard of
  -- this card. If only the function is tested, the invariant is untested.
  v_ok := false; v_err := null;
  begin
    perform fn_post_ledger(gen_random_uuid(), 'PACKAGING', v_central, 'READY', 'OPENING',
                           5.00, date '2026-09-30', p_packaging_item_id => v_pack);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%OPENING_CLOSED%';
  end;
  assert v_ok, format('TC-28: fn_post_ledger wrote an OPENING row after the close (%s)',
                      coalesce(v_err, 'none'));

  -- And the trigger did not shut the ledger to everything else while it was at it.
  perform fn_post_ledger(gen_random_uuid(), 'PACKAGING', v_central, 'READY', 'INTAKE',
                         5.00, date '2026-09-30', p_packaging_item_id => v_pack);

  --------------------------------------------------------------------------------- TC-40
  -- A miscount is corrected by a reversal plus a replacement (R2). After the close the two
  -- halves come apart, and the TDD's phrasing — "the reversal posts, the replacement raises"
  -- — is not quite what happens and is worth saying exactly:
  --
  --   * A PLAIN CANCELLATION still works. fn_reverse_ledger_entry with a null replacement
  --     posts one REVERSAL row, which is not an OPENING row, so the trigger has no opinion.
  --     An opening line entered twice can still be taken back off.
  --   * A REVERSAL WITH A REPLACEMENT is refused AS A WHOLE, atomically. The replacement for
  --     an OPENING row is an OPENING row; the trigger refuses it, and the reversal rolls back
  --     with it. There is no state where the meat has been reversed and not replaced.
  --
  -- THIS IS DELIBERATE AND IT IS THE PRICE OF A ONE-WAY SWITCH. It is worth an Owner sentence
  -- on ^ref-61's screen: once you close, a counting error is corrected as an ADJUSTMENT with
  -- a reason, not as a re-count.
  v_ok := false; v_err := null;
  begin
    perform fn_reverse_ledger_entry(gen_random_uuid(), v_a, 35.00, 'นับผิด');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%OPENING_CLOSED%';
  end;
  assert v_ok, format('TC-40: an OPENING row was replaced after the close (%s)',
                      coalesce(v_err, 'none'));

  select count(*) into v_n from stock_ledger where reversal_of = v_a;
  assert v_n = 0,
    format('TC-40: %s reversal row(s) survived a correction whose replacement was refused — '
           'the two halves are not atomic', v_n);

  -- The cancellation half, which does still work and is the only correction left after the
  -- close.
  perform fn_reverse_ledger_entry(gen_random_uuid(), v_b, null, 'ยกเลิกยอดยกมา');
  select count(*) into v_n from stock_ledger where reversal_of = v_b;
  assert v_n = 1,
    format('TC-40: a plain cancellation of an opening row posted %s reversal row(s), not one '
           '— the close must not shut the correction path as well', v_n);

  --------------------------------------------------------------------------------- TC-32
  -- R28 RE-ARMED, AND NO SECOND STATEMENT DID IT (Seam 4). fn_close_opening_balances writes
  -- one row; fn_backdating_allowed reads that row. One switch, one audit line. A "re-arm"
  -- step here would be a second mechanism, and the day the two disagree nobody can say which
  -- one the system is obeying.
  --
  -- No unlock_max_days_back is configured, so this is also TC-37: the refusal is
  -- CONFIG_NOT_SET, not an assumed 3.
  v_ok := false; v_err := null;
  begin
    perform fn_backdating_allowed(current_date - 30);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%CONFIG_NOT_SET%';
  end;
  assert v_ok,
    format('TC-37: back-dating was decided with no unlock_max_days_back set — a defaulted '
           'window is a window nobody chose (%s)', coalesce(v_err, 'none'));

  -- Unwind everything above and hand the remaining cases an open window.
  raise exception 'ROLLBACK_TO_OPEN';
exception when others then
  if sqlerrm not like '%ROLLBACK_TO_OPEN%' then raise; end if;
end $$;

-- The window is open again from here: the sub-block above unwound to its implicit savepoint,
-- and so did every fixture it created. Each block below rebuilds only what it needs.

do $$
declare
  v_owner   uuid := '55555555-5555-5555-5555-5555555555e1';
  v_l2      uuid := '55555555-5555-5555-5555-5555555555e2';
  v_central uuid;
  v_brA     uuid;
  v_pack    uuid;
  v_ok      boolean;
  v_err     text;
  v_n       bigint;
  v_k       integer;
begin
  insert into auth.users (id) values (v_owner), (v_l2);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',    'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา', 'L2_BRANCH_ADMIN', true);
  insert into locations (code, name_th, kind) values ('CE5', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  insert into locations (code, name_th, kind) values ('B5A', 'สาขามีนบุรี', 'BRANCH')
    returning id into v_brA;
  insert into user_locations (profile_id, location_id) values (v_l2, v_brA);
  insert into packaging_items (code, name_th, unit) values ('BOX5', 'กล่อง', 'ใบ')
    returning id into v_pack;

  --------------------------------------------------------------------------------- TC-30
  -- The close is L1 only, and a refused close leaves the window OPEN. A guard that refuses
  -- and half-closes is worse than no guard: the Owner is told it failed and the counters
  -- find the path shut.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_close_opening_balances(gen_random_uuid());
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-30: an L2 closed the opening window (%s)', coalesce(v_err, 'none'));
  select count(*) into v_n from opening_balance_close;
  assert v_n = 0, 'TC-30: a refused close still wrote its row';

  --------------------------------------------------------------------------------- TC-31
  -- BACK-DATING IS FREE WHILE THE WINDOW IS OPEN (ADR-021), and it is free WITHOUT READING
  -- CONFIG. Nothing is configured in this block, so a `true` here also proves the early
  -- return happens before fn_config_numeric is reached — which is what makes the relaxation
  -- usable on a project whose Owner has not set unlock_max_days_back yet.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  assert fn_backdating_allowed(current_date - 30),
    'TC-31: a 30-day-old date was refused while the opening window was open';
  assert fn_backdating_allowed(current_date - 3650),
    'TC-31: a ten-year-old date was refused while the window was open — the relaxation has '
    'no horizon of its own, the cut-off is what bounds it';

  raise exception 'ROLLBACK_TO_OPEN';
exception when others then
  if sqlerrm not like '%ROLLBACK_TO_OPEN%' then raise; end if;
end $$;

-- TC-32 ... TC-36: the boundary, once the window is shut.
--
-- One block per value of k, each closing the window and unwinding it, because the close
-- cannot be undone any other way. `k` is retuned between them on purpose: TC-36's whole
-- point is that INCLUSIVITY IS A PROPERTY OF THE RULE AND NOT OF THE NUMBER, so the same two
-- boundary asserts have to hold at 3, at 0 and at 5.
do $$
declare
  v_owner uuid := '55555555-5555-5555-5555-5555555555e1';
  v_cen   uuid;
  v_k     integer;
  v_ks    integer[] := array[3, 0, 5];
  i       integer;
begin
  insert into auth.users (id) values (v_owner);
  insert into profiles (id, display_name, role, is_active)
    values (v_owner, 'เจ้าของ', 'L1_OWNER', true);
  insert into locations (code, name_th, kind) values ('CE5', 'คลังกลาง', 'CENTRAL')
    returning id into v_cen;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  foreach v_k in array v_ks loop
    begin
      perform fn_set_config(gen_random_uuid(), 'unlock_max_days_back', date '2026-01-01',
                            p_value_numeric => v_k);
      -- Nothing to cost: the completeness check passes vacuously when no OPENING row exists,
      -- which is also the shape a project that skips opening balances entirely will take.
      perform fn_close_opening_balances(gen_random_uuid());

      ----------------------------------------------------------------------------- TC-32
      -- The same date TC-31 allowed, now refused. Nothing re-armed R28 — the table has a row.
      if v_k < 30 then
        assert not fn_backdating_allowed(current_date - 30),
          format('TC-32: a 30-day-old date is still allowed after the close at k=%s', v_k);
      end if;

      --------------------------------------------------------------------- TC-33 / TC-36
      -- INCLUSIVE OF ITS LAST DAY (R28, Owner 9 Sep 2026). On a Thursday with k=3, Monday is
      -- inside. The Owner may retune 3 -> 5 or 3 -> 1 and the last day named stays reachable.
      assert fn_backdating_allowed(current_date - v_k),
        format('TC-33: current_date - %s was refused; the boundary went exclusive at k=%s',
               v_k, v_k);

      --------------------------------------------------------------------- TC-34 / TC-36
      assert not fn_backdating_allowed(current_date - v_k - 1),
        format('TC-34: current_date - %s - 1 was allowed; the window is one day too wide at '
               'k=%s', v_k, v_k);

      ----------------------------------------------------------------------------- TC-35
      -- k = 0 is legal and means today only. A guard that treats 0 as "not configured" is
      -- the R9 mistake one table along, and it would silently widen the window to whatever
      -- the fallback is.
      assert fn_backdating_allowed(current_date),
        format('TC-35: today itself was refused at k=%s', v_k);
      if v_k = 0 then
        assert not fn_backdating_allowed(current_date - 1),
          'TC-35: k = 0 allowed yesterday; 0 means today only, not "unset"';
      end if;

      raise exception 'ROLLBACK_TO_OPEN';
    exception when others then
      if sqlerrm not like '%ROLLBACK_TO_OPEN%' then raise; end if;
    end;
  end loop;

  raise exception 'OPENING_CLOSE_TEST_PASSED';   -- the only clean way back out
end $$;
