-- Card ^ref-21 — the schema this card claims, asserted rather than read once.
--
-- transport_runs and transport_lines were both created in ...0003_purchasing_production.sql,
-- so ^ref-21 is the fifth stale-in-Backlog card of the same shape as ^ref-04, ^ref-10,
-- ^ref-13 and ^ref-18. Its acceptance line — "a line carries dispatched and received weight
-- separately, plus variance_reason" — was already true of the baseline. Turning that reading
-- into a test is what ^ref-10's T0 and ^ref-18's T1 did, for the reason that keeps proving
-- itself: a later migration that drops a unit suffix, an FK or the branch-leg check fails
-- the suite instead of passing review.
--
-- Covers TC-01 ... TC-04, TC-21 and TC-38 from TDD-transport.md.
--
-- Run:  psql "$DATABASE_URL" -f supabase/tests/transport_schema_test.sql

do $$
declare
  v_owner uuid := '77777777-7777-7777-7777-7777777777a1';
  v_branch uuid;
  v_n     bigint;
  v_txt   text;
  v_bad   text;
  v_ok    boolean;
  v_err   text;
  v_col   numeric;
  v_fn    numeric;
  v_verd  text;
begin
  --------------------------------------------------------------------------------- TC-01
  -- Both tables, and the columns the ER names.
  select count(*) into v_n
    from information_schema.tables
   where table_schema = 'public'
     and table_name in ('transport_runs', 'transport_lines');
  assert v_n = 2, format('TC-01: %s of the 2 transport tables exist', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'transport_runs'
     and column_name in ('route', 'vehicle_type', 'is_round_trip', 'event_date',
                         'run_cost_thb', 'alloc_method', 'created_by', 'created_at');
  assert v_n = 8, format('TC-01: transport_runs is missing columns (%s of 8)', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'transport_lines'
     and column_name in ('run_id', 'lot_id', 'smoke_date_group_id', 'from_location_id',
                         'to_location_id', 'dispatched_weight_kg', 'received_weight_kg',
                         'outstanding_weight_kg', 'variance_pct', 'freight_share_thb',
                         'received_by', 'received_at', 'variance_reason',
                         'variance_settlement');
  assert v_n = 14, format('TC-01: transport_lines is missing columns (%s of 14)', v_n);

  -- D01 / R21: every meat movement names its source lot, and a line is a meat movement.
  -- Nullable here would let a freight share be allocated to nothing.
  select is_nullable into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'transport_lines' and column_name = 'lot_id';
  assert v_txt = 'NO', 'TC-01: transport_lines.lot_id is nullable — a line with no lot (D01/R21)';

  -- D06 and BR12 are generated columns, not application arithmetic. If either stops being
  -- generated, some call site is now free to write its own answer into it.
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'transport_lines'
     and column_name in ('outstanding_weight_kg', 'variance_pct')
     and is_generated = 'ALWAYS';
  assert v_n = 2, format('TC-01: %s of 2 transport_lines columns are still generated (D06, BR12)', v_n);

  select count(*) into v_n
    from pg_constraint
   where conrelid = 'public.transport_lines'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) like '%dispatched_weight_kg > (0)%';
  assert v_n = 1, 'TC-01: dispatched_weight_kg has lost its > 0 check — a zero-weight line divides variance_pct by zero';

  --------------------------------------------------------------------------------- TC-02
  -- Every quantity column names its unit (_kg, _thb, _pct). A new unitless numeric on
  -- either table fails the suite the day it is added, which is the whole point.
  select string_agg(format('%s.%s', table_name, column_name), ', ' order by column_name), count(*)
    into v_bad, v_n
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('transport_runs', 'transport_lines')
     and data_type = 'numeric'
     and column_name !~ '_(kg|thb|pct)$';
  assert v_n = 0, format('TC-02: %s numeric column(s) with no unit in the name: %s', v_n, v_bad);

  --------------------------------------------------------------------------------- TC-04
  -- Migration ...0010. Three of the four columns are the retry (R4/ADR-005) and the fourth
  -- is the clock v_outstanding_receipts ages a line by (Finding 2).
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public'
     and ((table_name = 'transport_runs'  and column_name = 'idempotency_key')
       or (table_name = 'transport_lines' and column_name in ('idempotency_key',
                                                              'receipt_idempotency_key',
                                                              'created_at')));
  assert v_n = 4, format('TC-04: %s of the 4 ...0010 columns exist', v_n);

  -- A key column with no unique index is not a key. All three, or a replay writes twice.
  select count(*) into v_n
    from pg_index i
    join pg_class c     on c.oid = i.indrelid
    join pg_attribute a on a.attrelid = c.oid and a.attnum = any (i.indkey)
   where c.relname in ('transport_runs', 'transport_lines')
     and i.indisunique and i.indnatts = 1
     and a.attname in ('idempotency_key', 'receipt_idempotency_key');
  assert v_n = 3, format('TC-04: %s of the 3 idempotency keys are uniquely indexed (R4)', v_n);

  select is_nullable into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'transport_lines' and column_name = 'created_at';
  assert v_txt = 'NO', 'TC-04: transport_lines.created_at is nullable — a line with no age (Finding 2)';

  -- The comment is load-bearing: it is the only thing standing between the next reader and
  -- transport_lines.variance_pct, which TC-21 below proves is the wrong number to reach for.
  select col_description('public.transport_lines'::regclass, ordinal_position) into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'transport_lines' and column_name = 'variance_pct';
  assert v_txt like '%fn_check_variance%',
    'TC-04: variance_pct has lost the comment warning that fn_check_variance owns the verdict (ADR-019)';

  --------------------------------------------------------------------------------- TC-03
  -- R25 has teeth in the schema, not only in fn_create_transport_run. The function raises
  -- BRANCH_LEG_NOT_FREE for legibility; this constraint is what stops a fare arriving by any
  -- other route.
  insert into auth.users (id) values (v_owner);
  insert into profiles (id, display_name, role, is_active)
    values (v_owner, 'เจ้าของ', 'L1_OWNER', true);
  insert into locations (code, name_th, kind) values ('BRZ', 'สาขาซี', 'BRANCH')
    returning id into v_branch;

  v_ok := false; v_err := null;
  begin
    insert into transport_runs (route, event_date, run_cost_thb, alloc_method, created_by)
    values ('CENTRAL_TO_BRANCH', date '2026-03-01', 1.00, 'BY_LOT_WEIGHT', v_owner);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%transport_runs_branch_leg_free%';
  end;
  assert v_ok, format('TC-03: a CENTRAL_TO_BRANCH run took a 1 THB fare (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-21
  -- THE TWO VARIANCE ANSWERS DISAGREE, ON PURPOSE (Seam 4, ADR-019).
  --
  -- 799.96 kg received against 1000.00 kg dispatched is 20.004% off. The generated column
  -- keeps four decimals and never rounds before comparing, so it reads 20.0040 — over a 20%
  -- tolerance. fn_check_variance rounds to 2 first and then compares, so it reads 20.00 and
  -- says WITHIN. One line, two verdicts, differing in the third decimal.
  --
  -- This assert is not a complaint about the column. It is the record that the disagreement
  -- is known and deliberate, so that the day somebody simplifies v_transport_variance onto
  -- the column "because it is already there", this test says what changed.
  v_col := abs(799.96 - 1000.00) / 1000.00 * 100;
  select variance_pct, verdict into v_fn, v_verd
    from fn_check_variance(799.96, 1000.00, 'ALERT', 20.00);

  assert v_col > 20.00,
    format('TC-21: the raw column arithmetic no longer reads over threshold (%s)', v_col);
  assert v_fn = 20.00 and v_verd = 'WITHIN',
    format('TC-21: fn_check_variance no longer rounds before comparing (%s, %s)', v_fn, v_verd);
  assert v_col <> v_fn,
    'TC-21: the column and the function now agree — Seam 4 has silently changed, check ADR-019';

  --------------------------------------------------------------------------------- TC-38
  -- ^ref-64: one SELECT to authenticated, nothing to anon, on each of the three views. A
  -- grant that is real against Docker and inert live is the defect that card exists to
  -- close; a view that quietly gains a second grantee is the same defect arriving forwards.
  select string_agg(format('%s:%s:%s', table_name, grantee, privilege_type), ', '), count(*)
    into v_bad, v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name in ('v_freight_allocation', 'v_transport_variance', 'v_outstanding_receipts')
     and grantee in ('anon', 'authenticated')
     and not (grantee = 'authenticated' and privilege_type = 'SELECT');
  assert v_n = 0, format('TC-38: %s unexpected grant(s) on the transport views: %s', v_n, v_bad);

  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name in ('v_freight_allocation', 'v_transport_variance', 'v_outstanding_receipts')
     and grantee = 'authenticated' and privilege_type = 'SELECT';
  assert v_n = 3, format('TC-38: %s of 3 transport views are selectable by authenticated', v_n);

  raise exception 'TRANSPORT_SCHEMA_TEST_PASSED';   -- the only clean way back out
end $$;
