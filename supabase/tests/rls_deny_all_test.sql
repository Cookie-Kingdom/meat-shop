-- Failure-case test: the deny-all posture holds for anon and authenticated.
--
-- ADR-004: "RLS decides, the UI mirrors." Every write goes through a SECURITY DEFINER
-- fn_*, every read through a role-specific v_*. Until those exist, RLS on with no policy
-- plus revoked grants is the whole enforcement, and nothing else is guarding the data.
--
-- Two halves, because either alone can pass while the posture is broken:
--   1. the invariant sweep — every table in public has RLS on and no grants to
--      anon/authenticated. This is what catches a NEW table added by a later card:
--      migration 0005 looped over pg_tables once, at its own migration time, so a table
--      created afterwards inherits none of it.
--   2. the behavioural check — an actual `authenticated` session is refused.
--
-- Everything runs in a transaction that aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/rls_deny_all_test.sql

do $$
declare
  v_bad   text;
  v_n     bigint;
  v_ok    boolean;
begin
  -- 1a. Every table in public has row level security enabled.
  select string_agg(c.relname, ', ' order by c.relname), count(*)
    into v_bad, v_n
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and not c.relrowsecurity;
  assert v_n = 0, format('ADR-004: RLS is off on %s table(s): %s', v_n, v_bad);

  -- 1b. Neither anon nor authenticated holds any privilege on any table in public.
  --     A grant here would let a session read rows a v_* view is supposed to shape.
  select string_agg(format('%s->%s:%s', grantee, table_name, privilege_type), ', '),
         count(*)
    into v_bad, v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and grantee in ('anon', 'authenticated');
  assert v_n = 0, format('ADR-004: %s grant(s) leaked to anon/authenticated: %s', v_n, v_bad);

  -- 2. The behavioural half. A real authenticated session gets nothing.
  set local role authenticated;

  v_ok := false;
  begin
    perform 1 from profiles limit 1;
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'ADR-004: authenticated could read profiles';

  v_ok := false;
  begin
    insert into locations (code, name_th, kind) values ('XX1', 'ทดสอบ', 'CHEF_HOUSE');
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'ADR-004: authenticated could insert into locations';

  reset role;

  raise exception 'RLS_DENY_ALL_TEST_PASSED';   -- the only clean way back out
end $$;
