-- Failure-case tests for card ^ref-09 — v_audit_trail, the OW 11 reader.
--
-- ^ref-06's test proves the log is written. This one proves it can be read by exactly one
-- role, and read correctly. Each assert is a way the screen ships looking right and being
-- wrong:
--
--   * the role gate is in the nav instead of the database, so an L2 who types the URL —
--     or calls PostgREST directly — reads the whole trail (TC-A, TC-B)
--   * the gate is so tight it locks the Owner out too, and "deny everyone" passes both
--     deny tests vacuously (TC-C)
--   * the expansion emits every column, so a one-field edit reads as a total rewrite and
--     the field that actually moved is invisible in twenty rows of noise (TC-D)
--   * a creation expands per column too, so one INSERT reads as twelve edits (TC-E)
--   * a screen reaches past the view to the table, and the WHERE clause is decoration
--     (TC-F)
--   * เวลา is the business date rather than the moment it was typed, so a back-dated
--     entry back-dates its own audit trail (TC-G)
--
-- Covers TC-A … TC-G from v.0.1/ref-04-09-f1-identity-rls-audit/PLAN-f1-audit-trail.md,
-- and makes TC-22 of TDD-f1-identity-rls-audit.md real — v_audit_trail is the first
-- L1-only read in the system, so before this card the route guard was the only thing
-- being proved.
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/audit_trail_test.sql

do $$
declare
  v_owner    uuid := '11111111-1111-1111-1111-111111111111';
  v_l2       uuid := '22222222-2222-2222-2222-222222222222';
  v_l3       uuid := '33333333-3333-3333-3333-333333333333';
  v_sup      uuid;
  v_po       uuid;
  v_day      date := current_date - 3;
  v_stale    timestamptz := timestamptz '2000-01-01 00:00+07';
  v_ins      uuid;
  v_upd      uuid;
  v_n        bigint;
  v_field    text;
  v_old      text;
  v_new      text;
  v_when     timestamptz;
  v_actor    text;
  v_ok       boolean;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของกิจการ',    'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',       'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่', 'L3_CM_OPERATOR',  true);

  insert into suppliers (name) values ('ฟู้ดดีว่า') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  -- purchase_orders is the shallowest table carrying all three clocks this view has to
  -- keep apart: event_date (the order date), its own created_at (supplied stale on
  -- purpose), and the audit row's created_at, which is the only one เวลา may show.
  insert into purchase_orders (po_number, supplier_id, event_date, ordered_weight_kg,
                               created_by, created_at)
       values ('PO-AUDIT-1', v_sup, v_day, 100.00, v_owner, v_stale)
    returning id into v_po;

  select id into v_ins from audit_log
   where table_name = 'purchase_orders' and row_id = v_po and action = 'INSERT';
  assert v_ins is not null, 'no audit row for the PO insert — ^ref-06 regressed, not this card';

  update purchase_orders set ordered_weight_kg = 120.00 where id = v_po;

  select id into v_upd from audit_log
   where table_name = 'purchase_orders' and row_id = v_po and action = 'UPDATE';
  assert v_upd is not null, 'no audit row for the PO update';

  ------------------------------------------------------------------------ TC-A, the L3 gate
  -- The card's acceptance line. Hiding the nav item is not enforcement (ADR-004, UAT-15).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  select count(*) into v_n from v_audit_trail;
  assert v_n = 0, format('TC-A: an L3 session reads %s rows of v_audit_trail', v_n);

  ------------------------------------------------------------------------ TC-B, the L2 gate
  -- The permissions table gives L2 `—` as well. An audit trail scoped "own branch" would
  -- still show an L2 the Owner's config edits, which is the leak worth naming separately.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  select count(*) into v_n from v_audit_trail;
  assert v_n = 0, format('TC-B: an L2 session reads %s rows of v_audit_trail', v_n);

  ------------------------------------------------------------------ TC-C, not deny-everyone
  -- Two passing deny tests prove nothing on their own: `where false` passes both.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_audit_trail where audit_id in (v_ins, v_upd);
  assert v_n > 0, 'TC-C: the WHERE clause hid the Owner too — "deny everyone" is not the rule';

  --------------------------------------------------------------------- TC-D, the expansion
  -- One field moved, so one row. purchase_orders has twelve columns; the silent failure is
  -- twelve rows, eleven of them "value → same value", with the real change buried.
  select count(*) into v_n from v_audit_trail where audit_id = v_upd;
  assert v_n = 1, format(
    'TC-D: a one-field UPDATE expanded to %s rows — the view is emitting unchanged keys', v_n);

  select field_name, old_value, new_value into v_field, v_old, v_new
    from v_audit_trail where audit_id = v_upd;
  assert v_field = 'ordered_weight_kg', format('TC-D: field_name was %L', v_field);
  assert v_old::numeric = 100.00, format('TC-D: old_value was %L, expected 100.00', v_old);
  assert v_new::numeric = 120.00, format('TC-D: new_value was %L, expected 120.00', v_new);

  -- ผู้แก้ comes from the join, not from the jsonb. A null actor_name here is the column
  -- the screen renders blank for every row.
  select actor_name into v_actor from v_audit_trail where audit_id = v_upd;
  assert v_actor = 'เจ้าของกิจการ', format('TC-D: actor_name was %L', v_actor);

  ------------------------------------------------------------- TC-E, a creation is one event
  select count(*) into v_n from v_audit_trail where audit_id = v_ins;
  assert v_n = 1, format(
    'TC-E: an INSERT expanded to %s rows — a creation is one event, not one per column', v_n);

  select field_name into v_field from v_audit_trail where audit_id = v_ins;
  assert v_field is null, format('TC-E: an INSERT named field %L', v_field);

  -------------------------------------------------------------------------------- TC-G, เวลา
  -- Three clocks, and only one of them is the answer to "when was this typed" (ADR-007).
  -- The PO's own created_at is 26 years old and its event_date is three days back; the
  -- audit row's created_at is now. Asserted before TC-F, which changes the database role.
  select changed_at into v_when from v_audit_trail where audit_id = v_upd;
  assert v_when > now() - interval '1 minute',
    format('TC-G: changed_at was %s — it is not audit_log.created_at', v_when);
  assert v_when::date <> v_day,
    format('TC-G: changed_at fell on the event_date (%s) — the wrong clock shipped', v_day);
  assert v_when <> v_stale,
    'TC-G: changed_at is the audited row''s own created_at, not the audit row''s';

  ------------------------------------------------------------------ TC-F, no way around it
  -- The workaround. A screen that selects audit_log directly must fail, or the WHERE
  -- clause above is decoration — and the view must still be readable, or the grant is
  -- missing and the screen is broken for the Owner too.
  set local role authenticated;

  v_ok := false;
  begin
    perform 1 from audit_log limit 1;
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'TC-F: an authenticated session read audit_log directly (ADR-004)';

  v_ok := false;
  begin
    select count(*) into v_n from v_audit_trail;
    v_ok := true;
  exception when others then
    v_ok := false;
  end;
  assert v_ok, 'TC-F: authenticated cannot select v_audit_trail — the grant is missing';
  assert v_n > 0, 'TC-F: a real authenticated L1 session read 0 rows through the view';

  reset role;

  -- And no grant was quietly added to the table to make any of the above work.
  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name = 'audit_log'
     and grantee in ('anon', 'authenticated');
  assert v_n = 0, format('TC-F: %s grant(s) were added on audit_log (ADR-004)', v_n);

  raise exception 'AUDIT_TRAIL_TEST_PASSED';   -- the only clean way back out
end $$;
