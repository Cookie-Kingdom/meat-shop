-- Card ^fix-numeric-scale — the one guard every write RPC calls on a money, weight or
-- quantity input.
--
-- Every such column is numeric(12,2), and PostgreSQL rounds a third decimal into it with no
-- error: 1.005 kg is stored as 1.01. This raises instead. It compares VALUES, not scale, so a
-- form's 1.500 is 1.50 and passes. null passes too, and each caller keeps its own null rule.
--
-- p_name is echoed in the message, so a screen or a test can tell which of several inputs was
-- refused ('p_raw_purchased_kg', 'count 2 counted_qty').
--
-- Callers run it straight after IDEMPOTENCY_KEY_REQUIRED and before the role preamble. It reads
-- no table, so it tells an unentitled caller nothing (PLAN-numeric-scale.md D1).
--
-- fn_record_thaw, fn_record_waste, fn_record_sales and fn_record_lot_bags already refuse a
-- third decimal under their own names, and they do not call this. Neither does fn_set_config:
-- value_numeric is numeric(18,4), so it stores a third decimal exactly.
--
-- EXECUTE is granted to nobody, because this is a primitive and not an endpoint (^ref-64).
-- rls_deny_all_test's sweep 1f names it and 1g excludes it.
--
-- Covered by supabase/tests/numeric_scale_test.sql (NS-01 ... NS-04, NS-10).

create or replace function public.fn_require_two_decimals(p_name text, p_value numeric)
  returns void
  language plpgsql
  immutable
  set search_path = public, pg_temp
as $$
begin
  if p_value <> round(p_value, 2) then
    raise exception 'TOO_MANY_DECIMALS: % is % — money and weight are stored to two decimals, and a third would be rounded away',
      p_name, p_value;
  end if;
end $$;

revoke execute on function public.fn_require_two_decimals(text, numeric) from public, anon, authenticated;
