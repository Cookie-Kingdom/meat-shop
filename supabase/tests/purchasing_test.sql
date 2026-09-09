-- Failure-case tests for card ^ref-19 — fn_create_po, fn_add_po_delivery, v_po_outstanding.
--
-- Covers TC-05 ... TC-19 and TC-21 ... TC-33 from TDD-purchasing.md. TC-20 needs two
-- sessions and lives in purchasing_concurrency_test.sh.
--
-- Each assert is a way a purchase silently becomes the wrong number:
--   * an L2, an L3 or a deactivated Owner raises a PO, and the audit trail names them as
--     entitled to (ADR-004, R31)
--   * created_by or seq is a parameter, so a round can be signed by or ordered as somebody
--     else chooses
--   * a retry from a dropped connection books a second 30 kg round, and every lot, freight
--     share and yield figure downstream inherits the double (R4)
--   * a genuine second identical round is refused as if it were that retry
--   * a round is booked past the ordered weight, or two concurrent ones each fit alone
--   * a round is written with no lot, or a lot with a weight that is not the round's — and
--     BR03's loss base is then a weight that never moved (D01, R16)
--   * a lot is dispatched to a branch rather than the chef house (BR11)
--   * this card posts to the ledger, putting meat in stock days before the truck
--   * this card grants a session SELECT on a table holding a price (ADR-004, R20)
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/purchasing_test.sql

do $$
declare
  v_owner  uuid := '77777777-7777-7777-7777-777777777791';
  v_l2     uuid := '77777777-7777-7777-7777-777777777792';
  v_l3     uuid := '77777777-7777-7777-7777-777777777793';
  v_gone   uuid := '77777777-7777-7777-7777-777777777794';
  v_chef   uuid;
  v_branch uuid;
  v_sup    uuid;
  v_dead   uuid;
  v_po     uuid;
  v_po2    uuid;
  v_lot    uuid;
  v_lot2   uuid;
  v_again  uuid;
  v_n      bigint;
  v_num    numeric;
  v_ord    numeric;
  v_disp   numeric;
  v_recv   numeric;
  v_outst  numeric;
  v_rounds bigint;
  v_txt    text;
  v_ok     boolean;
  v_err    text;
  v_key    uuid;
  v_ledger bigint;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3), (v_gone);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',          'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',       'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่', 'L3_CM_OPERATOR',  true),
    (v_gone,  'เจ้าของที่ปิดใช้',    'L1_OWNER',        false);

  insert into locations (code, name_th, kind) values ('CH1', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('BRD', 'สาขาดี', 'BRANCH')
    returning id into v_branch;
  insert into suppliers (name, is_active) values ('ฟู้ดดีว่า', true)  returning id into v_sup;
  insert into suppliers (name, is_active) values ('ผู้ขายเก่า', false) returning id into v_dead;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-07
  -- L1 only, and the check is in the body: these are SECURITY DEFINER, so RLS does not
  -- apply inside them and there is no policy to consult (ADR-002, ADR-004).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  v_ok := false;
  begin
    perform fn_create_po(gen_random_uuid(), v_sup, date '2026-03-01', 100.00, 250.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-07: an L2 session was not refused (%s)', coalesce(v_err, 'no exception at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false;
  begin
    perform fn_create_po(gen_random_uuid(), v_sup, date '2026-03-01', 100.00, 250.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-07: an L3 session was not refused (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-08
  -- A deactivated Owner holding a live JWT is NO_ACTOR, not FORBIDDEN. The distinction is
  -- the whole point of asking the actor question first (R31).
  perform set_config('request.jwt.claims', json_build_object('sub', v_gone)::text, true);
  v_ok := false;
  begin
    perform fn_create_po(gen_random_uuid(), v_sup, date '2026-03-01', 100.00, 250.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%NO_ACTOR%';
  end;
  assert v_ok, format('TC-08: a deactivated Owner was not NO_ACTOR (%s)', coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from purchase_orders;
  assert v_n = 0, format('TC-07/08: %s purchase orders were written by refused callers', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-09
  -- By name, not as an FK error. `violates foreign key constraint` tells the Owner nothing
  -- about a supplier they can see in their own list.
  v_ok := false;
  begin
    perform fn_create_po(gen_random_uuid(), v_dead, date '2026-03-01', 100.00, 250.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%SUPPLIER_INACTIVE%';
  end;
  assert v_ok, format('TC-09: an inactive supplier was not refused by name (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-10
  -- Refused by name before the CHECK constraint fires.
  v_ok := false;
  begin
    perform fn_create_po(gen_random_uuid(), v_sup, date '2026-03-01', 0, 250.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%PO_WEIGHT_INVALID%';
  end;
  assert v_ok, format('TC-10: a zero-weight order was not refused by name (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-05
  v_key := gen_random_uuid();
  v_po := fn_create_po(v_key, v_sup, date '2026-03-01', 100.00, 250.00, 10.00, 500.00, 'รอบมีนาคม');
  assert v_po is not null, 'TC-05: fn_create_po returned null';

  select po_number, created_by into v_txt, v_again from purchase_orders where id = v_po;
  assert v_txt = 'PO-202603-001', format('TC-05: po_number is %s, expected PO-202603-001', v_txt);
  assert v_again = v_owner, 'TC-05: created_by is not the calling Owner';

  --------------------------------------------------------------------------------- TC-06
  -- created_by cannot be spoofed because there is no actor parameter to spoof it with.
  select count(*) into v_n
    from pg_proc p, unnest(p.proargnames) a(name)
   where p.proname = 'fn_create_po'
     and a.name in ('p_created_by', 'p_actor_id', 'p_actor', 'p_user_id');
  assert v_n = 0, 'TC-06: fn_create_po takes an actor parameter — created_by can be signed as somebody else';

  --------------------------------------------------------------------------------- TC-11
  -- A retry from a dropped connection has to look exactly like the first call succeeded,
  -- and must not mint a second po_number on its way there.
  v_again := fn_create_po(v_key, v_sup, date '2026-03-01', 100.00, 250.00, 10.00, 500.00, 'รอบมีนาคม');
  assert v_again = v_po, 'TC-11: a replayed PO returned a different id';
  select count(*) into v_n from purchase_orders;
  assert v_n = 1, format('TC-11: a retry wrote a second PO (%s rows)', v_n);

  --------------------------------------------------------------------------------- TC-12
  -- Same key, different payload. Raising leaves the committed 100 kg alone; returning the
  -- id would tell the caller their 120 kg order succeeded when it does not exist.
  v_ok := false;
  begin
    perform fn_create_po(v_key, v_sup, date '2026-03-01', 120.00, 250.00, 10.00, 500.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%PO_IDEMPOTENCY_CONFLICT%';
  end;
  assert v_ok, format('TC-12: a changed payload on a used key was accepted (%s)', coalesce(v_err, 'no exception at all'));
  select ordered_weight_kg into v_num from purchase_orders where id = v_po;
  assert v_num = 100.00, format('TC-12: the committed order became %s kg', v_num);

  --------------------------------------------------------------------------------- TC-21
  v_ok := false;
  begin
    perform fn_add_po_delivery(gen_random_uuid(), gen_random_uuid(), date '2026-03-02', 40.00, v_chef);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%PO_NOT_FOUND%';
  end;
  assert v_ok, format('TC-21: a round against an unknown PO was not refused (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-22
  -- BR11: nothing reaches a branch without passing through central stock first, and a lot
  -- certainly does not arrive there off a truck from Foodiva. The FK alone accepts it.
  v_ok := false;
  begin
    perform fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-03-02', 40.00, v_branch);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%LOCATION_KIND_INVALID%';
  end;
  assert v_ok, format('TC-22: a BRANCH destination was accepted for a lot (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------- TC-13, TC-14
  v_key := gen_random_uuid();
  v_lot := fn_add_po_delivery(v_key, v_po, date '2026-03-02', 40.00, v_chef, 'รอบแรก');
  assert v_lot is not null, 'TC-13: fn_add_po_delivery returned null';

  select count(*) into v_n from po_deliveries where po_id = v_po;
  assert v_n = 1, format('TC-13: %s rounds after one call', v_n);
  select count(*) into v_n from lots where po_id = v_po;
  assert v_n = 1, format('TC-13: %s lots after one round — D01 says exactly one', v_n);

  select d.seq into v_n from po_deliveries d join lots l on l.po_delivery_id = d.id
   where l.id = v_lot;
  assert v_n = 1, format('TC-13: the first round has seq %s', v_n);

  select l.state::text, l.event_date::text into v_txt, v_err from lots l where l.id = v_lot;
  assert v_txt = 'PO_CREATED', format('TC-13: a new lot is in state %s', v_txt);
  assert v_err = '2026-03-02', format('TC-13: the lot event_date is %s, not the dispatch date', v_err);

  -- TC-14. This equality is BR03's loss base and ADR-011's yield divisor. Frozen here, or
  -- every yield figure the system ever shows is computed against a weight that never moved.
  select count(*) into v_n
    from lots l join po_deliveries d on d.id = l.po_delivery_id
   where l.id = v_lot and l.foodiva_sent_weight_kg = d.foodiva_sent_weight_kg
     and l.foodiva_sent_weight_kg = 40.00;
  assert v_n = 1, 'TC-14: the lot weight and its round weight are not the same 40.00 kg';

  --------------------------------------------------------------------------------- TC-16
  select count(*) into v_n
    from pg_proc p, unnest(p.proargnames) a(name)
   where p.proname = 'fn_add_po_delivery' and a.name = 'p_seq';
  assert v_n = 0, 'TC-16: fn_add_po_delivery takes p_seq — a caller can reorder the rounds';

  --------------------------------------------------------------------------------- TC-23
  -- The same lot id both times, and no second round. A retry that returns a new lot makes
  -- the client book another one to "fix" it.
  v_again := fn_add_po_delivery(v_key, v_po, date '2026-03-02', 40.00, v_chef, 'รอบแรก');
  assert v_again = v_lot, 'TC-23: a replayed round returned a different lot';
  select count(*) into v_n from po_deliveries where po_id = v_po;
  assert v_n = 1, format('TC-23: a retry booked a second round (%s rows)', v_n);
  select count(*) into v_n from lots where po_id = v_po;
  assert v_n = 1, format('TC-23: a retry created a second lot (%s rows)', v_n);

  --------------------------------------------------------------------------------- TC-15
  v_lot2 := fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-03-05', 30.00, v_chef);
  assert v_lot2 <> v_lot, 'TC-15: the second round returned the first lot';
  select d.seq into v_n from po_deliveries d join lots l on l.po_delivery_id = d.id
   where l.id = v_lot2;
  assert v_n = 2, format('TC-15: the second round has seq %s, expected 2', v_n);
  select count(distinct lot_code) into v_n from lots where po_id = v_po;
  assert v_n = 2, format('TC-15: %s distinct lot codes for two rounds (D01)', v_n);
  select foodiva_sent_weight_kg into v_num from lots where id = v_lot;
  assert v_num = 40.00, format('TC-15: the first lot changed to %s kg', v_num);

  --------------------------------------------------------------------------------- TC-19
  -- Over by a satang of weight is still over. 40 + 30 + 30.01 against 100.
  v_ok := false;
  begin
    perform fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-03-08', 30.01, v_chef);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%PO_OVERDELIVERY%';
  end;
  assert v_ok, format('TC-19: 0.01 kg over the order was accepted (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-17
  v_ok := false;
  begin
    perform fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-03-08', 31.00, v_chef);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%PO_OVERDELIVERY%';
  end;
  assert v_ok, format('TC-17: an over-delivery was accepted (%s)', coalesce(v_err, 'no exception at all'));

  -- Neither refusal may leave half a write behind: no round, and no orphan lot (D01).
  select count(*) into v_n from po_deliveries where po_id = v_po;
  assert v_n = 2, format('TC-17: a refused round left %s rows behind', v_n);
  select count(*) into v_n from lots where po_id = v_po;
  assert v_n = 2, format('TC-17: a refused round left %s lots behind', v_n);

  --------------------------------------------------------------------------------- TC-18
  -- The boundary is `>`, not `>=`. Cumulative exactly equal to ordered is fully delivered,
  -- not over-delivered. Same class of decision as R16's yield boundary.
  v_again := fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-03-08', 30.00, v_chef);
  assert v_again is not null, 'TC-18: the round that filled the order exactly was refused';
  select sum(foodiva_sent_weight_kg) into v_num from po_deliveries where po_id = v_po;
  assert v_num = 100.00, format('TC-18: cumulative is %s, expected exactly 100.00', v_num);

  -- And a further round on a full PO is refused (edge case: delivered in full, then more).
  v_ok := false;
  begin
    perform fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-03-09', 0.01, v_chef);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%PO_OVERDELIVERY%';
  end;
  assert v_ok, format('TC-18: a round against a fully delivered PO was accepted (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-24
  -- Two genuine 40 kg rounds on the same day, different keys. A real double, not a retry —
  -- which is exactly why the key could not ride the payload (Finding 3).
  v_po2 := fn_create_po(gen_random_uuid(), v_sup, date '2026-03-01', 200.00, 250.00);
  assert v_po2 <> v_po, 'TC-24: the second PO returned the first id';
  select po_number into v_txt from purchase_orders where id = v_po2;
  assert v_txt = 'PO-202603-002', format('TC-24: the second PO number is %s, expected PO-202603-002', v_txt);

  perform fn_add_po_delivery(gen_random_uuid(), v_po2, date '2026-03-03', 40.00, v_chef);
  perform fn_add_po_delivery(gen_random_uuid(), v_po2, date '2026-03-03', 40.00, v_chef);
  select count(*) into v_n from po_deliveries where po_id = v_po2;
  assert v_n = 2, format('TC-24: two genuine identical rounds produced %s rows', v_n);
  select count(*) into v_n from lots where po_id = v_po2;
  assert v_n = 2, format('TC-24: two genuine identical rounds produced %s lots', v_n);

  --------------------------------------------------------------------------------- TC-25
  -- A PO is a commitment and a booked round is a plan. The meat has not left Foodiva, and
  -- stock enters at fn_dispatch_transport_line (^ref-22), not here.
  select count(*) into v_ledger from stock_ledger;
  assert v_ledger = 0,
    format('TC-25: this card posted %s ledger rows — meat is in stock days before the truck', v_ledger);

  --------------------------------------------------------------------------------- TC-26
  -- The audit row comes from ^ref-06's generic trigger, inside this same transaction. The
  -- functions contain no audit_log insert; a second one would audit every PO twice (R32).
  select count(*) into v_n from audit_log
   where table_name = 'purchase_orders' and row_id = v_po and action = 'INSERT';
  assert v_n = 1, format('TC-26: %s audit rows for one purchase order', v_n);
  select actor_id into v_again from audit_log
   where table_name = 'purchase_orders' and row_id = v_po and action = 'INSERT';
  assert v_again = v_owner, 'TC-26: the audit row does not name the calling Owner';

  select count(*) into v_n from audit_log
   where table_name = 'lots' and row_id = v_lot and action = 'INSERT';
  assert v_n = 1, format('TC-26: %s audit rows for one lot', v_n);

  select count(*) into v_n
    from pg_proc where proname in ('fn_create_po', 'fn_add_po_delivery')
     and prosrc ilike '%insert into audit_log%';
  assert v_n = 0, 'TC-26: a purchasing function inserts into audit_log itself — every row is audited twice';

  ------------------------------------------------------------------------- TC-27 ... TC-30
  -- v_po_outstanding. v_po is 100 ordered / 100 dispatched over 3 rounds; v_po2 is 200
  -- ordered / 80 over 2. A receipt on one of v_po2's lots proves received lags dispatch.
  select id into v_again from lots where po_id = v_po2 order by lot_code limit 1;
  insert into lot_receipts (lot_id, event_date, received_weight_kg, recorded_by)
       values (v_again, date '2026-03-04', 39.20, v_owner);

  select ordered_weight_kg, dispatched_weight_kg, outstanding_weight_kg, received_weight_kg
    into v_ord, v_disp, v_outst, v_recv
    from v_po_outstanding where po_id = v_po2;
  assert v_ord = 200.00, format('TC-27: ordered reads %s', v_ord);
  assert v_disp = 80.00, format('TC-27: dispatched reads %s, expected 80.00', v_disp);
  assert v_outst = 120.00, format('TC-27: outstanding reads %s, expected 120.00', v_outst);
  -- and they reconcile, which is the clause the card is actually accepted on
  assert v_ord - v_disp = v_outst, 'TC-27: ordered - dispatched does not equal outstanding';

  --------------------------------------------------------------------------------- TC-29
  -- Received lags dispatch: one of the two lots has a receipt, both have a round.
  assert v_recv = 39.20, format('TC-29: received reads %s, expected the one receipt at 39.20', v_recv);
  assert v_disp = 80.00, format('TC-29: dispatched reads %s — it must count both lots', v_disp);

  --------------------------------------------------------------------------------- TC-30
  -- A fully delivered PO stays visible with outstanding 0.00. Dropping it would hide the
  -- one the Owner is about to book a return run against.
  select outstanding_weight_kg, dispatched_weight_kg into v_outst, v_disp
    from v_po_outstanding where po_id = v_po;
  assert v_outst = 0.00, format('TC-30: a fully delivered PO reads outstanding %s', v_outst);
  assert v_disp = 100.00, format('TC-30: dispatched reads %s, expected 100.00', v_disp);

  --------------------------------------------------------------------------------- TC-28
  -- A PO with no round at all: dispatched 0.00, outstanding = ordered. Not null, not absent.
  v_again := fn_create_po(gen_random_uuid(), v_sup, date '2026-04-01', 55.00, 250.00);
  select dispatched_weight_kg, received_weight_kg, outstanding_weight_kg, round_count
    into v_disp, v_recv, v_outst, v_rounds
    from v_po_outstanding where po_id = v_again;
  assert v_disp = 0.00,  format('TC-28: a PO with no rounds reads dispatched %s', coalesce(v_disp::text, 'NULL'));
  assert v_recv = 0.00,  format('TC-28: a PO with no rounds reads received %s', coalesce(v_recv::text, 'NULL'));
  assert v_outst = 55.00, format('TC-28: a PO with no rounds reads outstanding %s, expected 55.00', coalesce(v_outst::text, 'NULL'));
  assert v_rounds = 0, format('TC-28: round_count reads %s', coalesce(v_rounds::text, 'NULL'));

  -- The counter is scoped to the month of the order date, so April restarts at 001.
  select po_number into v_txt from purchase_orders where id = v_again;
  assert v_txt = 'PO-202604-001', format('TC-28: April PO numbered %s, expected PO-202604-001', v_txt);

  select count(*) into v_n from v_po_outstanding;
  assert v_n = 3, format('TC-28: the Owner sees %s of 3 purchase orders', v_n);

  --------------------------------------------------------------------------- TC-31, TC-32
  -- The role test is the view's WHERE, not a GRANT — there is one database role for
  -- application users (R34). An L3 session gets zero rows from the database, which is how
  -- F4's "the CM operator never sees any price field" is actually enforced (ADR-004, R20).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  select count(*) into v_n from v_po_outstanding;
  assert v_n = 0, format('TC-31: an L2 session sees %s rows of v_po_outstanding', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  select count(*) into v_n from v_po_outstanding;
  assert v_n = 0, format('TC-32: an L3 session sees %s rows of v_po_outstanding', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_po_outstanding;
  assert v_n = 3, format('TC-31/32: the filter hid the Owner too (%s rows) — "deny everyone" is not the rule', v_n);

  --------------------------------------------------------------------------------- TC-33
  -- No table grant was added. A screen that works around the view by selecting the tables
  -- gets permission denied; rls_deny_all_test.sql keeps the whole posture green.
  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name in ('purchase_orders', 'po_deliveries', 'lots', 'suppliers')
     and grantee in ('anon', 'authenticated');
  assert v_n = 0, format('TC-33: %s grants were added on the purchasing tables (ADR-004, R20)', v_n);

  -- ...and the two functions plus the one view are callable by an application session.
  select count(*) into v_n
    from pg_proc p
   where p.proname in ('fn_create_po', 'fn_add_po_delivery')
     and has_function_privilege('authenticated', p.oid, 'execute');
  assert v_n = 2, format('TC-33: %s of 2 purchasing functions are callable by authenticated', v_n);
  assert has_table_privilege('authenticated', 'public.v_po_outstanding', 'select'),
    'TC-33: authenticated cannot select v_po_outstanding';

  ---------------------------------------------------------------- the uniform RPC contract
  -- A null idempotency key is refused everywhere, so the TypeScript wrapper shape is the
  -- same for every write in the system (ADR-005).
  v_ok := false; v_err := null;
  begin
    perform fn_create_po(null, v_sup, date '2026-03-01', 100.00, 250.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%IDEMPOTENCY_KEY_REQUIRED%';
  end;
  assert v_ok, format('R4: fn_create_po accepted a null idempotency key (%s)', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_add_po_delivery(null, v_po2, date '2026-03-03', 10.00, v_chef);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%IDEMPOTENCY_KEY_REQUIRED%';
  end;
  assert v_ok, format('R4: fn_add_po_delivery accepted a null idempotency key (%s)', coalesce(v_err, 'no exception at all'));

  raise exception 'PURCHASING_TEST_PASSED';   -- the only clean way back out
end $$;
