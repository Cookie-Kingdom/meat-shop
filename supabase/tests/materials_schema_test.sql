-- Card ^ref-47 — the columns and rules migration ...0020 claims, asserted rather than read once.
--
-- Covers TC-01 ... TC-09 from TDD-materials.md.
--
-- Assumes lane C's ...0018 (fn_guard_report_closed) only in the sense that it must NOT refuse
-- these inserts: every report used here is OPEN, and TC-04's row has a null daily_report_id,
-- which that trigger falls through on (TDD-sales.md TC-11).
--
-- Each assert is a way the F11 writers fail silently rather than loudly:
--   * a retried count batch lands twice, and the variance doubles
--   * 12.5 tubes of chilli paste are counted, and a half tube becomes a permanent variance
--   * a SELF_COOK figure lands on an EXTERNAL_COOKED row and belongs to no process
--   * an expense is saved with nobody behind it, and cannot be reimbursed
--   * lane C's TC-11 row or ^ref-39's rice fixture stops inserting, and two lanes break at once
--
-- Errors are captured into v_err and asserted after the block, never inside the handler.
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/materials_schema_test.sql

do $$
declare
  v_owner uuid := '47474747-4747-4747-4747-474747474701';
  v_adm   uuid := '47474747-4747-4747-4747-474747474702';
  v_bra   uuid;
  v_brb   uuid;
  v_rep_a uuid;
  v_rep_b uuid;
  v_key   uuid := gen_random_uuid();
  v_err   text;
  v_txt   text;
  v_n     bigint;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_adm);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',       'L1_OWNER',        true),
    (v_adm,   'ผู้ดูแลสาขา',   'L2_BRANCH_ADMIN', true);
  insert into locations (code, name_th, kind, rice_model)
       values ('M47A', 'สาขาทดสอบวัสดุ ก', 'BRANCH', 'EXTERNAL_COOKED') returning id into v_bra;
  insert into locations (code, name_th, kind, rice_model)
       values ('M47B', 'สาขาทดสอบวัสดุ ข', 'BRANCH', 'SELF_COOK') returning id into v_brb;
  insert into user_locations (profile_id, location_id) values (v_adm, v_bra), (v_adm, v_brb);

  -- One OPEN report per branch: daily_reports_one_open allows one each, and a CLOSED report
  -- would meet lane C's guard instead of the constraint under test.
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_bra, current_date, now(), v_adm) returning id into v_rep_a;
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_brb, current_date, now(), v_adm) returning id into v_rep_b;

  -- The audit trigger (R32) fires on every insert below and reads the actor from the JWT.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm)::text, true);

  --------------------------------------------------------------------------------- TC-01
  -- R39's batch key: a key column and a seq column, both nullable, unique as a pair.
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'physical_counts'
     and ((column_name = 'idempotency_key' and data_type = 'uuid')
       or (column_name = 'seq' and data_type = 'integer'))
     and is_nullable = 'YES';
  assert v_n = 2, format('TC-01: %s of 2 nullable key columns (idempotency_key uuid, seq integer) on physical_counts', v_n);

  select count(*) into v_n
    from pg_constraint con
   where con.conrelid = 'public.physical_counts'::regclass
     and con.conname = 'physical_counts_batch_key'
     and con.contype = 'u'
     and (select array_agg(a.attname::text order by a.attname)
            from pg_attribute a
           where a.attrelid = con.conrelid and a.attnum = any (con.conkey))
         = array['idempotency_key', 'seq'];
  assert v_n = 1, 'TC-01: physical_counts_batch_key is missing or is not unique on (idempotency_key, seq) — a key alone refuses line two of a batch';

  --------------------------------------------------------------------------------- TC-02
  -- BR21: whole tubes and whole materials. Meat is kg and stays fractional.
  v_err := null;
  begin
    insert into physical_counts (daily_report_id, location_id, event_date, item_type,
                                 counted_qty, system_qty, created_by)
         values (v_rep_a, v_bra, current_date, 'CHILLI_PASTE', 10.5, 10, v_adm);
  exception when check_violation then v_err := sqlerrm;
  end;
  assert v_err like '%physical_counts_whole_units%',
    format('TC-02: 10.5 tubes of chilli paste were stored, got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    insert into physical_counts (daily_report_id, location_id, event_date, item_type,
                                 counted_qty, system_qty, created_by)
         values (v_rep_a, v_bra, current_date, 'PACKAGING', 3.5, 4, v_adm);
  exception when check_violation then v_err := sqlerrm;
  end;
  assert v_err like '%physical_counts_whole_units%',
    format('TC-02: 3.5 of a packaging item were stored, got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    insert into physical_counts (daily_report_id, location_id, event_date, item_type,
                                 counted_qty, system_qty, created_by)
         values (v_rep_a, v_bra, current_date, 'SMOKED_MEAT', 2.35, 2.40, v_adm);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err is null, format('TC-02: a 2.35 kg meat count was refused — meat is kg, not units: [%s]', v_err);

  -- Finding 11: the rule binds the COUNT. A fractional system figure is a report of what the
  -- ledger says, and refusing the count over it would hide the discrepancy the count exists for.
  v_err := null;
  begin
    insert into physical_counts (daily_report_id, location_id, event_date, item_type,
                                 counted_qty, system_qty, created_by)
         values (v_rep_a, v_bra, current_date, 'CHILLI_PASTE', 10, 9.50, v_adm);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err is null,
    format('TC-02: a whole-tube count was refused because the ledger figure was fractional: [%s]', v_err);

  --------------------------------------------------------------------------------- TC-03
  -- One column, three units. The comment is the only place that says which is which.
  select col_description('public.physical_counts'::regclass,
           (select attnum from pg_attribute
             where attrelid = 'public.physical_counts'::regclass and attname = 'counted_qty'))
    into v_txt;
  assert v_txt like '%kg%' and v_txt like '%tube%',
    format('TC-03: counted_qty''s comment does not name its units per item type: [%s]', coalesce(v_txt, 'no comment'));

  --------------------------------------------------------------------------------- TC-04
  -- Lane C's TC-11 row shape: an ad-hoc chilli count, no report, no key, as the owner. The key
  -- columns are nullable precisely so this still inserts.
  v_err := null;
  begin
    insert into physical_counts (daily_report_id, location_id, event_date, item_type,
                                 counted_qty, system_qty, created_by)
         values (null, v_bra, current_date, 'CHILLI_PASTE', 10, 10, v_owner);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err is null, format('TC-04: lane C''s TC-11 row shape no longer inserts: [%s]', v_err);

  --------------------------------------------------------------------------------- TC-05
  -- The most-recent-write key: one column, plain unique.
  select count(*) into v_n
    from pg_index i
    join pg_class ic on ic.oid = i.indexrelid
    join pg_class c  on c.oid  = i.indrelid
    join pg_attribute a on a.attrelid = c.oid and a.attnum = i.indkey[0]
   where c.relname = 'rice_records' and ic.relname = 'rice_records_idempotency_key'
     and i.indisunique and i.indnatts = 1 and a.attname = 'idempotency_key';
  assert v_n = 1, 'TC-05: rice_records_idempotency_key is missing or not a single-column unique index';

  select data_type into v_txt from information_schema.columns
   where table_schema = 'public' and table_name = 'rice_records' and column_name = 'idempotency_key';
  assert v_txt = 'uuid', format('TC-05: rice_records.idempotency_key is [%s], not uuid', coalesce(v_txt, 'missing'));

  --------------------------------------------------------------------------------- TC-06
  -- M7A / M7B. The refused shapes first, so a later accepted row cannot turn the refusal into a
  -- unique_violation on daily_report_id.
  v_err := null;
  begin
    insert into rice_records (daily_report_id, location_id, event_date, model,
                              raw_purchased_kg, created_by)
         values (v_rep_a, v_bra, current_date, 'EXTERNAL_COOKED', 5.00, v_adm);
  exception when check_violation then v_err := sqlerrm;
  end;
  assert v_err like '%rice_records_model_fields%',
    format('TC-06: an EXTERNAL_COOKED row took a raw-rice purchase, got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    insert into rice_records (daily_report_id, location_id, event_date, model,
                              cooked_received_kg, created_by)
         values (v_rep_b, v_brb, current_date, 'SELF_COOK', 5.00, v_adm);
  exception when check_violation then v_err := sqlerrm;
  end;
  assert v_err like '%rice_records_model_fields%',
    format('TC-06: a SELF_COOK row took a cooked-rice receipt, got [%s]', coalesce(v_err, 'no error at all'));

  -- branch_daily_test.sql's fixture shape: cooked_remaining_kg only, both models.
  v_err := null;
  begin
    insert into rice_records (daily_report_id, location_id, event_date, model, cooked_remaining_kg, created_by)
         values (v_rep_a, v_bra, current_date, 'EXTERNAL_COOKED', 3.00, v_adm);
    insert into rice_records (daily_report_id, location_id, event_date, model, cooked_remaining_kg, created_by)
         values (v_rep_b, v_brb, current_date, 'SELF_COOK', 3.00, v_adm);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err is null,
    format('TC-06: a cooked_remaining_kg-only row was refused — ^ref-39''s fixtures break: [%s]', v_err);

  --------------------------------------------------------------------------------- TC-07
  -- ^ref-51's acceptance, as a column rule: no expense without the person who fronted the cash.
  select is_nullable into v_txt from information_schema.columns
   where table_schema = 'public' and table_name = 'branch_expenses' and column_name = 'paid_by_person';
  assert v_txt = 'NO', 'TC-07: branch_expenses.paid_by_person is nullable';

  v_err := null;
  begin
    insert into branch_expenses (daily_report_id, category, amount_thb, paid_by_person, created_by)
         values (v_rep_a, 'ค่าน้ำแข็ง', 40.00, '   ', v_adm);
  exception when check_violation then v_err := sqlerrm;
  end;
  assert v_err like '%branch_expenses_paid_by_not_blank%',
    format('TC-07: a blank payer was stored, got [%s]', coalesce(v_err, 'no error at all'));

  insert into branch_expenses (daily_report_id, category, amount_thb, paid_by_person, created_by, idempotency_key)
       values (v_rep_a, 'ค่าน้ำแข็ง', 40.00, 'สมชาย', v_adm, v_key);
  v_err := null;
  begin
    insert into branch_expenses (daily_report_id, category, amount_thb, paid_by_person, created_by, idempotency_key)
         values (v_rep_a, 'ค่าน้ำแข็ง', 40.00, 'สมชาย', v_adm, v_key);
  exception when unique_violation then v_err := sqlerrm;
  end;
  assert v_err like '%branch_expenses_idempotency_key%',
    format('TC-07: one key stored two expense rows, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-08
  -- ADR-007 as narrowed at ^ref-19: this migration added no clock. Same query as
  -- purchasing_schema_test.sql TC-03, so the two fail together. Base tables only: a read view
  -- may pass on the ledger's clock (v_branch_diff, the ^ref-55…^ref-58 reports) without
  -- storing one.
  select coalesce(string_agg(distinct c.table_name, ', '), '(none)') into v_txt
    from information_schema.columns c
    join information_schema.tables t using (table_schema, table_name)
   where c.table_schema = 'public' and c.column_name in ('business_date', 'event_at')
     and t.table_type = 'BASE TABLE';
  assert v_txt = 'stock_ledger',
    format('TC-08: business_date/event_at are on [%s], not on stock_ledger alone', v_txt);

  --------------------------------------------------------------------------------- TC-09
  -- Deny-all intact. Writes arrive through the fn_* writers only (ADR-002, ADR-004).
  assert not has_table_privilege('authenticated', 'public.physical_counts', 'SELECT'),
    'TC-09: authenticated can SELECT physical_counts directly';
  assert not has_table_privilege('authenticated', 'public.rice_records', 'SELECT'),
    'TC-09: authenticated can SELECT rice_records directly';
  assert not has_table_privilege('authenticated', 'public.branch_expenses', 'SELECT'),
    'TC-09: authenticated can SELECT branch_expenses directly';
  assert not has_table_privilege('authenticated', 'public.physical_counts', 'INSERT'),
    'TC-09: authenticated can INSERT physical_counts directly — the writer is not the only path';

  raise exception 'MATERIALS_SCHEMA_TEST_PASSED';   -- the only clean way back out
end $$;
