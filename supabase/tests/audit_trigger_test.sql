-- Failure-case tests for card ^ref-06 — the generic audit trigger.
--
-- Each assert is a way the audit fails silently rather than loudly:
--   * a table quietly carries no trigger, so its writes are simply absent from the log
--   * the actor is null because auth.uid() was never wired into the trigger
--   * `before` is empty on an UPDATE, so the log records that something changed and not what
--   * a reason column exists under a name the trigger does not know, and is dropped
--   * `created_at` is taken from the row, so a back-dated write back-dates its own audit
--   * the log can be edited or truncated afterwards, which makes all of the above moot
--
-- Covers TC-18, TC-19, TC-20 from TDD-f1-identity-rls-audit.md, plus the coverage sweep.
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/audit_trigger_test.sql

do $$
declare
  v_actor   uuid := '55555555-5555-5555-5555-555555555555';
  v_loc     uuid;
  v_sup     uuid;
  v_po      uuid;
  v_del     uuid;
  v_lot     uuid;
  v_receipt uuid;
  v_day     date := current_date - 2;
  v_a       audit_log%rowtype;
  v_bad     text;
  v_n       bigint;
  v_ok      boolean;
begin
  -- 0. Coverage. Every table but audit_log carries its trigger. This is what catches a table
  --    added by a later card: the attach loop lives in a file that is re-applied on every
  --    deploy, and this assert is what proves the loop actually ran.
  select string_agg(t.tablename, ', ' order by t.tablename), count(*)
    into v_bad, v_n
    from pg_tables t
   where t.schemaname = 'public'
     and t.tablename <> 'audit_log'
     and not exists (
       select 1
         from pg_trigger g
         join pg_class c on c.oid = g.tgrelid
        where c.relname = t.tablename
          and g.tgname  = 'trg_audit_' || t.tablename
     );
  assert v_n = 0, format('^ref-06: %s table(s) have no audit trigger: %s', v_n, v_bad);

  assert not exists (
    select 1 from pg_trigger g join pg_class c on c.oid = g.tgrelid
     where c.relname = 'audit_log' and g.tgname = 'trg_audit_audit_log'
  ), 'the audit trigger is attached to audit_log itself — that recurses';

  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_actor);
  insert into profiles (id, display_name, role, is_active)
       values (v_actor, 'ผู้ตรวจสอบ', 'L1_OWNER', true);

  -- From here the trigger should see a caller.
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor)::text, true);

  insert into locations (code, name_th, kind) values ('CH1', 'โรงรมทดสอบ', 'CHEF_HOUSE')
    returning id into v_loc;
  insert into suppliers (name) values ('ผู้ขายทดสอบ') returning id into v_sup;
  insert into purchase_orders (po_number, supplier_id, event_date, ordered_weight_kg, created_by)
       values ('PO-TEST-1', v_sup, v_day, 100.00, v_actor) returning id into v_po;
  insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg)
       values (v_po, 1, v_day, 100.00) returning id into v_del;
  insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                    chef_house_location_id, event_date)
       values ('LOT-TEST-1', v_po, v_del, 100.00, v_loc, v_day) returning id into v_lot;

  ------------------------------------------------------------- TC-19 / TC-20, the INSERT
  -- lot_receipts is the shallowest table carrying both halves of the card's acceptance:
  -- a weight (received_weight_kg) and a mismatch reason (variance_reason, R22/R27).
  -- created_at is supplied on purpose and must not reach the audit row's own clock.
  insert into lot_receipts (lot_id, event_date, received_weight_kg, post_drain_weight_kg,
                            variance_reason, recorded_by, created_at)
       values (v_lot, v_day, 98.00, 96.50, 'ชั่งได้น้อยกว่าที่ส่งมา', v_actor, timestamptz '2000-01-01 00:00+07')
    returning id into v_receipt;

  select * into v_a from audit_log
   where table_name = 'lot_receipts' and row_id = v_receipt and action = 'INSERT';

  assert v_a.id is not null, 'no audit row for the lot_receipts INSERT';
  assert v_a.actor_id   = v_actor,    format('audit actor_id was %s', v_a.actor_id);
  assert v_a.actor_role = 'L1_OWNER', format('audit actor_role was %s', v_a.actor_role);
  assert v_a.event_date = v_day,      format('audit event_date was %s, expected %s', v_a.event_date, v_day);
  assert v_a.before is null,          'INSERT recorded a `before` snapshot';

  -- The weight at that point. The snapshot is the whole row, so every _kg column is in it.
  assert (v_a.after ->> 'received_weight_kg')::numeric = 98.00,
         format('audit `after` lost the weight: %s', v_a.after ->> 'received_weight_kg');

  -- A reason where data mismatched (R22, R27). Spelled variance_reason on this table,
  -- fifo_override_reason on thaw_records, reason on waste_records — one audit column.
  assert v_a.reason = 'ชั่งได้น้อยกว่าที่ส่งมา', format('audit reason was %L', v_a.reason);

  -- TC-20. The row's own created_at is 26 years old; the audit row's is now.
  assert v_a.created_at > now() - interval '1 minute',
         format('audit created_at was user-supplied: %s', v_a.created_at);
  -- Compared as a timestamp, not as text: jsonb renders timestamptz in the session's zone,
  -- so the string form of this value depends on where the test runs.
  assert (v_a.after ->> 'created_at')::timestamptz = timestamptz '2000-01-01 00:00+07',
         format('the supplied created_at did not survive inside the snapshot, where it belongs: %s',
                v_a.after ->> 'created_at');

  -- A table with no idempotency_key column records null, not an error (ADR-005 applies to
  -- the tables that have one; the trigger must not care either way).
  assert v_a.idempotency_key is null, 'idempotency_key appeared from a table that has none';

  ------------------------------------------------------------------- TC-19, the UPDATE
  update lot_receipts set post_drain_weight_kg = 95.00 where id = v_receipt;

  select * into v_a from audit_log
   where table_name = 'lot_receipts' and row_id = v_receipt and action = 'UPDATE';

  assert v_a.id is not null, 'no audit row for the lot_receipts UPDATE';
  assert (v_a.before ->> 'post_drain_weight_kg')::numeric = 96.50,
         format('UPDATE lost the old value: %s', v_a.before ->> 'post_drain_weight_kg');
  assert (v_a.after  ->> 'post_drain_weight_kg')::numeric = 95.00,
         format('UPDATE lost the new value: %s', v_a.after ->> 'post_drain_weight_kg');

  ------------------------------------------------------------------- TC-19, the DELETE
  delete from lot_receipts where id = v_receipt;

  select * into v_a from audit_log
   where table_name = 'lot_receipts' and row_id = v_receipt and action = 'DELETE';

  assert v_a.id is not null, 'no audit row for the lot_receipts DELETE — the row left no trace';
  assert v_a.after is null,  'DELETE recorded an `after` snapshot';
  assert (v_a.before ->> 'received_weight_kg')::numeric = 98.00,
         'DELETE did not record what was destroyed';

  ---------------------------------------------------------- TC-18, the log is append-only
  v_ok := false;
  begin
    update audit_log set reason = 'ไม่ได้เกิดขึ้นจริง' where id = v_a.id;
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'TC-18: audit_log accepted an UPDATE';

  v_ok := false;
  begin
    delete from audit_log where id = v_a.id;
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'TC-18: audit_log accepted a DELETE';

  -- The other half of the R1 lesson: TRUNCATE fires neither of the events above.
  v_ok := false;
  begin
    truncate audit_log;
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'TC-18: audit_log accepted a TRUNCATE';

  raise exception 'AUDIT_TRIGGER_TEST_PASSED';   -- the only clean way back out
end $$;
