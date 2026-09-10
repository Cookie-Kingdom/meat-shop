-- Card ^ref-62, T4 — fn_backdating_allowed. R28's window, and the one place ADR-021 relaxes
-- it.
--
-- ADR-021: "while opening is unlocked, back-dated ordinary rows are accepted without an
-- unlock request." The card's acceptance line covers that in six words. What it means is
-- that while `opening_balance_close` is empty, EVERY write function in the system that would
-- have consulted R28 skips it — fn_record_sales, fn_record_waste, fn_record_thaw,
-- fn_close_daily_report, none of which are built yet (^ref-40, ^ref-43 ... ^ref-45).
--
-- WHICH IS EXACTLY WHY THE RULE IS A FUNCTION AND NOT A FLAG READ AT FIVE CALL SITES.
-- Eight unbuilt cards re-deriving `current_date - k` is eight chances for one of them to be
-- exclusive where the rest are inclusive, and the one that differs is discovered by an
-- Owner who cannot enter yesterday's sales on one screen and can on another. F9/F10/F11 get
-- one line each instead of a rule they each rewrite.
--
-- THE BOUNDARY IS INCLUSIVE OF ITS LAST DAY (R28, settled by the Owner 9 Sep 2026). On a
-- Thursday with the key at 3, Monday is inside and Sunday is outside. Inclusivity is a
-- property of the RULE, not of the number: the Owner may retune 3 to 5 or 3 to 1 and the
-- last day named stays reachable. `0` is legal and means today only. A negative value is
-- refused at the config writer, not here — this function answers a question, it does not
-- validate the Owner's arithmetic.
--
-- WHAT IT DOES NOT DO. It is the rule, not the escalation. ^ref-08's fn_request_unlock and
-- fn_decide_unlock are the path by which a date OUTSIDE the window is written anyway, and
-- they stay blocked on TICKET-004. A caller of this function that gets `false` has been told
-- the ordinary path is shut, not that the write is impossible.
--
-- WHY current_date AND NOT now()::date. The window is measured in business days against
-- Asia/Bangkok (ADR-010, ADR-014), and `current_date` is already resolved in the session
-- timezone. A cutover at 01:00 Bangkok is exactly where a UTC-evaluated boundary silently
-- gives or takes a day.
--
-- STABLE, not IMMUTABLE: it reads a table and current_date. Granted to `authenticated`
-- because it reveals nothing but a boolean about a date, and ADR-004's "the UI mirrors"
-- means a screen wants it to grey out a date picker before the RPC refuses. It is not a
-- price and it is not a balance.
--
-- Covered by supabase/tests/opening_close_test.sql (TC-31 ... TC-37).

create or replace function public.fn_backdating_allowed(p_business_date date)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_days numeric;
begin
  if p_business_date is null then
    raise exception 'BUSINESS_DATE_REQUIRED: fn_backdating_allowed answers about a date (R28)';
  end if;

  -- The relaxation, and the whole of it. No second mechanism re-arms R28 when the window
  -- shuts: fn_close_opening_balances writes one row and this read starts returning false in
  -- the same transaction (ADR-021, TDD Seam 4).
  if not exists (select 1 from opening_balance_close) then
    return true;
  end if;

  -- CONFIG_NOT_SET propagates. ADR-023/BR23: an unset Owner value is a named refusal, never
  -- an assumed 3. A defaulted window is a window nobody chose.
  v_days := fn_config_numeric('unlock_max_days_back', current_date);

  return p_business_date >= current_date - v_days::integer;
end $$;

revoke execute on function public.fn_backdating_allowed(date) from public, anon, authenticated;
grant  execute on function public.fn_backdating_allowed(date) to   authenticated;
