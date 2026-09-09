-- Failure-case tests for card ^ref-17 — fn_check_variance, the one variance rule.
--
-- Covers TC-14 … TC-18 from TDD-ledger-core.md.
--
-- Each assert is a way the rule fails silently rather than loudly:
--   * a division by zero expectation, or worse, a zero expectation quietly reading as
--     "0% off" so an unconfigured figure looks perfect (R22, ADR-019)
--   * the boundary drifts: 20.00 must be acceptable and 20.01 must not
--   * a third decimal pushes 20.004 over a line it is not over
--   * alert-vs-block acquires a default, and a call site inherits the wrong one without
--     anyone writing it down (ADR-019)
--   * BLOCK mode returns a verdict instead of aborting, and the caller ignores it
--
-- Everything runs in a transaction that aborts on purpose. No fixtures are needed — the
-- function is pure arithmetic.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/variance_test.sql

do $$
declare
  v_pct numeric;
  v_v   text;
  v_ok  boolean;
  v_err text;
begin
  --------------------------------------------------------------------------------- TC-14
  -- Ordinary: 75 against an expected 100 is 25% off, over the 20% band.
  select variance_pct, verdict into v_pct, v_v from fn_check_variance(75, 100, 'ALERT');
  assert v_pct = 25.00, format('TC-14: variance_pct is %s, expected 25.00', v_pct);
  assert v_v = 'OVER_THRESHOLD', format('TC-14: verdict is %s, expected OVER_THRESHOLD', v_v);

  -- ALERT does not abort: the flow continues and the caller demands a reason.
  select variance_pct, verdict into v_pct, v_v from fn_check_variance(105, 100, 'ALERT');
  assert v_v = 'WITHIN', format('TC-14: 5%% off read as %s', v_v);

  -- The rule is symmetric — over and under are both variance (abs).
  select variance_pct into v_pct from fn_check_variance(125, 100, 'ALERT');
  assert v_pct = 25.00, format('TC-14: an overshoot read as %s, expected 25.00', v_pct);

  --------------------------------------------------------------------------------- TC-15
  -- The boundary. R22 is "<= 20.00": 20.00 is acceptable, 20.01 is not.
  select variance_pct, verdict into v_pct, v_v from fn_check_variance(120, 100, 'ALERT');
  assert v_pct = 20.00 and v_v = 'WITHIN',
    format('TC-15: 20.00%% read as %s / %s, expected 20.00 / WITHIN', v_pct, v_v);

  select variance_pct, verdict into v_pct, v_v from fn_check_variance(120.01, 100, 'ALERT');
  assert v_pct = 20.01 and v_v = 'OVER_THRESHOLD',
    format('TC-15: 20.01%% read as %s / %s, expected 20.01 / OVER_THRESHOLD', v_pct, v_v);

  -- Rounding happens before the comparison (ADR-008). A third decimal must not push a
  -- figure over a line it is not over.
  select variance_pct, verdict into v_pct, v_v from fn_check_variance(120.004, 100, 'ALERT');
  assert v_pct = 20.00 and v_v = 'WITHIN',
    format('TC-15: 20.004%% read as %s / %s, expected 20.00 / WITHIN', v_pct, v_v);

  --------------------------------------------------------------------------------- TC-16
  -- Zero expected. The function does not divide, and it does not pretend the answer is 0.
  select variance_pct, verdict into v_pct, v_v from fn_check_variance(5, 0, 'ALERT');
  assert v_pct is null, format('TC-16: variance_pct is %s against a zero expectation', v_pct);
  assert v_v = 'REASON_REQUIRED', format('TC-16: verdict is %s, expected REASON_REQUIRED', v_v);

  -- And a zero expectation does not become harmless just because BLOCK was asked for.
  select verdict into v_v from fn_check_variance(0, 0, 'ALERT');
  assert v_v = 'REASON_REQUIRED', format('TC-16: 0 against 0 read as %s', v_v);

  --------------------------------------------------------------------------------- TC-17
  -- BLOCK aborts. Returning a verdict that the caller may ignore is not blocking.
  v_ok := false;
  begin
    perform fn_check_variance(200, 100, 'BLOCK');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%VARIANCE_OVER_THRESHOLD%';
  end;
  assert v_ok, format('TC-17: BLOCK mode did not abort (%s)',
                      coalesce(v_err, 'no exception at all'));

  -- BLOCK inside the band is silent, or the mode is just "always fail".
  select verdict into v_v from fn_check_variance(110, 100, 'BLOCK');
  assert v_v = 'WITHIN', format('TC-17: BLOCK aborted inside the band (%s)', v_v);

  --------------------------------------------------------------------------------- TC-18
  -- No mode, no function. ADR-019: every call site states alert-or-block out loud, so
  -- there is no two-argument form to inherit a default from.
  v_ok := false;
  v_err := null;
  begin
    execute 'select variance_pct from fn_check_variance(5, 10)';
  exception when undefined_function then
    v_ok := true;
  when others then
    v_err := sqlerrm;
  end;
  assert v_ok, format('TC-18: a two-argument call resolved (%s)',
                      coalesce(v_err, 'no exception at all'));

  -- An unrecognised mode is a typo, not a silent ALERT.
  v_ok := false;
  v_err := null;
  begin
    perform fn_check_variance(200, 100, 'WARN');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%UNKNOWN_MODE%';
  end;
  assert v_ok, format('TC-18: mode "WARN" was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  raise exception 'VARIANCE_TEST_PASSED';   -- the only clean way back out
end $$;
