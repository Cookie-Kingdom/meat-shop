-- fn_check_variance() — one variance rule, called everywhere (ADR-019, R22).
--
--   variance_pct = round(abs(actual - expected) / expected * 100, 2)
--
-- Every place the system compares a counted figure against an expected one — branch Diff
-- (R23), central intake (R27), transport receipt (BR12), physical counts (R19) — calls
-- this. Re-deriving the arithmetic per call site is how the tolerance ends up meaning
-- three different things in three screens.
--
-- Three things this function refuses to do:
--
--   1. Divide by a zero expectation. It returns variance_pct NULL and REASON_REQUIRED, so
--      an unconfigured or unset expectation reads as "somebody has to explain this" and
--      never as "0% off, all fine" (R22, UAT-10 has the same shape for full_stock_qty).
--
--   2. Guess whether it is alerting or blocking. p_mode has NO default, so there is no
--      two-argument form for a call site to inherit one from — the omission is a
--      compile-time miss, not a silent ALERT. ADR-019 asks for exactly this.
--
--   3. Round after comparing. The rounding is applied first, so 20.004 is 20.00 and inside
--      the band. Comparing raw and reporting rounded means the number on screen and the
--      verdict beside it disagree at the third decimal.
--
-- The threshold is a parameter, not a literal buried in the body (ADR-006, ADR-018). It
-- defaults to R22's 20.00 today; when ^ref-11 lands fn_config_value the default becomes a
-- dated config lookup and no call site changes.
--
-- OUT parameters rather than a composite type: a new type would need a migration, and this
-- slice needs none. Changing an OUT list is not a `create or replace`, hence the drop.

drop function if exists public.fn_check_variance(numeric, numeric, text, numeric);

create function public.fn_check_variance(
  p_actual        numeric,
  p_expected      numeric,
  p_mode          text,
  p_threshold_pct numeric default 20.00,
  out variance_pct numeric,
  out verdict      text
)
  language plpgsql
  immutable
  set search_path = public, pg_temp
as $$
begin
  if p_mode is null or p_mode not in ('ALERT', 'BLOCK') then
    raise exception 'UNKNOWN_MODE: %, expected ALERT or BLOCK (ADR-019)', coalesce(p_mode, 'null');
  end if;

  if p_expected is null or p_expected = 0 then
    variance_pct := null;
    verdict      := 'REASON_REQUIRED';
    return;
  end if;

  variance_pct := round(abs(p_actual - p_expected) / abs(p_expected) * 100, 2);
  verdict      := case when variance_pct <= p_threshold_pct then 'WITHIN' else 'OVER_THRESHOLD' end;

  if verdict = 'OVER_THRESHOLD' and p_mode = 'BLOCK' then
    raise exception 'VARIANCE_OVER_THRESHOLD: %%% against a tolerance of %%% (R22)',
      variance_pct, p_threshold_pct;
  end if;
end $$;

revoke execute on function public.fn_check_variance(numeric, numeric, text, numeric) from public, anon, authenticated;
grant  execute on function public.fn_check_variance(numeric, numeric, text, numeric) to authenticated;
