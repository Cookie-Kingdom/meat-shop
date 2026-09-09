-- Failure-case test: the deny-all posture holds for anon and authenticated.
--
-- ADR-004: "RLS decides, the UI mirrors." Every write goes through a SECURITY DEFINER
-- fn_*, every read through a role-specific v_*. Until those exist, RLS on with no policy
-- plus revoked grants is the whole enforcement, and nothing else is guarding the data.
--
-- Two halves, because either alone can pass while the posture is broken:
--   1. the invariant sweep — every table in public has RLS on, anon holds nothing,
--      authenticated holds no write anywhere, and any table authenticated can SELECT
--      carries a SELECT policy. This is what catches a NEW table added by a later card:
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

  -- 1b. anon holds nothing at all, anywhere in public — tables and views alike.
  select string_agg(format('%s:%s', table_name, privilege_type), ', '), count(*)
    into v_bad, v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and grantee = 'anon';
  assert v_n = 0, format('ADR-004: %s grant(s) leaked to anon: %s', v_n, v_bad);

  -- 1c. `authenticated` never holds a write privilege on anything. Card ^ref-05 clause 3,
  --     and the whole of ADR-002: writes arrive through SECURITY DEFINER fn_* or not at all.
  select string_agg(format('%s:%s', table_name, privilege_type), ', '), count(*)
    into v_bad, v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and grantee = 'authenticated'
     and privilege_type <> 'SELECT';
  assert v_n = 0, format('ADR-002: %s write grant(s) to authenticated: %s', v_n, v_bad);

  -- 1d. A SELECT grant to `authenticated` on a base table is allowed only where that table
  --     carries a SELECT policy to shape it.
  --
  --     This replaces a blanket "no grants to anon or authenticated anywhere" assert, which
  --     was right while nothing was readable and wrong from ^ref-05 onward: it covered views
  --     too, so it would have failed on the first v_* the architecture calls for. The
  --     invariant it was reaching for is this one — a grant without a policy is an open
  --     table, and a policy without a grant is dead code.
  select string_agg(c.relname, ', ' order by c.relname), count(*)
    into v_bad, v_n
    from information_schema.role_table_grants g
    join pg_class c     on c.relname = g.table_name
    join pg_namespace n on n.oid = c.relnamespace and n.nspname = g.table_schema
   where g.table_schema = 'public'
     and g.grantee = 'authenticated'
     and g.privilege_type = 'SELECT'
     and c.relkind = 'r'
     and not exists (
       select 1 from pg_policy p
        where p.polrelid = c.oid
          and p.polcmd in ('r', '*')          -- SELECT, or ALL
     );
  assert v_n = 0, format('ADR-004: %s table(s) readable by authenticated with no SELECT policy: %s',
                         v_n, v_bad);

  -- 2. The behavioural half. A real authenticated session gets nothing.
  set local role authenticated;

  -- `locations`, not `profiles`: ^ref-05 grants SELECT on profiles behind a self-or-Owner
  -- policy, so a claimless session there gets zero rows rather than an error. Every other
  -- table is still refused outright, and that is what this half is checking.
  v_ok := false;
  begin
    perform 1 from locations limit 1;
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'ADR-004: authenticated could read locations';

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
