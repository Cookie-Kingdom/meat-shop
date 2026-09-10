-- Failure-case test: the deny-all posture holds for anon and authenticated.
--
-- ADR-004: "RLS decides, the UI mirrors." Every write goes through a SECURITY DEFINER
-- fn_*, every read through a role-specific v_*. Until those exist, RLS on with no policy
-- plus revoked grants is the whole enforcement, and nothing else is guarding the data.
--
-- THE POSTURE HALF, AND NOTHING ELSE. Every sweep below is a read-only catalogue query,
-- which is what lets `migrations_apply_test.sh --db-url` run this file against the live
-- project. The behavioural half - an actual `authenticated` session being refused - moved
-- to `rls_behaviour_test.sql` when ^ref-64 split them, because it writes fixtures and so
-- is Docker-only. Neither half proves the posture alone; they are two files, not one test.
--
-- WHY IT RUNS AGAINST LIVE (^ref-64). A posture asserted only against Docker asserts
-- nothing about the database that holds the data. `pg_default_acl` in a Supabase project
-- grants to `anon` and `authenticated` BY NAME on every relation and function `postgres`
-- creates in `public`; `revoke ... from public` removes the implicit PUBLIC privilege and
-- does NOT remove a named-role grant. So every revoke in this repo was real in Docker and
-- inert live, and 1b/1c below sat green over 22 open function grants. Docker has no
-- default ACLs and structurally cannot see it. That is why `--db-url` runs this file, and
-- why 1e exists at all.
--
-- The sweeps:
--   1a  every table in public has RLS on
--   1b  anon holds nothing on any table or view
--   1c  authenticated holds no write privilege anywhere
--   1d  a table authenticated can SELECT carries a SELECT policy
--   1e  anon holds EXECUTE on no function in public                         (^ref-64)
--   1f  the five no-grant functions are executable by neither role, by name (^ref-64)
--   1g  every other fn_* is executable by authenticated and not by anon     (^ref-64)
--
-- 1a-1d catch a NEW table added by a later card: migration 0005 looped over pg_tables once,
-- at its own migration time, so a table created afterwards inherits none of it.
--
-- Everything runs in a transaction that aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/rls_deny_all_test.sql

do $$
declare
  v_bad   text;
  v_n     bigint;
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

  -- 1e. anon holds EXECUTE on nothing in public. (^ref-64)
  --
  --     `has_function_privilege`, not `information_schema.routine_privileges`. The latter
  --     lists only privileges recorded as explicit ACL entries and reads as empty for a
  --     privilege that is held by default - which is the exact shape of the bug this card
  --     closed, so asking it would reproduce the blindness rather than test for it.
  --
  --     1b is the same question for tables and views and cannot answer this one:
  --     `role_table_grants` covers relations and nothing else, which is why 22 open
  --     function grants sat underneath a green suite.
  select string_agg(p.proname, ', ' order by p.proname), count(*)
    into v_bad, v_n
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prokind = 'f'
     and has_function_privilege('anon', p.oid, 'EXECUTE');
  assert v_n = 0, format('ADR-004: anon may execute %s function(s): %s', v_n, v_bad);

  -- 1f. The six that are granted to NOBODY, by name. (^ref-64)
  --
  --     A list, not a pattern. The point is that these six are different from the rest,
  --     and a pattern that happened to match them today would stop matching the day a
  --     seventh arrives - which is how the card's own acceptance line came to name three.
  --     ^ref-22 is the sixth arriving: fn_config_boolean, which F5 needed because
  --     partial_receipt_allowed and receipt_variance_requires_reason are boolean keys and
  --     config_settings has no boolean column for them to live in.
  --
  --     fn_config_value, fn_config_numeric and fn_config_boolean are primitives for definer
  --     functions and resolve prices (R20, R31). fn_post_ledger is the ledger write
  --     primitive (ADR-003). fn_require_owner and fn_require_branch are definer preambles.
  --     All six are called from inside a SECURITY DEFINER function and by nothing else, ever.
  select string_agg(p.proname, ', ' order by p.proname), count(*)
    into v_bad, v_n
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_config_value', 'fn_config_numeric', 'fn_config_boolean',
                       'fn_post_ledger', 'fn_require_owner', 'fn_require_branch')
     and (has_function_privilege('anon',          p.oid, 'EXECUTE')
       or has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  assert v_n = 0,
    format('ADR-002: %s no-grant function(s) executable by a session role: %s', v_n, v_bad);

  -- 1g. And the other way round: every remaining fn_* IS executable by authenticated.
  --
  --     Without this, `functions/000_revoke_defaults.sql` could revoke everything and the
  --     suite would go green on an application where no RPC works at all. A function that
  --     silently loses its grant is as much a defect as one that gains one - it is just a
  --     defect the UI reports instead of the database.
  --
  --     The excluded trigger functions fire as the table owner, so EXECUTE buys them
  --     nothing and 1e already requires they hold none.
  select string_agg(p.proname, ', ' order by p.proname), count(*)
    into v_bad, v_n
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prokind = 'f'
     and p.proname like 'fn\_%'
     and p.proname not in ('fn_config_value', 'fn_config_numeric', 'fn_config_boolean',
                           'fn_post_ledger', 'fn_require_owner', 'fn_require_branch',
                           'fn_audit_row', 'fn_audit_log_append_only',
                           'fn_rollup_smoke_log_input', 'fn_require_lot_for_meat',
                           'fn_stock_ledger_append_only')
     and not has_function_privilege('authenticated', p.oid, 'EXECUTE');
  assert v_n = 0,
    format('ADR-002: %s RPC function(s) executable by nobody: %s', v_n, v_bad);

  raise exception 'RLS_DENY_ALL_TEST_PASSED';   -- the only clean way back out
end $$;
