-- Card ^ref-38 — the schema this card claims, asserted rather than read once.
--
-- daily_reports and thaw_records were both created in ...0004_stock_and_branch_daily.sql,
-- so ^ref-38 is the sixth stale-in-Backlog card of the same shape as ^ref-04, ^ref-10,
-- ^ref-13 and ^ref-18. Unlike those, it does not move on that evidence alone: two clauses
-- of its acceptance line were false, and this file is what found them.
--
-- Written BEFORE migration ...0009 and run red on purpose (PLAN T1 before T2). TC-02,
-- TC-03 and TC-04 failed against the baseline; ...0009 is what turns them green. TC-06 is
-- the inverse — it asserts a column that must NEVER appear, so the card's correction
-- cannot drift back in as "make the acceptance line literally true".
--
-- Covers TC-01 ... TC-09 from TDD-branch-daily-open.md.
--
-- Run:  psql "$DATABASE_URL" -f supabase/tests/branch_daily_schema_test.sql

do $$
declare
  v_n    bigint;
  v_txt  text;
begin
  --------------------------------------------------------------------------------- TC-01
  -- The two tables and the columns the ER at API_DATA_MODEL.md §3 names.
  select count(*) into v_n
    from information_schema.tables
   where table_schema = 'public'
     and table_name in ('daily_reports', 'thaw_records');
  assert v_n = 2, format('TC-01: %s of the 2 branch-daily tables exist', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'daily_reports'
     and column_name in ('location_id', 'report_date', 'shift_started_at', 'status',
                         'opened_by', 'closed_by', 'closed_at', 'remark', 'created_at');
  assert v_n = 9, format('TC-01: daily_reports is missing columns (%s of 9)', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'thaw_records'
     and column_name in ('daily_report_id', 'lot_id', 'smoke_date_group_id',
                         'thawed_weight_kg', 'fifo_override_reason', 'created_by',
                         'created_at');
  assert v_n = 7, format('TC-01: thaw_records is missing columns (%s of 7)', v_n);

  --------------------------------------------------------------------------------- TC-02
  -- Finding 1. The third clock (ADR-007). daily_reports carried report_date (the business
  -- date) and shift_started_at (the event clock) and nothing that says when the row was
  -- physically written. This is NOT the ^ref-18 case, where ADR-007's prose was over-broad
  -- and the schema was right: here API_DATA_MODEL.md §3's own ER omitted created_at too,
  -- so doc and schema agreed with each other and both disagreed with the ADR — which means
  -- neither was an observation of a decision anybody made. A row that cannot say when it
  -- was written cannot be reconciled against audit_log when a back-dated open is disputed,
  -- which is the exact thing three clocks exist for.
  select is_nullable, column_default into v_txt, v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'daily_reports'
     and column_name = 'created_at';
  assert found, 'TC-02: daily_reports.created_at does not exist (ADR-007, Finding 1)';

  select is_nullable into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'daily_reports'
     and column_name = 'created_at';
  assert v_txt = 'NO', 'TC-02: daily_reports.created_at is nullable — a clock that can be absent is not a clock';

  select column_default into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'daily_reports'
     and column_name = 'created_at';
  assert v_txt like 'now()%',
    format('TC-02: daily_reports.created_at defaults to [%s], not now() — a caller must not be able to set it', v_txt);

  --------------------------------------------------------------------------------- TC-03
  -- Finding 3. shift_started_at is the column ADR-014 rests on: with it null the business
  -- day is undecidable for that row, because there is no shift open to run the day from.
  -- fn_open_daily_report is its only writer and always sets now(), so NOT NULL is free
  -- today and a data migration later.
  select is_nullable into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'daily_reports'
     and column_name = 'shift_started_at';
  assert v_txt = 'NO', 'TC-03: daily_reports.shift_started_at is nullable — ADR-014 is undecidable for such a row (Finding 3)';

  --------------------------------------------------------------------------------- TC-04
  -- Finding 4, and this is the mechanism rather than a nicety.
  --
  -- "A 01:00 entry belongs to the previous day" (ADR-014) is NOT arithmetic. There is no
  -- shift-boundary time anywhere in the schema and business_day_shift_rule is a `text`
  -- config key with no number in it. The rule is true because a child row attaches to the
  -- branch's OPEN report and there is exactly one. A 01:00 sale finds yesterday's report
  -- still open and lands on it. That is the whole implementation, and it is correct only
  -- if "exactly one" is enforced here.
  --
  -- ...0004 created daily_reports_open as a PLAIN index on (location_id, report_date). R5
  -- stops the same date twice; nothing stopped Monday and Tuesday being open together.
  select count(*) into v_n
    from pg_index i
    join pg_class c on c.oid = i.indrelid
    join pg_class ic on ic.oid = i.indexrelid
   where c.relname = 'daily_reports' and ic.relname = 'daily_reports_one_open'
     and i.indisunique and i.indnatts = 1;
  assert v_n = 1, 'TC-04: daily_reports_one_open is missing or not a single-column unique index (Finding 4)';

  select pg_get_expr(i.indpred, i.indrelid) into v_txt
    from pg_index i
    join pg_class ic on ic.oid = i.indexrelid
   where ic.relname = 'daily_reports_one_open';

  -- The predicate is a CONTRACT, not a detail. UNLOCKED is a past day reopened under
  -- R28/ADR-013 and has to coexist with today's open day; a `status <> 'CLOSED'` predicate
  -- would make unlocking yesterday impossible the moment today is open, which is precisely
  -- the situation in which somebody wants to. ^ref-08 builds against this.
  assert v_txt like '%''OPEN''%',
    format('TC-04: daily_reports_one_open predicate is [%s] — it must be status = ''OPEN''', v_txt);
  assert v_txt not like '%<>%',
    format('TC-04: daily_reports_one_open predicate is [%s] — a <> ''CLOSED'' predicate blocks ^ref-08''s unlock (D2)', v_txt);

  --------------------------------------------------------------------------------- TC-05
  -- R5 still there. The new index is a second guard, not a replacement: R5 stops the same
  -- date twice, daily_reports_one_open stops two dates at once. Losing R5 would also lose
  -- the natural key that carries this card's idempotency (Finding 5).
  select count(*) into v_n
    from pg_index i
    join pg_class c on c.oid = i.indrelid
   where c.relname = 'daily_reports' and i.indisunique and i.indnatts = 2
     and (select array_agg(a.attname order by a.attname)
            from pg_attribute a
           where a.attrelid = c.oid and a.attnum = any (i.indkey))
         = array['location_id', 'report_date']::name[];
  assert v_n = 1, 'TC-05: R5''s unique (location_id, report_date) is gone — the idempotency key with it (Finding 5)';

  --------------------------------------------------------------------------------- TC-06
  -- Finding 2, asserted as an ABSENCE so the correction cannot drift back.
  --
  -- ^ref-38's acceptance line said "daily_reports carries the branch's rice_model". It does
  -- not, and API_DATA_MODEL.md §3's ER never gave it one. rice_model lives in two places,
  -- both correct: locations.rice_model (the branch's CURRENT model) and rice_records.model
  -- (the per-row SNAPSHOT, R29). The snapshot is what stops an Owner switching a branch
  -- from EXTERNAL_COOKED to SELF_COOK and silently recomputing every closed day's rice
  -- cost. A third copy on daily_reports would be a value able to disagree with both.
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'daily_reports' and column_name = 'rice_model';
  assert v_n = 0, 'TC-06: daily_reports.rice_model exists — a third copy that can disagree with locations and rice_records (Finding 2)';

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'rice_records' and column_name = 'model';
  assert v_n = 1, 'TC-06: rice_records.model is gone — R29''s snapshot is where the model per day actually lives';

  --------------------------------------------------------------------------------- TC-07
  -- thaw_records was already complete and must stay so. lot_id NOT NULL is R21/D01: two
  -- lots per smoke date is routine, so a thaw that cannot name its lot breaks the trace
  -- from a branch quantity back to a supplier batch. fifo_override_reason is R15's.
  select is_nullable into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'thaw_records' and column_name = 'lot_id';
  assert v_txt = 'NO', 'TC-07: thaw_records.lot_id is nullable — a thaw with no source lot (R21, D01, ADR-017)';

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'thaw_records'
     and column_name = 'fifo_override_reason';
  assert v_n = 1, 'TC-07: thaw_records.fifo_override_reason is gone — R15''s skip reason has nowhere to land';

  --------------------------------------------------------------------------------- TC-08
  -- Deny-all intact. Reads arrive through a v_* view, writes only through a SECURITY
  -- DEFINER fn_* (ADR-002, ADR-004). policies/daily_reports.sql stays deny-all on this
  -- card: the read view is ^ref-41's, and a grant added here would be the hole its RLS
  -- claim is supposed to close.
  assert not has_table_privilege('authenticated', 'public.daily_reports', 'SELECT'),
    'TC-08: authenticated can SELECT daily_reports directly — the view is not the only read path';
  assert not has_table_privilege('authenticated', 'public.thaw_records', 'SELECT'),
    'TC-08: authenticated can SELECT thaw_records directly';
  assert not has_table_privilege('anon', 'public.daily_reports', 'SELECT'),
    'TC-08: anon can SELECT daily_reports';
  assert not has_table_privilege('authenticated', 'public.daily_reports', 'INSERT'),
    'TC-08: authenticated can INSERT daily_reports directly — fn_open_daily_report is not the only writer';

  --------------------------------------------------------------------------------- TC-09
  -- R32. ^ref-06's attach loop runs over pg_tables on every deploy, so a table created by
  -- a later card is covered without anyone remembering to come back. Asserted here because
  -- "covered automatically" is exactly the kind of claim that stops being true silently.
  select count(*) into v_n
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
   where c.relname in ('daily_reports', 'thaw_records')
     and t.tgname in ('trg_audit_daily_reports', 'trg_audit_thaw_records')
     and not t.tgisinternal;
  assert v_n = 2, format('TC-09: %s of 2 audit triggers attached (R32)', v_n);

  raise exception 'BRANCH_DAILY_SCHEMA_TEST_PASSED';   -- the only clean way back out
end $$;
