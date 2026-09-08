-- Supabase linter 0011 / 0028 / 0029.

alter function public.fn_rollup_smoke_log_input()   set search_path = public, pg_temp;
alter function public.fn_require_lot_for_meat()      set search_path = public, pg_temp;
alter function public.fn_stock_ledger_append_only()  set search_path = public, pg_temp;

-- Pre-existing project helper, not part of this schema. It has no business being callable
-- from the public REST API.
revoke execute on function public.rls_auto_enable() from anon, authenticated;
