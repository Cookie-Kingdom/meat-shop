-- Failure-case tests for card ^ref-44: fn_record_waste.
--
-- Contracts assumed from an unmerged lane (lane B, ^ref-40):
--   * fn_require_branch_or_owner(uuid) -> uuid, per PLAN-thaw.md T3;
--   * fn_record_thaw(p_idempotency_key, p_daily_report_id, p_lot_id, p_smoke_date_group_id,
--     p_thawed_weight_kg, p_fifo_override_reason) -> json, per PLAN-thaw.md T5, posting THAW_IN
--     on (SMOKED_MEAT, product NULL, lot, group, branch, READY).
--
-- Covers TC-32 ... TC-37 of TDD-sales.md, with TC-32 read through PLAN-sales.md B1 (L1 may
-- write off at any branch). Added cases:
--   * the card's acceptance line: leftover thawed meat written off leaves READY at zero, with
--     FROZEN untouched;
--   * B15's refusals: WASTE_ITEM_TYPE_INVALID, WASTE_STATE_INVALID, WASTE_QTY_INVALID,
--     PRODUCT_AMBIGUOUS;
--   * B2's replay after close.
--
-- Each assert catches a way this function fails silently:
--   * a write-off lands on the wrong tuple because the state was defaulted rather than stated
--   * an unexplained write-off, the one an audit finds (BR19)
--   * an over-waste leaves a waste row behind with no ledger movement to match it
--   * chilli is written off against a product no sale draws from
--   * a replay writes the row twice, or a retry after the close reads REPORT_CLOSED (R4)
--
-- Errors are captured into v_err and asserted after the block (see branch_daily_test.sql).
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/waste_test.sql

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_adm_a  uuid := gen_random_uuid();
  v_adm_b  uuid := gen_random_uuid();
  v_cm     uuid := gen_random_uuid();
  v_day    date := date '2026-05-04';
  v_bra    uuid;
  v_brb    uuid;
  v_lotA   uuid;
  v_lotB   uuid;
  v_gA     uuid;
  v_gB     uuid;
  v_rep    uuid;
  v_chilli uuid;
  v_chl2   uuid;
  v_kR     uuid := gen_random_uuid();   -- TC-35's READY write-off, replayed at TC-37 and after close
  v_kF     uuid := gen_random_uuid();   -- TC-35's FROZEN write-off
  v_id     uuid;
  v_id2    uuid;
  v_err    text;
  v_ok     boolean;
  v_n      bigint;
  v_n2     bigint;
  v_rows   bigint;
  v_led    bigint;
  v_kg     numeric;
  v_qty    numeric;
  v_state  text;
  v_item   text;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_adm_a), (v_adm_b), (v_cm);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',             'L1_OWNER',        true),
    (v_adm_a, 'แอดมินสาขาเอ',         'L2_BRANCH_ADMIN', true),
    (v_adm_b, 'แอดมินสาขาบี',         'L2_BRANCH_ADMIN', true),
    (v_cm,    'ผู้ปฏิบัติงานเชียงใหม่',   'L3_CM_OPERATOR',  true);
  insert into locations (code, name_th, kind) values ('BRA44', 'สาขาเอ', 'BRANCH') returning id into v_bra;
  insert into locations (code, name_th, kind) values ('BRB44', 'สาขาบี', 'BRANCH') returning id into v_brb;
  insert into user_locations (profile_id, location_id) values
    (v_adm_a, v_bra), (v_adm_b, v_brb), (v_cm, v_bra);

  insert into lots (lot_code, is_opening, state, event_date)
       values ('LOT-44A', true, 'LOT_CLOSED', v_day - 5) returning id into v_lotA;
  insert into lots (lot_code, is_opening, state, event_date)
       values ('LOT-44B', true, 'LOT_CLOSED', v_day - 5) returning id into v_lotB;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotA, v_day - 5) returning id into v_gA;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotB, v_day - 5) returning id into v_gB;
  select id into v_chilli from products where code = 'CHILLI_TUBE';

  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_bra, v_day, now(), v_adm_a) returning id into v_rep;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_bra, 'FROZEN', 'TRANSFER_IN',
                         10.00, v_day - 1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(gen_random_uuid(), 'CHILLI_PASTE', v_bra, 'READY', 'TRANSFER_IN',
                         100, v_day - 1, p_product_id => v_chilli);

  -- UAT-10's first half: frozen 10, thaw 3, through lane B's thaw.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  perform fn_record_thaw(p_idempotency_key     => gen_random_uuid(),
                         p_daily_report_id     => v_rep,
                         p_lot_id              => v_lotA,
                         p_smoke_date_group_id => v_gA,
                         p_thawed_weight_kg    => 3.00);

  --------------------------------------------------------------------------------- TC-32
  -- Role and branch. The L3 holds a membership row at branch A and is refused on role.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'READY', 0.10, 'เหลือปลายวัน', v_lotA, v_gA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-32: an L3 wrote off meat, got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'READY', 0.10, 'เหลือปลายวัน', v_lotA, v_gA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN_LOCATION%',
    format('TC-32: branch B''s admin wrote off at branch A, got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), gen_random_uuid(), 'SMOKED_MEAT', 'READY', 0.10, 'เหลือปลายวัน', v_lotA, v_gA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_NOT_FOUND%',
    format('TC-32: an L1 with a missing report got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_err := null;
  begin
    perform fn_record_waste(null, v_rep, 'SMOKED_MEAT', 'READY', 0.10, 'เหลือปลายวัน', v_lotA, v_gA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'IDEMPOTENCY_KEY_REQUIRED%',
    format('a null key got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-33
  -- No reason, then a blank one. BR19: an unexplained write-off is the one found in an audit.
  foreach v_state in array array['null', '   '] loop
    v_err := null;
    begin
      perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'READY', 0.10,
                              case when v_state = 'null' then null else v_state end, v_lotA, v_gA);
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'WASTE_REASON_REQUIRED%',
      format('TC-33: reason [%s] got [%s]', v_state, coalesce(v_err, 'no error at all'));
  end loop;

  --------------------------------------------------------------------------------- TC-34
  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'READY', 0.10, 'เหลือปลายวัน', null, v_gA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'LOT_REQUIRED%',
    format('TC-34: meat with no lot got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'READY', 0.10, 'เหลือปลายวัน', v_lotA, null);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'SMOKE_GROUP_REQUIRED%',
    format('TC-34: meat with no smoke-date group got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'READY', 0.10, 'เหลือปลายวัน', v_lotA, v_gB);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'LOT_REQUIRED%' and v_err like '%' || v_lotB::text || '%',
    format('TC-34: lot A with lot B''s group got [%s]', coalesce(v_err, 'no error at all'));

  ------------------------------------------------------------- the row's shape (B15, BR21)
  foreach v_item in array array['COOKED_RICE', 'PACKAGING', 'BEVERAGE'] loop
    v_err := null;
    begin
      perform fn_record_waste(gen_random_uuid(), v_rep, v_item::item_type, 'READY', 1.00, 'หก');
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'WASTE_ITEM_TYPE_INVALID%',
      format('B15: a %s write-off got [%s]', v_item, coalesce(v_err, 'no error at all'));
  end loop;

  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'IN_TRANSIT', 0.10, 'เหลือปลายวัน', v_lotA, v_gA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'WASTE_STATE_INVALID%',
    format('B15: an IN_TRANSIT write-off got [%s]', coalesce(v_err, 'no error at all'));

  -- The state is stated, never defaulted: an explicit null is refused by name.
  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', null, 0.10, 'เหลือปลายวัน', v_lotA, v_gA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'WASTE_STATE_INVALID%',
    format('B15: a null stock state got [%s]', coalesce(v_err, 'no error at all'));

  foreach v_qty in array array[0, -1, 0.123]::numeric[] loop
    v_err := null;
    begin
      perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'READY', v_qty, 'เหลือปลายวัน', v_lotA, v_gA);
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'WASTE_QTY_INVALID%',
      format('B15: a qty of %s got [%s]', v_qty, coalesce(v_err, 'no error at all'));
  end loop;

  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'CHILLI_PASTE', 'READY', 1.5, 'หลอดแตก');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'QTY_NOT_WHOLE_UNITS%',
    format('BR21: 1.5 tubes got [%s]', coalesce(v_err, 'no error at all'));

  select count(*) into v_n from waste_records;
  assert v_n = 0, format('%s waste row(s) survived refused calls', v_n);

  --------------------------------------------------------------------------------- TC-35
  -- The state is stated, not defaulted. 0.60 READY, then 1.00 FROZEN: two different tuples.
  -- READY falls 0.60 and FROZEN falls 1.00.
  select count(*) into v_led from stock_ledger;
  v_id  := fn_record_waste(v_kR, v_rep, 'SMOKED_MEAT', 'READY',  0.60, 'เนื้อละลายเหลือปลายวัน', v_lotA, v_gA);
  v_id2 := fn_record_waste(v_kF, v_rep, 'SMOKED_MEAT', 'FROZEN', 1.00, 'ถุงรั่ว เนื้อเสีย',       v_lotA, v_gA);

  select count(*) into v_n from stock_ledger
   where source_table = 'waste_records' and source_id = v_id and movement_type = 'WASTE'
     and stock_state = 'READY' and qty_delta = -0.60 and lot_id = v_lotA
     and smoke_date_group_id = v_gA and product_id is null and business_date = v_day
     and idempotency_key = v_kR;
  select count(*) into v_n2 from stock_ledger
   where source_table = 'waste_records' and source_id = v_id2 and movement_type = 'WASTE'
     and stock_state = 'FROZEN' and qty_delta = -1.00 and lot_id = v_lotA;
  assert v_n = 1 and v_n2 = 1,
    format('TC-35: READY write-off rows %s, FROZEN write-off rows %s — expected one each, on their own tuples', v_n, v_n2);

  select sum(qty_delta) filter (where stock_state = 'READY'),
         sum(qty_delta) filter (where stock_state = 'FROZEN')
    into v_kg, v_qty
    from stock_ledger
   where item_type = 'SMOKED_MEAT' and location_id = v_bra and lot_id = v_lotA;
  assert v_kg = 2.40 and v_qty = 6.00,
    format('TC-35: READY %s (expected 2.40), FROZEN %s (expected 6.00)', v_kg, v_qty);

  select count(*) into v_n from waste_records
   where id = v_id and reason = 'เนื้อละลายเหลือปลายวัน' and created_by = v_adm_a
     and idempotency_key = v_kR and qty = 0.60 and item_type = 'SMOKED_MEAT';
  assert v_n = 1, 'TC-35: the waste row does not carry its reason, actor, key and quantity';

  -- R32: the audit row is the trigger's, written once, and it carries the reason.
  select count(*) into v_n from audit_log
   where table_name = 'waste_records' and row_id = v_id and reason = 'เนื้อละลายเหลือปลายวัน';
  assert v_n = 1, format('TC-35: %s audit row(s) for one write-off, expected 1 carrying the reason', v_n);

  --------------------------------------------------------------------------------- TC-36
  -- Over-wasting: 5.00 against 2.40 READY. R3 refuses it by its own name, and nothing is left
  -- behind: neither the waste row nor a ledger row.
  select count(*) into v_rows from waste_records;
  select count(*) into v_led  from stock_ledger;
  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'READY', 5.00, 'เหลือปลายวัน', v_lotA, v_gA);
  exception when others then v_err := sqlerrm;
  end;
  select count(*) into v_n  from waste_records;
  select count(*) into v_n2 from stock_ledger;
  assert v_err like 'INSUFFICIENT_STOCK%' and v_n = v_rows and v_n2 = v_led,
    format('TC-36: over-waste got [%s] and left %s row(s), %s ledger row(s)',
           coalesce(v_err, 'no error at all'), v_n - v_rows, v_n2 - v_led);

  --------------------------------------------------------------------------------- TC-37
  -- The replay: same key, same payload, the same id, one row, one ledger row (R4).
  v_id2 := fn_record_waste(v_kR, v_rep, 'SMOKED_MEAT', 'READY', 0.60, 'เนื้อละลายเหลือปลายวัน', v_lotA, v_gA);
  select count(*) into v_n  from waste_records where idempotency_key = v_kR;
  select count(*) into v_n2 from stock_ledger  where source_id = v_id;
  assert v_id2 = v_id and v_n = 1 and v_n2 = 1,
    format('TC-37: the replay returned %s (first %s), rows %s, ledger rows %s', v_id2, v_id, v_n, v_n2);

  -- The same key with a different payload: a different quantity, then a different state.
  v_err := null;
  begin
    perform fn_record_waste(v_kR, v_rep, 'SMOKED_MEAT', 'READY', 0.50, 'เนื้อละลายเหลือปลายวัน', v_lotA, v_gA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'WASTE_IDEMPOTENCY_CONFLICT%',
    format('TC-37: the key with another quantity got [%s]', coalesce(v_err, 'no error at all'));
  v_err := null;
  begin
    perform fn_record_waste(v_kR, v_rep, 'SMOKED_MEAT', 'FROZEN', 0.60, 'เนื้อละลายเหลือปลายวัน', v_lotA, v_gA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'WASTE_IDEMPOTENCY_CONFLICT%',
    format('TC-37: the key with another stock state got [%s]', coalesce(v_err, 'no error at all'));

  ------------------------------------------------------------------ chilli (B12, BR21)
  v_id2 := fn_record_waste(gen_random_uuid(), v_rep, 'CHILLI_PASTE', 'READY', 2, 'หลอดแตก');
  select count(*) into v_n from stock_ledger
   where source_id = v_id2 and item_type = 'CHILLI_PASTE' and product_id = v_chilli
     and lot_id is null and stock_state = 'READY' and qty_delta = -2;
  select sum(qty_delta) into v_kg from stock_ledger where item_type = 'CHILLI_PASTE' and location_id = v_bra;
  assert v_n = 1 and v_kg = 98,
    format('B12: the chilli write-off is not -2 on (CHILLI_TUBE, READY): rows %s, balance %s', v_n, v_kg);

  -- A second active chilli SKU makes the tuple ambiguous, and that is refused, never guessed.
  insert into products (code, name_th, item_type, sale_unit, is_stock_tracked)
       values ('CHILLI_TUBE_TEST', 'น้ำพริกทดสอบ', 'CHILLI_PASTE', 'tube', true) returning id into v_chl2;
  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'CHILLI_PASTE', 'READY', 1, 'หลอดแตก');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'PRODUCT_AMBIGUOUS%',
    format('B12: two chilli SKUs got [%s]', coalesce(v_err, 'no error at all'));
  update products set is_active = false where id = v_chl2;

  ------------------------------------------------------------------- the Owner writes off (B1)
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_id2 := fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'READY', 0.40, 'ตัวอย่างให้ลูกค้าชิม', v_lotA, v_gA);
  select count(*) into v_n from waste_records where id = v_id2 and created_by = v_owner;
  assert v_n = 1, 'B1: the Owner''s write-off at branch A is not signed by the Owner (v0.2:57)';

  --------------------------------------------------------------------- the acceptance line
  -- "Leftover thawed meat is written off against its lot with a reason; nothing thawed
  -- carries to tomorrow." Whatever is left in READY goes, and FROZEN is not touched (BR19).
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'READY', 2.00, 'เนื้อละลายเหลือปลายวัน', v_lotA, v_gA);
  select sum(qty_delta) filter (where stock_state = 'READY'),
         sum(qty_delta) filter (where stock_state = 'FROZEN')
    into v_kg, v_qty
    from stock_ledger
   where item_type = 'SMOKED_MEAT' and location_id = v_bra;
  assert v_kg = 0.00 and v_qty = 6.00,
    format('acceptance: READY %s (expected 0.00), FROZEN %s (expected 6.00, untouched)', v_kg, v_qty);

  ----------------------------------------------------------- the closed day (TC-32, B2)
  update daily_reports set status = 'CLOSED', closed_by = v_adm_a, closed_at = now() where id = v_rep;
  v_err := null;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'FROZEN', 0.10, 'ถุงรั่ว', v_lotA, v_gA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_CLOSED%' and v_err like '%no waste can be recorded%'
     and v_err like '%' || v_day::text || '%',
    format('TC-32: a write-off against a CLOSED day got [%s]', coalesce(v_err, 'no error at all'));

  -- The retry of a write-off that committed before the close returns its id (R4).
  v_id2 := fn_record_waste(v_kR, v_rep, 'SMOKED_MEAT', 'READY', 0.60, 'เนื้อละลายเหลือปลายวัน', v_lotA, v_gA);
  assert v_id2 = v_id, format('B2: a replay after close returned %s, expected %s', v_id2, v_id);

  update daily_reports set status = 'UNLOCKED' where id = v_rep;
  v_ok := false;
  begin
    perform fn_record_waste(gen_random_uuid(), v_rep, 'SMOKED_MEAT', 'FROZEN', 0.10, 'ถุงรั่ว', v_lotA, v_gA);
    v_ok := true;
  exception when others then v_err := sqlerrm;
  end;
  assert v_ok, format('an UNLOCKED day refused a write-off: [%s]', v_err);

  ------------------------------------------------------------------------------ grants
  assert has_function_privilege('authenticated',
           'public.fn_record_waste(uuid, uuid, item_type, stock_state, numeric, text, uuid, uuid)', 'EXECUTE'),
    'authenticated cannot execute fn_record_waste';
  assert not has_function_privilege('anon',
           'public.fn_record_waste(uuid, uuid, item_type, stock_state, numeric, text, uuid, uuid)', 'EXECUTE'),
    'anon can execute fn_record_waste';

  raise exception 'WASTE_TEST_PASSED';   -- the only clean way back out
end $$;
