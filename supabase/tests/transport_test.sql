-- Failure-case tests for cards ^ref-22 and ^ref-23 — fn_create_transport_run,
-- fn_dispatch_transport_line, fn_confirm_transport_receipt, fn_allocate_freight and the
-- three transport views.
--
-- Covers TC-05 ... TC-37, TC-39 and TC-40 from TDD-transport.md. TC-41 needs two sessions
-- and lives in transport_concurrency_test.sh. TC-21 and TC-38 are schema-shaped and live in
-- transport_schema_test.sql.
--
-- Each assert is a way meat or money silently becomes the wrong number:
--   * a run is created by an L2, an L3 or a deactivated Owner (ADR-004, R31)
--   * the allocation method is chosen by the caller, or re-read from config after the fact,
--     so a config change made in July moves a number closed in March (R29, BR23)
--   * a return run is created for lots nobody has scheduled a pickup for (R26, BR17)
--   * a dispatch leaves the in-transit tuple at the wrong end, and every balance downstream
--     stays plausible and wrong (Seam 1)
--   * a retry from a dropped Chiang Mai connection posts a second TRANSFER_OUT and 40 kg
--     becomes 80 kg against a lot that can never balance (Seam 2, R4)
--   * a partial receipt is treated as a full one, and 10 kg is conjured onto the shelf (D06)
--   * a variance past threshold is signed off with no reason (UAT-11, BR12)
--   * a branch admin signs for another branch's load, or for the chef house (ADR-004)
--   * the rounded freight shares sum to 99.99 and the cost of goods drifts (R24, Seam 3)
--   * an L3 session reads a fare (R20, R34)
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/transport_test.sql

do $$
declare
  v_owner   uuid := '77777777-7777-7777-7777-7777777777b1';
  v_l2      uuid := '77777777-7777-7777-7777-7777777777b2';
  v_l3      uuid := '77777777-7777-7777-7777-7777777777b3';
  v_gone    uuid := '77777777-7777-7777-7777-7777777777b4';
  v_chef    uuid;
  v_central uuid;
  v_brA     uuid;
  v_brB     uuid;
  v_sup     uuid;
  v_po      uuid;
  v_lots    uuid[] := '{}';
  v_run     uuid;
  v_run2    uuid;
  v_run3    uuid;
  v_line    uuid;
  v_line2   uuid;
  v_again   uuid;
  v_key     uuid;
  v_method  freight_alloc;
  v_method2 freight_alloc;
  v_txt     text;
  v_ok      boolean;
  v_err     text;
  v_n       bigint;
  v_ledger  bigint;
  v_qty     numeric;
  v_share1  numeric;
  v_share2  numeric;
  v_sum     numeric;
  v_age     integer;
  i         integer;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3), (v_gone);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',           'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',        'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่', 'L3_CM_OPERATOR',  true),
    (v_gone,  'เจ้าของที่ปิดใช้',     'L1_OWNER',        false);

  insert into locations (code, name_th, kind) values ('CH2', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('CEN', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  insert into locations (code, name_th, kind) values ('BRA', 'สาขามีนบุรี', 'BRANCH')
    returning id into v_brA;
  insert into locations (code, name_th, kind) values ('BRB', 'สาขาศาลาแดง', 'BRANCH')
    returning id into v_brB;

  insert into user_locations (profile_id, location_id) values (v_l2, v_brA), (v_l3, v_chef);
  insert into suppliers (name, is_active) values ('Foodiva', true) returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  -- Config. Every key F5 reads, dated, because a business number in a function body is a
  -- support ticket (ADR-006, ADR-018). The three freight_alloc_method rows give each
  -- allocation test its own date island rather than a mutated global.
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', date '2026-01-01',
                        p_value_text => 'BY_LOT_WEIGHT');
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', date '2026-06-01',
                        p_value_text => 'EQUAL_SPLIT');
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', date '2026-07-01',
                        p_value_text => 'MANUAL');
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-04-01',
                        p_value_text => 'false');
  perform fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', date '2026-05-01',
                        p_value_text => 'false');

  v_po := fn_create_po(gen_random_uuid(), v_sup, date '2026-03-01', 1000.00, 250.00);
  for i in 1..16 loop
    v_lots := v_lots || fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-03-01',
                                           40.00, v_chef);
  end loop;

  --------------------------------------------------------------------------------- TC-05
  -- Happy path, and the method is the one config held on the run's own event date.
  v_run := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', date '2026-03-05',
                                   'รถกระบะ', false, 4500.00);
  select alloc_method into v_method from transport_runs where id = v_run;
  assert v_method = 'BY_LOT_WEIGHT',
    format('TC-05: alloc_method snapshotted as %s, not the config value at 2026-03-05', v_method);

  --------------------------------------------------------------------------------- TC-07
  -- The method cannot be passed in. A caller who can choose it can choose a different one
  -- for the same day's two runs and nothing on screen would say so.
  select pg_get_function_arguments(p.oid) into v_txt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_create_transport_run';
  assert v_txt not like '%alloc_method%',
    format('TC-07: fn_create_transport_run takes an alloc_method parameter (%s)', v_txt);

  --------------------------------------------------------------------------------- TC-08
  -- ADR-023: an unset BLOCK key is a named refusal, never a default. Nothing is configured
  -- before 2026-01-01, so a run dated before it has no method to snapshot.
  v_ok := false; v_err := null;
  begin
    perform fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', date '2025-12-05',
                                    'รถกระบะ', false, 4500.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%CONFIG_NOT_SET%';
  end;
  assert v_ok, format('TC-08: a run was created with no freight_alloc_method set (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-09
  -- R26 / BR17. The return leg exists only once somebody has named a receive date. Closing
  -- the lot does not create it.
  update lots set state = 'LOT_CLOSED' where id = v_lots[1];
  v_ok := false; v_err := null;
  begin
    perform fn_create_transport_run(gen_random_uuid(), 'CM_TO_FOODIVA', date '2026-03-05',
                                    'รถห้องเย็น', false, 6000.00, array[v_lots[1]]);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%RETURN_NOT_SCHEDULED%';
  end;
  assert v_ok, format('TC-09: a return run was created for an unscheduled lot (%s)',
                      coalesce(v_err, 'no exception at all'));

  select lot_code into v_txt from lots where id = v_lots[1];
  assert v_err like '%' || v_txt || '%',
    format('TC-09: the refusal does not name the offending lot (%s)', v_err);

  select count(*) into v_n from transport_runs where route = 'CM_TO_FOODIVA';
  assert v_n = 0, format('TC-09: %s CM_TO_FOODIVA run(s) were written despite the refusal', v_n);

  --------------------------------------------------------------------------------- TC-10
  -- One bad lot in three. Checked over the whole array BEFORE anything is written — a
  -- per-lot loop would leave two lines and a raise.
  update lots set state = 'RETURN_SCHEDULED' where id in (v_lots[2], v_lots[3]);
  v_ok := false; v_err := null;
  begin
    perform fn_create_transport_run(gen_random_uuid(), 'CM_TO_FOODIVA', date '2026-03-05',
                                    'รถห้องเย็น', false, 6000.00,
                                    array[v_lots[2], v_lots[3], v_lots[1]]);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%RETURN_NOT_SCHEDULED%';
  end;
  assert v_ok, format('TC-10: two good lots carried a bad one onto a return run (%s)',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from transport_runs where route = 'CM_TO_FOODIVA';
  assert v_n = 0, format('TC-10: %s partial run(s) survived the refusal', v_n);

  --------------------------------------------------------------------------------- TC-11
  -- L1 only, checked in the body: these are SECURITY DEFINER, so RLS does not apply inside
  -- them and there is no policy to consult (ADR-002, ADR-004).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', date '2026-03-05',
                                    'รถกระบะ', false, 4500.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-11: an L2 session created a transport run (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-12
  -- Actor before role: a deactivated Owner holding a live token is NO_ACTOR, not FORBIDDEN.
  -- The distinction is what tells whoever reads the log which of the two states they are in.
  perform set_config('request.jwt.claims', json_build_object('sub', v_gone)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', date '2026-03-05',
                                    'รถกระบะ', false, 4500.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%NO_ACTOR%';
  end;
  assert v_ok, format('TC-12: a deactivated Owner was reported as merely forbidden (%s)',
                      coalesce(v_err, 'no exception at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-13
  v_key := gen_random_uuid();
  v_line := fn_dispatch_transport_line(v_key, v_run, v_lots[4], null, null, v_chef, 40.00);

  select count(*) into v_n from transport_lines
   where id = v_line and dispatched_weight_kg = 40.00
     and received_weight_kg is null and outstanding_weight_kg is null;
  assert v_n = 1, 'TC-13: the dispatched line is not 40 kg out with nothing received';

  --------------------------------------------------------------------------------- TC-14
  -- SEAM 1, CORRECTED. TDD-transport asserted "READY at the origin down 40", which assumed
  -- a Foodiva location holding a balance. There is none: location_kind is CENTRAL,
  -- CHEF_HOUSE or BRANCH, Foodiva is a supplier, and fn_add_po_delivery writes nothing to
  -- the ledger. The outbound leg is where meat ENTERS the books, so what this test asserts
  -- is the absence: exactly one ledger row for this lot, and it is not at an origin.
  select count(*) into v_ledger from stock_ledger where lot_id = v_lots[4];
  assert v_ledger = 1,
    format('TC-14: a FOODIVA_TO_CM dispatch wrote %s ledger rows, not the single +IN_TRANSIT', v_ledger);

  v_ok := false; v_err := null;
  begin
    perform fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lots[5], null,
                                       v_central, v_chef, 40.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%ORIGIN_LOCATION_INVALID%';
  end;
  assert v_ok, format('TC-14: a FOODIVA_TO_CM line took an origin location (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-15
  -- ...and onto the destination as IN_TRANSIT, not as stock the chef house can use.
  select coalesce(sum(qty_delta), 0) into v_qty from stock_ledger
   where lot_id = v_lots[4] and location_id = v_chef and stock_state = 'IN_TRANSIT';
  assert v_qty = 40.00, format('TC-15: IN_TRANSIT at the destination is %s, not 40', v_qty);

  select coalesce(sum(qty_delta), 0) into v_qty from stock_ledger
   where lot_id = v_lots[4] and location_id = v_chef and stock_state in ('FROZEN', 'READY');
  assert v_qty = 0,
    format('TC-15: %s kg landed at the destination as usable stock before anyone signed for it', v_qty);

  --------------------------------------------------------------------------------- TC-16
  -- R21 / ADR-017. Named before the NOT NULL constraint can report a constraint name.
  v_ok := false; v_err := null;
  begin
    perform fn_dispatch_transport_line(gen_random_uuid(), v_run, null, null, null, v_chef, 40.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%LOT_REQUIRED%';
  end;
  assert v_ok, format('TC-16: a line was dispatched without naming its lot (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-17
  -- SEAM 2. The whole function, twice, on one key. A replay that skipped the line insert on
  -- its unique index and then posted the ledger rows again would leave 80 kg in IN_TRANSIT
  -- against a lot that can never balance.
  v_again := fn_dispatch_transport_line(v_key, v_run, v_lots[4], null, null, v_chef, 40.00);
  assert v_again = v_line,
    format('TC-17: the replay returned a different line (%s vs %s)', v_again, v_line);

  select count(*) into v_n from stock_ledger where lot_id = v_lots[4];
  assert v_n = v_ledger,
    format('TC-17: the replay posted %s ledger row(s) on top of %s', v_n - v_ledger, v_ledger);

  select coalesce(sum(qty_delta), 0) into v_qty from stock_ledger
   where lot_id = v_lots[4] and location_id = v_chef and stock_state = 'IN_TRANSIT';
  assert v_qty = 40.00, format('TC-17: IN_TRANSIT doubled to %s on a retry', v_qty);

  --------------------------------------------------------------------------------- TC-18
  -- Same key, different payload, is not a retry — it is a bug at the caller, and returning
  -- the first line silently would hide it.
  v_ok := false; v_err := null;
  begin
    perform fn_dispatch_transport_line(v_key, v_run, v_lots[4], null, null, v_chef, 50.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%LINE_IDEMPOTENCY_CONFLICT%';
  end;
  assert v_ok, format('TC-18: a key was reused for a different line (%s)',
                      coalesce(v_err, 'no exception at all'));

  select dispatched_weight_kg into v_qty from transport_lines where id = v_line;
  assert v_qty = 40.00, format('TC-18: the original line was moved to %s kg', v_qty);

  --------------------------------------------------------------------------------- TC-19
  -- Happy path receipt, signed by the CM operator the load is addressed to.
  v_line2 := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lots[6], null, null,
                                        v_chef, 40.00);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line2, date '2026-03-08', 40.00);

  select outstanding_weight_kg into v_qty from transport_lines where id = v_line2;
  assert v_qty = 0, format('TC-19: a fully received line still shows %s kg outstanding', v_qty);

  select coalesce(sum(qty_delta), 0) into v_qty from stock_ledger
   where lot_id = v_lots[6] and location_id = v_chef and stock_state = 'IN_TRANSIT';
  assert v_qty = 0, format('TC-19: %s kg is still on the truck after a full receipt', v_qty);

  select coalesce(sum(qty_delta), 0) into v_qty from stock_ledger
   where lot_id = v_lots[6] and location_id = v_chef and stock_state = 'FROZEN';
  assert v_qty = 40.00, format('TC-19: %s kg landed as FROZEN stock, not 40 (R14)', v_qty);

  --------------------------------------------------------------------------------- TC-20
  -- D06. A partial receipt is a fact, not an error, and the shortfall stays on the truck
  -- rather than being written off by arithmetic nobody chose.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_line2 := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lots[7], null, null,
                                        v_chef, 40.00);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line2, date '2026-03-08', 30.00,
                                       'รถมาถึงช้า ของขาด');

  select outstanding_weight_kg into v_qty from transport_lines where id = v_line2;
  assert v_qty = 10.00, format('TC-20: outstanding reads %s, not 10 (D06)', v_qty);

  select coalesce(sum(qty_delta), 0) into v_qty from stock_ledger
   where lot_id = v_lots[7] and location_id = v_chef and stock_state = 'IN_TRANSIT';
  assert v_qty = 10.00,
    format('TC-20: IN_TRANSIT reads %s — a partial receipt cleared the whole truck', v_qty);

  --------------------------------------------------------------------------------- TC-22
  -- UAT-11 / BR12. 25 kg against 40 is 37.5% off, past the 20% tolerance, and the toggle is
  -- on at this date.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_line2 := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lots[8], null, null,
                                        v_chef, 40.00);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_confirm_transport_receipt(gen_random_uuid(), v_line2, date '2026-03-08', 25.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%VARIANCE_REASON_REQUIRED%';
  end;
  assert v_ok, format('TC-22: a 37.5%% shortfall was signed off with no reason (%s)',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from transport_lines
   where id = v_line2 and received_weight_kg is not null;
  assert v_n = 0, 'TC-22: the refused receipt was written anyway';

  --------------------------------------------------------------------------------- TC-23
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line2, date '2026-03-08', 25.00,
                                       'ตาชั่งที่ต้นทางคลาดเคลื่อน');
  select variance_reason into v_txt from transport_lines where id = v_line2;
  assert v_txt = 'ตาชั่งที่ต้นทางคลาดเคลื่อน', format('TC-23: the reason was not stored (%s)', v_txt);

  select coalesce(sum(qty_delta), 0) into v_qty from stock_ledger
   where lot_id = v_lots[8] and location_id = v_chef and stock_state = 'FROZEN';
  assert v_qty = 25.00, format('TC-23: %s kg was posted in, not the 25 received', v_qty);

  --------------------------------------------------------------------------------- TC-24
  -- The toggle is the Owner's. From 2026-04-01 it is off, and the same shortfall goes
  -- through unexplained — which is a decision, recorded in config and dated.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_line2 := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lots[9], null, null,
                                        v_chef, 40.00);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line2, date '2026-04-08', 25.00);
  select received_weight_kg into v_qty from transport_lines where id = v_line2;
  assert v_qty = 25.00, 'TC-24: the receipt was refused with the reason toggle off';

  --------------------------------------------------------------------------------- TC-25
  -- partial_receipt_allowed goes false from 2026-05-01. A shortfall then has nowhere to go
  -- and the receipt is refused rather than silently leaving a balance nobody agreed to.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_line2 := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lots[10], null, null,
                                        v_chef, 40.00);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_confirm_transport_receipt(gen_random_uuid(), v_line2, date '2026-05-08', 30.00,
                                         'ของขาด');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%PARTIAL_RECEIPT_NOT_ALLOWED%';
  end;
  assert v_ok, format('TC-25: a shortfall was accepted with partial receipt switched off (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-26
  -- The role comes from the destination, not from an argument. A branch admin has no
  -- business signing for the chef house.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_confirm_transport_receipt(gen_random_uuid(), v_line2, date '2026-03-08', 40.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-26: an L2 signed for a CHEF_HOUSE load (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-27
  -- ...and not for another branch's, either. fn_require_branch asks membership as well as
  -- role, because an L3 also holds user_locations rows and an L2 at one branch is not an L2
  -- at every branch.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_run2 := fn_create_transport_run(gen_random_uuid(), 'CENTRAL_TO_BRANCH', date '2026-03-05',
                                    'รถกระบะ', false, 0);
  -- Stock has to exist at central before it can leave it, so this lot walks the whole chain:
  -- Foodiva -> chef house -> central -> branch. It is also the only end-to-end path in the
  -- suite, and BR11's "nothing reaches a branch without passing through central" is the
  -- reason it has to be walked rather than short-cut.
  v_line2 := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lots[11], null, null,
                                        v_chef, 40.00);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line2, date '2026-03-08', 40.00);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  update lots set state = 'RETURN_SCHEDULED' where id = v_lots[11];
  v_run3 := fn_create_transport_run(gen_random_uuid(), 'CM_TO_FOODIVA', date '2026-03-10',
                                    'รถห้องเย็น', false, 6000.00, array[v_lots[11]]);
  v_line2 := fn_dispatch_transport_line(gen_random_uuid(), v_run3, v_lots[11], null,
                                        v_chef, v_central, 40.00);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line2, date '2026-03-12', 40.00);

  v_line2 := fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lots[11], null,
                                        v_central, v_brB, 40.00);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_confirm_transport_receipt(gen_random_uuid(), v_line2, date '2026-03-14', 40.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-27: the L2 of มีนบุรี signed for ศาลาแดง''s load (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-28
  -- Over-delivery. The truck brought more than the note said; refusing to record it does not
  -- send it back. The truck is cleared of what went onto it and the surplus arrives as an
  -- ADJUSTMENT, because no transfer accounts for it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_line2 := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lots[12], null, null,
                                        v_chef, 40.00);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_line2, date '2026-03-08', 45.00,
                                       'ได้รับเกินใบส่งของ');

  select coalesce(sum(qty_delta), 0) into v_qty from stock_ledger
   where lot_id = v_lots[12] and location_id = v_chef and stock_state = 'IN_TRANSIT';
  assert v_qty = 0, format('TC-28: IN_TRANSIT reads %s after an over-delivery, not 0', v_qty);

  select coalesce(sum(qty_delta), 0) into v_qty from stock_ledger
   where lot_id = v_lots[12] and location_id = v_chef and stock_state = 'FROZEN';
  assert v_qty = 45.00, format('TC-28: %s kg landed on the shelf, not the 45 received', v_qty);

  select count(*) into v_n from stock_ledger
   where lot_id = v_lots[12] and movement_type = 'ADJUSTMENT' and qty_delta = 5.00;
  assert v_n = 1, 'TC-28: the 5 kg surplus was posted as a transfer, not as an ADJUSTMENT';

  --------------------------------------------------------------------------------- TC-29
  -- SEAM 3. 100 THB across three 1 kg lines is 33.33 three times and 99.99 in total. R24
  -- says it sums back to the fare to the satang, and the remainder lands on the largest
  -- line — here a three-way tie, broken by the smallest id so a recompute cannot move it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_run2 := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', date '2026-03-05',
                                    'มอเตอร์ไซค์', false, 100.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lots[13], null, null, v_chef, 1.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lots[14], null, null, v_chef, 1.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lots[15], null, null, v_chef, 1.00);

  perform fn_allocate_freight(gen_random_uuid(), v_run2);
  select coalesce(sum(freight_share_thb), 0) into v_sum
    from transport_lines where run_id = v_run2;
  assert v_sum = 100.00, format('TC-29: three shares sum to %s, not 100.00 (R24)', v_sum);

  select count(*) into v_n from transport_lines
   where run_id = v_run2 and freight_share_thb = 33.34;
  assert v_n = 1, format('TC-29: %s line(s) carry the extra satang, expected exactly 1', v_n);

  --------------------------------------------------------------------------------- TC-30
  -- Deterministic on a recompute. A tiebreak that depended on row order would move a satang
  -- between two lots every time the fare was re-allocated, which is a lot cost that changes
  -- when nobody changed anything.
  select freight_share_thb into v_share1 from transport_lines
   where run_id = v_run2 order by dispatched_weight_kg desc, id limit 1;
  perform fn_allocate_freight(gen_random_uuid(), v_run2);
  select freight_share_thb into v_share2 from transport_lines
   where run_id = v_run2 order by dispatched_weight_kg desc, id limit 1;
  assert v_share1 = v_share2,
    format('TC-30: the satang moved between runs of the same allocation (%s then %s)',
           v_share1, v_share2);

  select coalesce(sum(freight_share_thb), 0) into v_sum
    from transport_lines where run_id = v_run2;
  assert v_sum = 100.00, format('TC-30: re-allocating drifted the total to %s', v_sum);

  --------------------------------------------------------------------------------- TC-31
  -- EQUAL_SPLIT, from the config row dated 2026-06-01. Equal shares still put the remainder
  -- on the largest line by weight — that is the honest place for a satang even when the
  -- split ignored weight.
  v_run2 := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', date '2026-06-05',
                                    'รถกระบะ', false, 100.00);
  select alloc_method into v_method from transport_runs where id = v_run2;
  assert v_method = 'EQUAL_SPLIT',
    format('TC-31: the run snapshotted %s, not the EQUAL_SPLIT dated 2026-06-01', v_method);

  perform fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lots[13], null, null, v_chef, 40.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lots[14], null, null, v_chef, 35.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lots[15], null, null, v_chef, 25.00);
  perform fn_allocate_freight(gen_random_uuid(), v_run2);

  select coalesce(sum(freight_share_thb), 0) into v_sum
    from transport_lines where run_id = v_run2;
  assert v_sum = 100.00, format('TC-31: EQUAL_SPLIT shares sum to %s, not 100.00', v_sum);

  select freight_share_thb into v_share1 from transport_lines
   where run_id = v_run2 and dispatched_weight_kg = 40.00;
  assert v_share1 = 33.34,
    format('TC-31: the 40 kg line carries %s — the remainder is not on the largest line', v_share1);

  --------------------------------------------------------------------------------- TC-32
  -- MANUAL refuses. Falling through to the automatic path would produce a BY_LOT_WEIGHT
  -- split wearing a MANUAL label, and nothing on any screen would say which it was.
  v_run2 := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', date '2026-07-05',
                                    'รถกระบะ', false, 100.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lots[16], null, null, v_chef, 10.00);
  v_ok := false; v_err := null;
  begin
    perform fn_allocate_freight(gen_random_uuid(), v_run2);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%MANUAL_ALLOC_NOT_AUTOMATIC%';
  end;
  assert v_ok, format('TC-32: a MANUAL run was split automatically (%s)',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from transport_lines
   where run_id = v_run2 and freight_share_thb is not null;
  assert v_n = 0, format('TC-32: %s share(s) were written on a MANUAL run', v_n);

  --------------------------------------------------------------------------------- TC-33
  -- Zero is the correct fare on the branch leg (R25), so allocating it is a quiet no-op and
  -- the shares stay null rather than becoming a row of honest-looking zeroes.
  v_run2 := fn_create_transport_run(gen_random_uuid(), 'CENTRAL_TO_BRANCH', date '2026-03-05',
                                    'รถกระบะ', false, 0);
  v_qty := fn_allocate_freight(gen_random_uuid(), v_run2);
  assert v_qty = 0, format('TC-33: the branch leg reconciled to %s, not 0 (R25)', v_qty);

  --------------------------------------------------------------------------------- TC-34
  -- ...and the same 0 anywhere else means nobody typed the fare in. Allocating it would
  -- write 0.00 on every line, sum back to 0.00, and pass R24 while being wrong (Finding 6).
  v_run2 := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', date '2026-03-05',
                                    'รถกระบะ', false, 0);
  v_ok := false; v_err := null;
  begin
    perform fn_allocate_freight(gen_random_uuid(), v_run2);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%RUN_FARE_NOT_SET%';
  end;
  assert v_ok, format('TC-34: a fare-less FOODIVA_TO_CM run allocated cleanly (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-36
  -- BR16 / D04.1: a round trip is charged once. One run row holds one fare, and nothing in
  -- fn_allocate_freight doubles or halves it. A return leg that is genuinely a second
  -- vehicle is a second run with a second fare, and that is two charges because two
  -- vehicles went.
  v_run2 := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', date '2026-03-05',
                                    'รถห้องเย็น', true, 4500.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lots[13], null, null, v_chef, 30.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lots[14], null, null, v_chef, 20.00);
  perform fn_allocate_freight(gen_random_uuid(), v_run2);
  select coalesce(sum(freight_share_thb), 0) into v_sum
    from transport_lines where run_id = v_run2;
  assert v_sum = 4500.00,
    format('TC-36: a round trip was charged %s against a 4500 fare (BR16)', v_sum);

  --------------------------------------------------------------------------------- TC-06
  -- R29 / BR23, last, because it changes what a date resolves to and nothing may run after
  -- it. The run keeps the method it was created with even once config says otherwise: a
  -- later config row never moves a closed number.
  v_run2 := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', date '2026-09-05',
                                    'รถกระบะ', false, 4500.00);
  select alloc_method into v_method from transport_runs where id = v_run2;
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', date '2026-09-01',
                        p_value_text => 'EQUAL_SPLIT');
  select alloc_method into v_method2 from transport_runs where id = v_run2;
  assert v_method = v_method2,
    format('TC-06: a config change moved a closed run from %s to %s (R29)', v_method, v_method2);
  assert (fn_config_value('freight_alloc_method', date '2026-09-05')).value_text = 'EQUAL_SPLIT',
    'TC-06: the config change did not take, so the snapshot proved nothing';

  --------------------------------------------------------------------------------- TC-39
  -- The outstanding view ages a line off migration ...0010's created_at. Before that column
  -- there was no clock on the line at all and BR12's alert had nothing to fire against.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*), min(age_days) into v_n, v_age
    from v_outstanding_receipts where lot_id = v_lots[4];
  assert v_n = 1, format('TC-39: the never-received line appears %s time(s) as outstanding', v_n);
  assert v_age = 0, format('TC-39: a line dispatched moments ago is %s days old', v_age);

  -- The partially received line is outstanding too, and it is the one D06 exists for.
  select count(*) into v_n from v_outstanding_receipts where lot_id = v_lots[7];
  assert v_n = 1, 'TC-39: a partial receipt with 10 kg still on the truck reads as settled';

  -- ...and a fully received one is not.
  select count(*) into v_n from v_outstanding_receipts where lot_id = v_lots[6];
  assert v_n = 0, 'TC-39: a fully received line is still listed as outstanding';

  --------------------------------------------------------------------------------- TC-37
  -- R34: the role test is in the WHERE, so a role that may not see a subject gets zero rows
  -- from the database rather than a hidden nav item.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  select count(*) into v_n from v_transport_variance where to_location_id = v_chef;
  assert v_n = 0, format('TC-37: the L2 of มีนบุรี reads %s chef-house line(s)', v_n);

  select count(*) into v_n from v_freight_allocation;
  assert v_n = 0, format('TC-37: an L2 session read %s row(s) of freight money (R20)', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  select count(*) into v_n from v_freight_allocation;
  assert v_n = 0, format('TC-37: an L3 session read %s row(s) of freight money (R20)', v_n);

  select count(*) into v_n from v_outstanding_receipts;
  assert v_n = 0, format('TC-37: an L3 session read %s outstanding-receipt row(s)', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_freight_allocation where run_id is not null;
  assert v_n > 0, 'TC-37: the Owner reads no freight allocation at all — the WHERE is too tight';

  --------------------------------------------------------------------------------- TC-40
  -- The tables stay deny-all. Reads arrive through the three views and writes through the
  -- four functions; a screen that works around either gets permission denied (ADR-002,
  -- ADR-004). rls_deny_all_test.sql sweeps the same ground for every table at once.
  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name in ('transport_runs', 'transport_lines')
     and grantee in ('anon', 'authenticated');
  assert v_n = 0, format('TC-40: %s grant(s) leaked onto the transport tables', v_n);

  select count(*) into v_n
    from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public'
     and c.relname in ('transport_runs', 'transport_lines')
     and c.relrowsecurity;
  assert v_n = 2, format('TC-40: RLS is off on %s of the 2 transport tables', 2 - v_n);

  ---------------------------------------------------------------- the uniform RPC contract
  -- A null idempotency key is refused everywhere, so the TypeScript wrapper shape is the
  -- same for every write in the system (ADR-005).
  v_ok := false; v_err := null;
  begin
    perform fn_create_transport_run(null, 'FOODIVA_TO_CM', date '2026-03-05', 'รถกระบะ', false, 100.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%IDEMPOTENCY_KEY_REQUIRED%';
  end;
  assert v_ok, format('R4: fn_create_transport_run accepted a null key (%s)', coalesce(v_err, 'none'));

  v_ok := false; v_err := null;
  begin
    perform fn_dispatch_transport_line(null, v_run, v_lots[4], null, null, v_chef, 1.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%IDEMPOTENCY_KEY_REQUIRED%';
  end;
  assert v_ok, format('R4: fn_dispatch_transport_line accepted a null key (%s)', coalesce(v_err, 'none'));

  v_ok := false; v_err := null;
  begin
    perform fn_confirm_transport_receipt(null, v_line, date '2026-03-08', 1.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%IDEMPOTENCY_KEY_REQUIRED%';
  end;
  assert v_ok, format('R4: fn_confirm_transport_receipt accepted a null key (%s)', coalesce(v_err, 'none'));

  v_ok := false; v_err := null;
  begin
    perform fn_allocate_freight(null, v_run);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%IDEMPOTENCY_KEY_REQUIRED%';
  end;
  assert v_ok, format('R4: fn_allocate_freight accepted a null key (%s)', coalesce(v_err, 'none'));

  raise exception 'TRANSPORT_TEST_PASSED';   -- the only clean way back out
end $$;
