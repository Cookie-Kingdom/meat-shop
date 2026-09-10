-- Failure-case tests for card ^ref-20 — the three OW 01 read views (lane F, 10 Sep 2026).
--
-- Assumes no unmerged lane's contract: fn_create_po and fn_add_po_delivery are ^ref-19's,
-- already on develop. WRITTEN, NOT RUN on 10 Sep (PARALLEL-LANES.md) — the Owner's final
-- pass is its first run.
--
-- The screen writes nothing of its own; both writes are ^ref-19's functions and are
-- covered by purchasing_test.sql. What can go wrong here is the READ, and each assert is a
-- way OW 01 ships looking right and being wrong:
--
--   * an L2 or L3 who types the URL reads a price, because the gate was the nav (TC-S02,
--     R20, ADR-004) — and "deny everyone" passes that vacuously, so TC-S01/S03/S05 prove L1
--     reads real rows
--   * the supplier picker offers a supplier fn_create_po will refuse (TC-S01)
--   * a PO delivered in two rounds shows one lot, or a lot whose code does not name its
--     round (TC-S03, D01, UAT-01)
--   * a price column drifts onto the round list, which OW 02 also reads (TC-S04)
--   * the register computes sent/outstanding a second way and disagrees with
--     v_po_outstanding (TC-S06), or rounds a total the way a float would (TC-S07)
--   * a PO saved without a price shows a total of 0.00 (TC-S05)
--   * the view is readable by anon, or not by authenticated (TC-S08)
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/purchasing_screen_test.sql

do $$
declare
  v_owner     uuid := 'f2000000-0000-0000-0000-0000000000a1';
  v_l2        uuid := 'f2000000-0000-0000-0000-0000000000a2';
  v_l3        uuid := 'f2000000-0000-0000-0000-0000000000a3';
  v_chef      uuid;
  v_branch    uuid;
  v_sup       uuid;
  v_gone      uuid;
  v_po        uuid;
  v_po2       uuid;
  v_po3       uuid;
  v_lot1      uuid;
  v_lot2      uuid;
  v_id        uuid;
  v_po_number text;
  v_txt       text;
  v_n         bigint;
  v_n2        bigint;
  v_kg        numeric;
  v_kg2       numeric;
  v_thb       numeric;
  v_thb2      numeric;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',                 'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',              'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',      'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind) values ('CH-F20', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('BR-F20', 'สาขาทดสอบ', 'BRANCH')
    returning id into v_branch;
  insert into user_locations (profile_id, location_id) values (v_l2, v_branch), (v_l3, v_chef);

  insert into suppliers (name, is_active) values ('ฟู้ดดีว่า', true)        returning id into v_sup;
  insert into suppliers (name, is_active) values ('ผู้ขายที่เลิกใช้', false) returning id into v_gone;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  -- UAT-01's worked case: 100 kg ordered, 40 then 30 sent.
  v_po   := fn_create_po(gen_random_uuid(), v_sup, date '2026-09-01', 100.00, 250.00, 10.00, 500.00);
  v_lot1 := fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-09-02', 40.00, v_chef);
  v_lot2 := fn_add_po_delivery(gen_random_uuid(), v_po, date '2026-09-03', 30.00, v_chef);
  select po_number into v_po_number from purchase_orders where id = v_po;

  -- A PO with no price and no brine offer: every money argument left at its default.
  v_po2  := fn_create_po(gen_random_uuid(), v_sup, date '2026-09-04', 50.00);

  -- A PO whose total is not a round number, for TC-S07.
  v_po3  := fn_create_po(gen_random_uuid(), v_sup, date '2026-09-05', 33.33, 99.99, 10.50);

  -------------------------------------------------------------------------------- TC-S01
  -- The picker offers the active supplier and not the retired one, which fn_create_po would
  -- refuse with SUPPLIER_INACTIVE.
  select count(*) into v_n from v_supplier_options where id = v_sup;
  assert v_n = 1, format('TC-S01: L1 reads %s row(s) for the active supplier', v_n);
  select count(*) into v_n from v_supplier_options where id = v_gone;
  assert v_n = 0, 'TC-S01: the picker offers an inactive supplier';

  -------------------------------------------------------------------------------- TC-S02
  -- R20 / R34 / ADR-004. The (owner) layout 403s these roles first, but that is the mirror:
  -- the database has to give them nothing on its own.
  foreach v_id in array array[v_l2, v_l3] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
    select (select count(*) from v_supplier_options)
         + (select count(*) from v_po_rounds)
         + (select count(*) from v_po_register)
      into v_n;
    assert v_n = 0,
      format('TC-S02: %s reads %s row(s) of the OW 01 views (R20, R34)',
             (select role from profiles where id = v_id), v_n);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  -------------------------------------------------------------------------------- TC-S03
  -- D01. Two rounds are two lots, each code naming its round, each carrying its own weight.
  select count(*) into v_n from v_po_rounds where po_id = v_po;
  assert v_n = 2, format('TC-S03: a PO of two rounds lists %s', v_n);

  select lot_code into v_txt from v_po_rounds where lot_id = v_lot1;
  assert v_txt = v_po_number || '-1', format('TC-S03: round 1 shows lot %s', v_txt);
  select lot_code into v_txt from v_po_rounds where lot_id = v_lot2;
  assert v_txt = v_po_number || '-2', format('TC-S03: round 2 shows lot %s', v_txt);

  select foodiva_sent_weight_kg into v_kg  from v_po_rounds where lot_id = v_lot1;
  select foodiva_sent_weight_kg into v_kg2 from v_po_rounds where lot_id = v_lot2;
  assert v_kg = 40.00 and v_kg2 = 30.00,
    format('TC-S03: the rounds read %s and %s kg, not 40 and 30', v_kg, v_kg2);

  -- Both wait for a truck at the chef house the round named — what OW 02's picker filters on.
  select count(*) into v_n from v_po_rounds
   where po_id = v_po and lot_state = 'PO_CREATED'
     and chef_house_location_id = v_chef and chef_house_name = 'โรงรมเชียงใหม่';
  assert v_n = 2, format('TC-S03: %s of 2 rounds read PO_CREATED at the named chef house', v_n);

  -------------------------------------------------------------------------------- TC-S04
  -- OW 02 reads v_po_rounds too. No money reaches it, now or after a later edit.
  select string_agg(table_name || '.' || column_name, ', ') into v_txt
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('v_po_rounds', 'v_supplier_options')
     and (column_name like '%price%' or column_name like '%cost%'
       or column_name like '%thb%'   or column_name like '%brine%');
  assert v_txt is null, format('TC-S04: a money column is on a non-money view: %s', v_txt);

  -------------------------------------------------------------------------------- TC-S05
  -- F4 clauses 1-2 and UAT-01, read back from what was saved.
  select dispatched_weight_kg, outstanding_weight_kg, meat_total_thb, brine_offered_kg,
         brine_cost_thb, round_count
    into v_kg, v_kg2, v_thb, v_n2, v_thb2, v_n
    from v_po_register where po_id = v_po;
  assert v_kg = 70.00 and v_kg2 = 30.00,
    format('TC-S05: sent %s / outstanding %s, not 70 / 30 (UAT-01)', v_kg, v_kg2);
  assert v_thb = 25000.00, format('TC-S05: 100 kg x 250.00 reads %s', v_thb);
  assert v_n2 = 10 and v_thb2 = 500.00 and v_n = 2,
    format('TC-S05: brine %s kg / cost %s / rounds %s', v_n2, v_thb2, v_n);

  -- Null in, null out. A PO saved without a price has no total — 0.00 would read as "free".
  select meat_total_thb, brine_offered_kg, dispatched_weight_kg, outstanding_weight_kg
    into v_thb, v_kg, v_kg2, v_thb2
    from v_po_register where po_id = v_po2;
  assert v_thb is null and v_kg is null,
    format('TC-S05: a PO with no price reads total %s, brine %s', v_thb, v_kg);
  assert v_kg2 = 0.00 and v_thb2 = 50.00,
    format('TC-S05: a PO with no round reads sent %s / outstanding %s', v_kg2, v_thb2);

  -------------------------------------------------------------------------------- TC-S06
  -- One derivation of sent/outstanding, not two (D01, ADR-003).
  select count(*) into v_n
    from v_po_register r
    join v_po_outstanding o using (po_id)
   where r.ordered_weight_kg     <> o.ordered_weight_kg
      or r.dispatched_weight_kg  <> o.dispatched_weight_kg
      or r.outstanding_weight_kg <> o.outstanding_weight_kg
      or r.round_count           <> o.round_count;
  assert v_n = 0, format('TC-S06: %s PO(s) disagree with v_po_outstanding', v_n);
  select count(*) into v_n  from v_po_register;
  select count(*) into v_n2 from v_po_outstanding;
  assert v_n = v_n2, format('TC-S06: the register lists %s POs, v_po_outstanding %s', v_n, v_n2);

  -------------------------------------------------------------------------------- TC-S07
  -- numeric rounding, to the satang. 33.33 x 99.99 = 3332.6667 -> 3332.67; 33.33 x 10.50 / 100
  -- = 3.49965 -> 3.50. A float gets the second one wrong at the half.
  select meat_total_thb, brine_offered_kg into v_thb, v_kg from v_po_register where po_id = v_po3;
  assert v_thb = 3332.67 and v_kg = 3.50,
    format('TC-S07: 33.33 kg at 99.99 reads %s THB and %s kg brine', v_thb, v_kg);

  -------------------------------------------------------------------------------- TC-S08
  -- The grant shape ^ref-64 fixed: SELECT to authenticated, nothing to anon, on all three.
  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name in ('v_supplier_options', 'v_po_rounds', 'v_po_register')
     and grantee = 'authenticated' and privilege_type = 'SELECT';
  assert v_n = 3, format('TC-S08: authenticated holds SELECT on %s of the 3 views', v_n);

  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name in ('v_supplier_options', 'v_po_rounds', 'v_po_register')
     and grantee = 'anon';
  assert v_n = 0, format('TC-S08: anon holds %s grant(s) on the OW 01 views', v_n);

  raise exception 'PURCHASING_SCREEN_TEST_PASSED';   -- the only clean way back out
end $$;
