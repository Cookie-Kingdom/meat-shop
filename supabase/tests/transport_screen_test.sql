-- Failure-case tests for card ^ref-24 — v_transport_runs, OW 02's retry contract, and
-- TC-42 automated (lane F, 10 Sep 2026).
--
-- Assumes no unmerged lane's contract: every function called is on develop (^ref-19,
-- ^ref-22, ^ref-23, ^ref-35). WRITTEN, NOT RUN on 10 Sep (PARALLEL-LANES.md) — the Owner's
-- final pass is its first run.
--
-- OW 02 writes nothing of its own. It sequences four existing functions, so what can go
-- wrong is the sequence and the read. Each assert is a way it ships looking right and being
-- wrong:
--
--   * a run whose first dispatch failed is invisible, and its fare sits unallocated where
--     nobody can see it (TC-S10)
--   * the screen's retry — every step keyed off ONE form key, md5(form:run),
--     md5(form:line:<lot>), md5(form:alloc) — books a second run or a second IN_TRANSIT row
--     instead of replaying (TC-S13, R4, Seam 2)
--   * the UAT-06 worked case splits differently from what OW 02 previewed (TC-S11)
--   * an L2 or L3 reads a fare (TC-S12, R20, R34)
--   * clause 1 of ^ref-24: the two views OW 02 renders do not carry the lines (TC-S14)
--   * TC-42: the reason rule is a disabled button and not the database. An L1 on a CENTRAL
--     line, the only line OW 02 lets the Owner sign for, is refused without a reason
--     (TC-42b) — the Owner is not exempt — and an L1 on a CHEF_HOUSE line is refused
--     outright (TC-42a), which is why OW 02 offers no button there
--   * the screen's live mirror uses a different boundary from fn_check_variance, so the
--     reason turns required at 20.00% on screen and the database accepts it (TC-S15)
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/transport_screen_test.sql

do $$
declare
  v_owner   uuid := 'f2400000-0000-0000-0000-0000000000b1';
  v_l2      uuid := 'f2400000-0000-0000-0000-0000000000b2';
  v_l3      uuid := 'f2400000-0000-0000-0000-0000000000b3';
  v_form    uuid := 'f2400000-0000-0000-0000-00000000f0f0';   -- the OW 02 form key
  v_chef    uuid;
  v_central uuid;
  v_branch  uuid;
  v_sup     uuid;
  v_po      uuid;
  v_lotA    uuid;
  v_lotB    uuid;
  v_lotR    uuid;
  v_lotR2   uuid;
  v_run     uuid;
  v_runR    uuid;
  v_line    uuid;
  v_line2   uuid;
  v_lineR   uuid;
  v_lineR2  uuid;
  v_k_run   uuid;
  v_k_a     uuid;
  v_id      uuid;
  v_n       bigint;
  v_kg      numeric;
  v_thb     numeric;
  v_thb2    numeric;
  v_bool    boolean;
  v_ok      boolean;
  v_err     text;
  v_txt     text;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',                 'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',              'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',      'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind) values ('CH-F24', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('CEN-F24', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  insert into locations (code, name_th, kind) values ('BR-F24', 'สาขาทดสอบ', 'BRANCH')
    returning id into v_branch;
  insert into user_locations (profile_id, location_id) values (v_l2, v_branch), (v_l3, v_chef);
  insert into suppliers (name, is_active) values ('Foodiva', true) returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  -- Every key OW 02's functions read, dated (ADR-006).
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', date '2026-01-01',
                        p_value_text => 'BY_LOT_WEIGHT');
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', date '2026-01-01',
                        p_value_text => 'true');

  v_po    := fn_create_po(gen_random_uuid(), v_sup, date '2026-09-01', 500.00, 250.00);
  v_lotA  := fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-09-02', 60.00, v_chef);
  v_lotB  := fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-09-02', 40.00, v_chef);
  v_lotR  := fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-09-02', 40.00, v_chef);
  v_lotR2 := fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-09-02', 40.00, v_chef);

  -------------------------------------------------------------------------------- TC-S10
  -- The run OW 02 creates first, before any lot is on it.
  v_k_run := md5(v_form::text || ':run')::uuid;
  v_run := fn_create_transport_run(v_k_run, 'FOODIVA_TO_CM', date '2026-09-05',
                                   'รถกระบะ', false, 1000.00);

  select line_count, fare_reconciles_to_satang, dispatched_weight_kg
    into v_n, v_bool, v_kg
    from v_transport_runs where run_id = v_run;
  assert v_n = 0 and v_bool = false and v_kg = 0.00,
    format('TC-S10: a run with no lines reads %s line(s), reconciles %s, %s kg', v_n, v_bool, v_kg);

  -- The reason 252 exists: the per-line view cannot show it.
  select count(*) into v_n from v_freight_allocation where run_id = v_run;
  assert v_n = 0, format('TC-S10: v_freight_allocation shows %s row(s) for a run with no lines', v_n);

  -------------------------------------------------------------------------------- TC-S13
  -- The retry contract (PLAN-transport.md ^ref-24 build notes, Finding 5). The action
  -- derives every step's key from the one form key, so running the whole booking again
  -- after a dropped connection replays each step rather than repeating it.
  v_k_a  := md5(v_form::text || ':line:' || v_lotA::text)::uuid;
  v_line := fn_dispatch_transport_line(v_k_a, v_run, v_lotA, null, null, v_chef, 60.00);

  v_id := fn_create_transport_run(v_k_run, 'FOODIVA_TO_CM', date '2026-09-05',
                                  'รถกระบะ', false, 1000.00);
  assert v_id = v_run, format('TC-S13: the replayed run is %s, not %s', v_id, v_run);
  v_id := fn_dispatch_transport_line(v_k_a, v_run, v_lotA, null, null, v_chef, 60.00);
  assert v_id = v_line, format('TC-S13: the replayed line is %s, not %s', v_id, v_line);

  select coalesce(sum(qty_delta), 0) into v_kg from stock_ledger
   where lot_id = v_lotA and location_id = v_chef and stock_state = 'IN_TRANSIT';
  assert v_kg = 60.00, format('TC-S13: IN_TRANSIT reads %s kg after a replay, not 60', v_kg);
  select count(*) into v_n from transport_runs where idempotency_key = v_k_run;
  assert v_n = 1, format('TC-S13: %s run(s) carry the form''s run key', v_n);

  v_line2 := fn_dispatch_transport_line(md5(v_form::text || ':line:' || v_lotB::text)::uuid,
                                        v_run, v_lotB, null, null, v_chef, 40.00);

  -------------------------------------------------------------------------------- TC-S11
  -- UAT-06's worked case through OW 02's path: 1,000.00 over 60/40 kg is 600.00 / 400.00,
  -- and the run-level reconciliation flips only when the shares are written.
  select fare_reconciles_to_satang into v_bool from v_transport_runs where run_id = v_run;
  assert v_bool = false, 'TC-S11: an unallocated fare already reads as reconciled';

  perform fn_allocate_freight(md5(v_form::text || ':alloc')::uuid, v_run);

  select freight_share_thb into v_thb  from v_freight_allocation where line_id = v_line;
  select freight_share_thb into v_thb2 from v_freight_allocation where line_id = v_line2;
  assert v_thb = 600.00 and v_thb2 = 400.00,
    format('TC-S11: 1,000.00 over 60/40 kg split %s / %s (UAT-06)', v_thb, v_thb2);

  select line_count, dispatched_weight_kg, allocated_thb, fare_reconciles_to_satang
    into v_n, v_kg, v_thb, v_bool
    from v_transport_runs where run_id = v_run;
  assert v_n = 2 and v_kg = 100.00 and v_thb = 1000.00 and v_bool,
    format('TC-S11: the run reads %s line(s), %s kg, %s allocated, reconciles %s',
           v_n, v_kg, v_thb, v_bool);

  -- Both lots left the "waiting for a truck" state OW 02's picker lists.
  select count(*) into v_n from v_po_rounds
   where lot_id in (v_lotA, v_lotB) and lot_state = 'IN_TRANSIT';
  assert v_n = 2, format('TC-S11: %s of 2 dispatched lots read IN_TRANSIT', v_n);

  -------------------------------------------------------------------------------- TC-S12
  -- R20 / R34. A fare is money; L2 and L3 read nothing from the database.
  foreach v_id in array array[v_l2, v_l3] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
    select count(*) into v_n from v_transport_runs;
    assert v_n = 0,
      format('TC-S12: %s reads %s row(s) of v_transport_runs',
             (select role from profiles where id = v_id), v_n);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'v_transport_runs'
     and grantee = 'anon';
  assert v_n = 0, format('TC-S12: anon holds %s grant(s) on v_transport_runs', v_n);

  -------------------------------------------------------------------------------- TC-S14
  -- ^ref-24 clause 1, at the database: both lines are outstanding and both carry a
  -- variance row, for the role OW 02 renders them to.
  select count(*) into v_n from v_outstanding_receipts where run_id = v_run;
  assert v_n = 2, format('TC-S14: v_outstanding_receipts lists %s of the run''s 2 lines', v_n);
  select count(*) into v_n from v_transport_variance where run_id = v_run;
  assert v_n = 2, format('TC-S14: v_transport_variance lists %s of the run''s 2 lines', v_n);

  -------------------------------------------------------------------------------- TC-42a
  -- The Owner cannot sign for the chef house. OW 02 therefore shows "รอเชียงใหม่ยืนยันรับ"
  -- on these rows and no button — a button here would be a refusal waiting to happen.
  v_ok := false; v_err := null;
  begin
    perform fn_confirm_transport_receipt(gen_random_uuid(), v_line, date '2026-09-06', 60.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('TC-42a: an L1 signed for a CHEF_HOUSE line (%s)',
                      coalesce(v_err, 'no exception at all'));

  ------------------------------------------------------------------ the CENTRAL fixture
  -- Two lots on a return leg into central: the only line OW 02 lets the Owner sign for.
  -- Closing and scheduling are not under test, so the state is set directly (the same
  -- shortcut movement_test.sql takes for IN_TRANSIT), and the chef house is given the
  -- FROZEN stock the return dispatch draws down.
  update lots set state = 'RETURN_SCHEDULED', return_pickup_date = date '2026-09-08'
   where id in (v_lotR, v_lotR2);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 'FROZEN', 'TRANSFER_IN',
                         40.00, date '2026-09-07', p_lot_id => v_lotR);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 'FROZEN', 'TRANSFER_IN',
                         40.00, date '2026-09-07', p_lot_id => v_lotR2);

  v_runR   := fn_create_transport_run(gen_random_uuid(), 'CM_TO_FOODIVA', date '2026-09-08',
                                      p_run_cost_thb => 1500.00,
                                      p_lot_ids => array[v_lotR, v_lotR2]);
  v_lineR  := fn_dispatch_transport_line(gen_random_uuid(), v_runR, v_lotR,  null, v_chef,
                                         v_central, 40.00);
  v_lineR2 := fn_dispatch_transport_line(gen_random_uuid(), v_runR, v_lotR2, null, v_chef,
                                         v_central, 40.00);

  -------------------------------------------------------------------------------- TC-42b
  -- TC-42, automated. 25 kg against 40 is 37.50% off, past 20.00, with the toggle on. The
  -- Owner calls the RPC directly — no screen, no disabled button — and is refused.
  v_ok := false; v_err := null;
  begin
    perform fn_confirm_transport_receipt(gen_random_uuid(), v_lineR, date '2026-09-09', 25.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'VARIANCE_REASON_REQUIRED:%';
  end;
  assert v_ok, format('TC-42b: an L1 signed off a 37.50%% shortfall with no reason (%s)',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from transport_lines
   where id = v_lineR and received_weight_kg is not null;
  assert v_n = 0, 'TC-42b: the refused receipt was written anyway';

  -- A blank reason is no reason: the function trims.
  v_ok := false; v_err := null;
  begin
    perform fn_confirm_transport_receipt(gen_random_uuid(), v_lineR, date '2026-09-09', 25.00, '   ');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'VARIANCE_REASON_REQUIRED:%';
  end;
  assert v_ok, format('TC-42b: a whitespace reason was accepted (%s)', coalesce(v_err, 'no exception at all'));

  -- With a reason it is recorded — ALERT, not BLOCK: the receipt is a fact (UAT-11).
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_lineR, date '2026-09-09', 25.00,
                                       'ถุงแตกระหว่างทาง');
  select variance_reason into v_txt from transport_lines where id = v_lineR;
  assert v_txt = 'ถุงแตกระหว่างทาง', format('TC-42b: the reason was stored as %s', v_txt);
  select state::text into v_txt from lots where id = v_lotR;
  assert v_txt = 'CENTRAL_STOCK', format('TC-42b: the received return lot reads %s', v_txt);

  -------------------------------------------------------------------------------- TC-S15
  -- The live mirror's boundary is fn_check_variance's: 32 against 40 is exactly 20.00%,
  -- which is WITHIN (`<=`). The screen leaves the reason optional there, and the database
  -- must agree by accepting it without one.
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_lineR2, date '2026-09-09', 32.00);
  select received_weight_kg into v_kg from transport_lines where id = v_lineR2;
  assert v_kg = 32.00, format('TC-S15: 20.00%% exactly was refused or mis-recorded (%s)', v_kg);

  raise exception 'TRANSPORT_SCREEN_TEST_PASSED';   -- the only clean way back out
end $$;
