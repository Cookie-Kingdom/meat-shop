-- Card ^ref-40 — the schema migration ...0019 claims, asserted rather than read once
-- (PLAN-thaw.md T1, TDD-thaw.md TC-01 ... TC-04).
--
-- Written before ...0019 and red against the baseline on TC-01, TC-02 and TC-03: ...0004 gave
-- thaw_records no idempotency column, a nullable smoke_date_group_id and no check on the
-- override reason. TC-04 is the inverse — green from the start and kept, because it asserts an
-- ABSENCE (TDD Seam 5): fn_guard_lot_closed must never reach thaw_records. Every lot with stock
-- at a branch is CENTRAL_STOCK, which sorts >= LOT_CLOSED in the enum that trigger compares on,
-- so attaching it here would refuse every thaw in the system. A future "attach R8 to every child
-- table" loop fails here loudly instead of taking the branches offline.
--
-- Contract assumed from an unmerged lane: lane C's ...0018 attaches fn_guard_report_closed to
-- thaw_records as a BEFORE trigger that refuses status = 'CLOSED' without an approved, unexpired
-- unlock. TC-03's fixture report is OPEN, so the trigger passes it whichever way it lands.
--
-- ONE do $$ BLOCK: the harness pipes each file into psql without --single-transaction, and the
-- closing raise can only roll back the block it is in. Nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/thaw_schema_test.sql

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_chef   uuid;
  v_bra    uuid;
  v_sup    uuid;
  v_po     uuid;
  v_lot    uuid;
  v_group  uuid;
  v_report uuid;
  v_n      bigint;
  v_txt    text;
  v_ok     boolean;
  v_err    text;
begin
  --------------------------------------------------------------------------------- TC-01
  -- The retry key: uuid, not null, and unique on its own (Finding 1, R4).
  select data_type || '/' || is_nullable into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'thaw_records' and column_name = 'idempotency_key';
  assert v_txt = 'uuid/NO',
    format('TC-01: thaw_records.idempotency_key reads %s, expected uuid/NO (R4, Finding 1)',
           coalesce(v_txt, 'missing'));

  select count(*) into v_n
    from pg_index i
    join pg_class c  on c.oid  = i.indrelid
    join pg_class ic on ic.oid = i.indexrelid
   where c.relname = 'thaw_records' and ic.relname = 'thaw_records_idempotency_key'
     and i.indisunique and i.indnatts = 1 and i.indpred is null
     and (select a.attname from pg_attribute a
           where a.attrelid = c.oid and a.attnum = i.indkey[0]) = 'idempotency_key';
  assert v_n = 1,
    'TC-01: thaw_records_idempotency_key is missing, not unique, partial, or on the wrong column — '
    'a concurrent retry would reach the ledger twice (Seam 1)';

  --------------------------------------------------------------------------------- TC-02
  select is_nullable into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'thaw_records' and column_name = 'smoke_date_group_id';
  assert v_txt = 'NO',
    'TC-02: thaw_records.smoke_date_group_id is nullable — the FIFO sort cannot place a thaw with no group (R15, R21)';

  --------------------------------------------------------------------------------- TC-04
  -- Asked by trigger FUNCTION, not by trigger name, so a rename cannot slip past it.
  select string_agg(t.tgname, ', ') into v_txt
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
   where c.relname = 'thaw_records'
     and not t.tgisinternal
     and t.tgfoid = 'public.fn_guard_lot_closed'::regproc;
  assert v_txt is null,
    format('TC-04: %s fires fn_guard_lot_closed on thaw_records — every branch lot is CENTRAL_STOCK '
           '(>= LOT_CLOSED), so every thaw would be refused (Seam 5, ADR-026)', v_txt);

  --------------------------------------------------------------------------------- TC-03
  -- A real row, so the check is the only thing that can refuse it: a BEFORE trigger (R32's audit,
  -- lane C's report guard) runs before a CHECK, and a random report id would let one of those
  -- answer first. The lot is CENTRAL_STOCK, which is also TC-04's behavioural half at the table.
  insert into auth.users (id) values (v_owner);
  insert into profiles (id, display_name, role, is_active) values (v_owner, 'เจ้าของ', 'L1_OWNER', true);
  insert into locations (code, name_th, kind) values ('CH40S', 'โรงรมทดสอบ', 'CHEF_HOUSE') returning id into v_chef;
  insert into locations (code, name_th, kind) values ('BR40S', 'สาขาทดสอบ', 'BRANCH') returning id into v_bra;
  insert into suppliers (name) values ('ฟู้ดดีว่าทดสอบ') returning id into v_sup;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_po  := fn_create_po(gen_random_uuid(), v_sup, current_date - 5, 100.00, 250.00);
  v_lot := fn_add_po_delivery(gen_random_uuid(), v_po, current_date - 5, 100.00, v_chef);
  -- The group goes in while the lot is PO_CREATED: trg_guard_lot_closed on smoke_date_groups
  -- refuses a group for a CENTRAL_STOCK lot, correctly.
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lot, current_date - 3) returning id into v_group;
  update lots set state = 'CENTRAL_STOCK' where id = v_lot;
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
    values (v_bra, current_date, now(), v_owner) returning id into v_report;

  v_ok := false; v_err := null;
  begin
    insert into thaw_records (daily_report_id, lot_id, smoke_date_group_id, thawed_weight_kg,
                              fifo_override_reason, created_by, idempotency_key)
      values (v_report, v_lot, v_group, 1.00, '   ', v_owner, gen_random_uuid());
  exception when check_violation then
    v_err := sqlerrm; v_ok := v_err like '%thaw_records_fifo_reason_not_blank%';
  end;
  assert v_ok,
    format('TC-03: a blank override reason got %s, expected thaw_records_fifo_reason_not_blank',
           coalesce(v_err, 'no exception at all'));

  -- The control: a real reason, and no reason at all, are both accepted, so the check is not
  -- refusing every row. Nothing reaches this table this way in production — fn_record_thaw is
  -- the only writer — which is why this is a superuser insert.
  insert into thaw_records (daily_report_id, lot_id, smoke_date_group_id, thawed_weight_kg,
                            fifo_override_reason, created_by, idempotency_key)
    values (v_report, v_lot, v_group, 1.00, 'สาขาขอของรมใหม่', v_owner, gen_random_uuid()),
           (v_report, v_lot, v_group, 1.00, null,               v_owner, gen_random_uuid());
  select count(*) into v_n from thaw_records where daily_report_id = v_report;
  assert v_n = 2, format('TC-03: the two valid rows left %s thaw row(s)', v_n);

  -- Deny-all intact: the view (^ref-41) and the function are the only paths.
  assert not has_table_privilege('authenticated', 'public.thaw_records', 'SELECT'),
    'TC-03: authenticated can SELECT thaw_records directly';
  assert not has_table_privilege('authenticated', 'public.thaw_records', 'INSERT'),
    'TC-03: authenticated can INSERT thaw_records directly — fn_record_thaw is not the only writer';

  raise exception 'THAW_SCHEMA_TEST_PASSED';   -- the only clean way back out
end $$;
