-- Cards ^ref-55 ... ^ref-58 — the shape of lane K's report views. TC-S01 ... TC-S08 of
-- v.0.1/ready-ref-55-58-reporting/TDD-reporting.md ("Schema").
-- Contract assumed from an unmerged lane: none.
--
-- ONE LIST, GROWN PER CARD. v_views holds every 2xx view built so far; each card appends its
-- names under its own § line and every sweep below runs over the whole list. A view added to
-- supabase/views/2xx_* and not to this list is a view no sweep checks.
--
-- Run:  psql "$DATABASE_URL" -f supabase/tests/reports_schema_test.sql

do $$
declare
  v_views text[] := array[
    -- §55 (^ref-55)
    'v_daily_sales', 'v_daily_sales_qty', 'v_monthly_summary', 'v_monthly_summary_qty'
  ];
  v_qty_views text[] := array['v_daily_sales_qty', 'v_monthly_summary_qty'];
  v_bad text;
begin
  ------------------------------------------------------------------------------ TC-S01
  select string_agg(n, ', ') into v_bad
    from unnest(v_views) n
   where not exists (select 1 from pg_views where schemaname = 'public' and viewname = n);
  assert v_bad is null, format('TC-S01: planned view(s) missing: %s', v_bad);

  ------------------------------------------------------------------------------ TC-S02
  -- Units in names: every numeric column says what it counts.
  select string_agg(table_name || '.' || column_name, ', ') into v_bad
    from information_schema.columns
   where table_schema = 'public' and table_name = any (v_views)
     and data_type = 'numeric'
     and column_name !~ '_(kg|thb|qty|tubes|pct)$';
  assert v_bad is null, format('TC-S02: numeric column(s) with no unit in the name: %s', v_bad);

  ------------------------------------------------------------------------------ TC-S03
  select string_agg(table_name || '.' || column_name, ', ') into v_bad
    from information_schema.columns
   where table_schema = 'public' and table_name = any (v_views)
     and column_name ~ '_thb$'
     and (data_type <> 'numeric' or numeric_precision is distinct from 12
          or numeric_scale is distinct from 2);
  assert v_bad is null, format('TC-S03: _thb column(s) that are not numeric(12,2): %s', v_bad);

  select string_agg(table_name || '.' || column_name, ', ') into v_bad
    from information_schema.columns
   where table_schema = 'public' and table_name = any (v_views)
     and column_name ~ '_pct$'
     and (data_type <> 'numeric' or numeric_precision is distinct from 6
          or numeric_scale is distinct from 2);
  assert v_bad is null, format('TC-S03: _pct column(s) that are not numeric(6,2): %s', v_bad);

  ------------------------------------------------------------------------------ TC-S04
  -- R34, Finding 1: the branch's views carry nothing money-shaped, so selecting one is 42703.
  select string_agg(table_name || '.' || column_name, ', ') into v_bad
    from information_schema.columns
   where table_schema = 'public' and table_name = any (v_qty_views)
     and column_name ~ '(thb|price|cost|pct|loss|yield|profit|revenue)';
  assert v_bad is null, format('TC-S04: money-shaped column(s) in a _qty view: %s', v_bad);

  ------------------------------------------------------------------------------ TC-S06
  select string_agg(n, ', ') into v_bad
    from unnest(v_views) n
   where not has_table_privilege('authenticated', 'public.' || quote_ident(n), 'SELECT');
  assert v_bad is null, format('TC-S06: authenticated cannot SELECT: %s', v_bad);

  select string_agg(table_name || ':' || grantee || ':' || privilege_type, ', ') into v_bad
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = any (v_views)
     and (grantee = 'anon' or (grantee = 'authenticated' and privilege_type <> 'SELECT'));
  assert v_bad is null, format('TC-S06: grant(s) beyond SELECT to authenticated: %s', v_bad);

  ------------------------------------------------------------------------------ TC-S07
  -- R34: an invoker view over deny-all tables returns nothing for every role, L1 included.
  select string_agg(c.relname, ', ') into v_bad
    from pg_class c
    join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relname = any (v_views)
     and coalesce(array_to_string(c.reloptions, ','), '') ~* 'security_invoker=(true|on|1)';
  assert v_bad is null, format('TC-S07: security_invoker view(s): %s', v_bad);

  ------------------------------------------------------------------------------ TC-S08
  -- Finding 8: fn_config_* is granted to nobody and a view calls functions as the caller.
  select string_agg(viewname, ', ') into v_bad
    from pg_views
   where schemaname = 'public' and viewname = any (v_views)
     and definition ~ 'fn_config_(value|numeric|boolean|date)';
  assert v_bad is null, format('TC-S08: view(s) calling a no-grant config primitive: %s', v_bad);

  raise exception 'REPORTS_SCHEMA_TEST_PASSED';
end $$;
