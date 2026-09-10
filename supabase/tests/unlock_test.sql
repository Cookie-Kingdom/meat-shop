-- Card ^ref-08 — fn_request_unlock, fn_decide_unlock, fn_unlock_impact, v_unlock_requests,
-- migration ...0023, and fn_set_config's guard on the two unlock keys.
--
-- Covers UL-01 ... UL-46 from v.0.1/ref-08-unlock/TDD-unlock.md.
-- Assumes lane C's unmerged ...0018: sales_lines.created_by NOT NULL and pack_weight_kg
-- (UL-30, UL-31, UL-34, UL-35 insert sales lines in that shape), and fn_guard_report_closed
-- on sales_lines (UL-35 expects its REPORT_CLOSED). The file passes only once C has merged.
--
-- THE CLOCK. Report dates are current_date - k, because R28's window is measured from
-- current_date. now() is fixed for the transaction, so "time passes" is written as expires_at
-- moving behind now() (TC-52's precedent). The comparison is the same, and no sweep is
-- involved (R42).
--
-- ORDER MATTERS, which is why this is one block (and one block is the house pattern anyway:
-- the closing raise rolls it all back):
--   unlock_window_hours stays unset until after UL-45, so UL-01 ... UL-03 see CONFIG_NOT_SET;
--   opening_balance_close stays empty until after UL-04 (ADR-021), then is closed for good;
--   unlock_max_days_back goes 3 → 5 → 1 → 0 through later-dated rows (UL-05 ... UL-09).
-- Lane I's ...0024 seeds unlock_max_days_back = 3 at 2000-01-01. Every row here is dated
-- later, so the seed never wins. unlock_window_hours is not seeded (ADR-023 BLOCK), so no
-- seed row needs deleting for UL-01 ... UL-03.
--
-- Run:  psql "$DATABASE_URL" -f supabase/tests/unlock_test.sql

do $$
declare
  v_ok        boolean;
  v_err       text;
  v_n         bigint;
  v_m         bigint;
  v_x         bigint;
  v_kg        numeric;
  v_base_rows bigint;
  v_base_kg   numeric;
  v_resp      jsonb;
  v_resp2     jsonb;
  v_imp       jsonb;
  v_imp2      jsonb;
  v_st        unlock_status;
  v_rs        report_status;
  v_by        uuid;
  v_txt       text;
  v_today     date := current_date;
  v_day       date := date '2026-05-04';
  v_owner     uuid := gen_random_uuid();
  v_l2a       uuid := gen_random_uuid();
  v_l2b       uuid := gen_random_uuid();
  v_l3        uuid := gen_random_uuid();
  v_l3b       uuid := gen_random_uuid();
  v_gone      uuid := gen_random_uuid();
  v_chef      uuid;
  v_chef2     uuid;
  v_brA       uuid;
  v_brB       uuid;
  v_sup       uuid;
  v_po        uuid;
  v_lotL      uuid;   -- closed, assigned to v_l3, has a receipt
  v_lotM      uuid;   -- closed, assigned to v_l3b at the other chef house
  v_lotS      uuid;   -- still SMOKING
  v_prod      uuid;
  v_rA10      uuid;
  v_rA8       uuid;
  v_rA6       uuid;
  v_rA5       uuid;
  v_rA4       uuid;
  v_rA3       uuid;
  v_rA2       uuid;
  v_rA1       uuid;
  v_rA0       uuid;
  v_rB1       uuid;
  v_rBopen    uuid;
  v_key       uuid;
  v_reqL      uuid;
  v_reqD3     uuid;
  v_reqD8     uuid;
  v_id        uuid;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2a), (v_l2b), (v_l3), (v_l3b), (v_gone);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',                'L1_OWNER',        true),
    (v_l2a,   'แอดมินสาขา A',           'L2_BRANCH_ADMIN', true),
    (v_l2b,   'แอดมินสาขา B',           'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานโรงรมหนึ่ง',    'L3_CM_OPERATOR',  true),
    (v_l3b,   'ผู้ปฏิบัติงานโรงรมสอง',     'L3_CM_OPERATOR',  true),
    (v_gone,  'ผู้ปฏิบัติงานที่ปิดใช้',     'L3_CM_OPERATOR',  false);

  insert into locations (code, name_th, kind) values ('ULC1', 'โรงรมปลดล็อกหนึ่ง', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('ULC2', 'โรงรมปลดล็อกสอง', 'CHEF_HOUSE')
    returning id into v_chef2;
  insert into locations (code, name_th, kind) values ('ULBA', 'สาขาปลดล็อก A', 'BRANCH')
    returning id into v_brA;
  insert into locations (code, name_th, kind) values ('ULBB', 'สาขาปลดล็อก B', 'BRANCH')
    returning id into v_brB;
  insert into user_locations (profile_id, location_id) values
    (v_l3, v_chef), (v_gone, v_chef), (v_l3b, v_chef2), (v_l2a, v_brA), (v_l2b, v_brB);
  insert into suppliers (name) values ('ฟู้ดดีว่า UL') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_json => 'true'::jsonb);
  perform fn_set_config(gen_random_uuid(), 'unlock_max_days_back', date '2026-01-01',
                        p_value_numeric => 3);

  v_po   := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);
  v_lotL := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotS := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotM := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef2);
  update lots set state = 'IN_TRANSIT', assigned_operator_id = v_l3  where id in (v_lotL, v_lotS);
  update lots set state = 'IN_TRANSIT', assigned_operator_id = v_l3b where id = v_lotM;

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotL, v_day, 98.00);

  update lots set state = 'LOT_CLOSED' where id in (v_lotL, v_lotM);
  update lots set state = 'SMOKING'    where id = v_lotS;

  -- Closed days at branch A, one per boundary case, so no two cases share a target.
  insert into daily_reports (location_id, report_date, status, shift_started_at)
       values (v_brA, v_today - 10, 'CLOSED', now()) returning id into v_rA10;
  insert into daily_reports (location_id, report_date, status, shift_started_at)
       values (v_brA, v_today - 6, 'CLOSED', now()) returning id into v_rA6;
  insert into daily_reports (location_id, report_date, status, shift_started_at)
       values (v_brA, v_today - 5, 'CLOSED', now()) returning id into v_rA5;
  insert into daily_reports (location_id, report_date, status, shift_started_at)
       values (v_brA, v_today - 4, 'CLOSED', now()) returning id into v_rA4;
  insert into daily_reports (location_id, report_date, status, shift_started_at)
       values (v_brA, v_today - 3, 'CLOSED', now()) returning id into v_rA3;
  insert into daily_reports (location_id, report_date, status, shift_started_at)
       values (v_brA, v_today - 2, 'CLOSED', now()) returning id into v_rA2;
  insert into daily_reports (location_id, report_date, status, shift_started_at)
       values (v_brA, v_today - 1, 'CLOSED', now()) returning id into v_rA1;
  insert into daily_reports (location_id, report_date, status, shift_started_at)
       values (v_brA, v_today, 'CLOSED', now()) returning id into v_rA0;
  insert into daily_reports (location_id, report_date, status, shift_started_at)
       values (v_brB, v_today - 1, 'CLOSED', now()) returning id into v_rB1;
  insert into daily_reports (location_id, report_date, status, shift_started_at)
       values (v_brB, v_today, 'OPEN', now()) returning id into v_rBopen;

  -- The impact day, A @ -8. It holds two sales lines and two meat ledger rows on lot L, written
  -- while the day is OPEN and then closed, the way a real day is.
  insert into products (code, name_th, item_type, sale_unit)
       values ('UL_TEST_BOX', 'เนื้อรมควันกล่องทดสอบปลดล็อก', 'SMOKED_MEAT', 'box')
    returning id into v_prod;
  insert into daily_reports (location_id, report_date, status, shift_started_at)
       values (v_brA, v_today - 8, 'OPEN', now()) returning id into v_rA8;
  insert into sales_lines (daily_report_id, product_id, lot_id, qty, unit_price_thb, channel,
                           created_by, pack_weight_kg) values
    (v_rA8, v_prod, v_lotL, 2, 350.00, 'LINE_MAN', v_l2a, 0.50),
    (v_rA8, v_prod, v_lotL, 1, 320.00, 'LINE_MAN', v_l2a, 0.50);

  -- Whatever the purchasing chain already put on lot L is the LOT impact's baseline (UL-31).
  select count(*), coalesce(sum(abs(qty_delta)) filter (where item_type = 'SMOKED_MEAT'), 0)
    into v_base_rows, v_base_kg
    from stock_ledger where lot_id = v_lotL;

  insert into stock_ledger (idempotency_key, item_type, lot_id, location_id, stock_state,
                            movement_type, qty_delta, business_date, event_at, created_by) values
    (gen_random_uuid(), 'SMOKED_MEAT', v_lotL, v_brA, 'READY', 'INTAKE',  5.00, v_today - 8, now(), v_owner),
    (gen_random_uuid(), 'SMOKED_MEAT', v_lotL, v_brA, 'READY', 'SALE',   -2.00, v_today - 8, now(), v_owner);
  update daily_reports set status = 'CLOSED', closed_at = now(), closed_by = v_l2a where id = v_rA8;

  select count(*) into v_n from opening_balance_close;
  assert v_n = 0, 'fixture: opening_balance_close is not empty, so UL-04 cannot test ADR-021';

  ---------------------------------------------------------------------------------- UL-01
  -- No window hours: an approval has no expiry to write, so it is refused (R42, R35).
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA6, 'แก้ยอดขาย');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'CONFIG_NOT_SET:%';
  end;
  assert v_ok, format('UL-01: an L1 unlock with no window hours got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-02
  -- A PENDING request needs no expiry, so it does not need the key either.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_resp := fn_request_unlock(gen_random_uuid(), 'LOT', v_lotL, 'ชั่งน้ำหนักรับเข้าผิด ต้องแก้');
  assert v_resp ->> 'status' = 'PENDING', format('UL-02: an L3 lot request answered %s', v_resp);
  assert v_resp ->> 'expires_at' is null, format('UL-02: a PENDING request carries an expiry: %s', v_resp);
  v_reqL := (v_resp ->> 'unlock_request_id')::uuid;

  ---------------------------------------------------------------------------------- UL-03
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_decide_unlock(gen_random_uuid(), v_reqL, 'APPROVED', 'ตรวจแล้ว');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'CONFIG_NOT_SET:%';
  end;
  assert v_ok, format('UL-03: an approval with no window hours got %s', coalesce(v_err, 'no exception at all'));
  select status into v_st from unlock_requests where id = v_reqL;
  assert v_st = 'PENDING', format('UL-03: the refused approval left the request %s', v_st);

  --------------------------------------------------------------------------- UL-43 ... 45
  -- The config writer refuses the shapes R28 and R42 cannot use.
  v_ok := false; v_err := null;
  begin
    perform fn_set_config(gen_random_uuid(), 'unlock_max_days_back', v_today - 3, p_value_numeric => -1);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'CONFIG_VALUE_INVALID:%';
  end;
  assert v_ok, format('UL-43: a negative reach got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_set_config(gen_random_uuid(), 'unlock_max_days_back', v_today - 3, p_value_numeric => 1.5);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'CONFIG_VALUE_INVALID:%';
  end;
  assert v_ok, format('UL-44: a fractional reach got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_set_config(gen_random_uuid(), 'unlock_window_hours', date '2026-01-01', p_value_numeric => 0);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'CONFIG_VALUE_INVALID:%';
  end;
  assert v_ok, format('UL-45: a zero-hour window got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_set_config(gen_random_uuid(), 'unlock_window_hours', date '2026-01-01', p_value_numeric => -2);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'CONFIG_VALUE_INVALID:%';
  end;
  assert v_ok, format('UL-45: a negative window got %s', coalesce(v_err, 'no exception at all'));

  perform fn_set_config(gen_random_uuid(), 'unlock_window_hours', date '2026-01-01', p_value_numeric => 4);

  ---------------------------------------------------------------------------------- UL-04
  -- ADR-021: while opening balances are unlocked, back-dating is relaxed, and so is
  -- auto-approval. It is the same function, so it is the same relaxation.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_resp := fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA10, 'ลืมบันทึกยอดขายช่วงเปิดระบบ');
  assert v_resp ->> 'status' = 'APPROVED', format('UL-04: -10 with opening open answered %s', v_resp);
  assert v_resp ->> 'decided_by' is null, format('UL-04: an auto-approval names a decider: %s', v_resp);

  insert into opening_balance_close (closed_by, closed_idempotency_key) values (v_owner, gen_random_uuid());

  ---------------------------------------------------------------------------------- UL-05
  -- The boundary itself, exactly current_date - 3 with the key at 3: inside (R28, inclusive).
  v_key := gen_random_uuid();
  v_resp := fn_request_unlock(v_key, 'DAILY_REPORT', v_rA3, 'ยอดขายขาดหนึ่งรายการ');
  assert v_resp ->> 'status' = 'APPROVED', format('UL-05: exactly -3 answered %s', v_resp);
  assert v_resp ->> 'decided_by' is null, format('UL-05: R28 decided it, yet a decider is named: %s', v_resp);
  assert (v_resp ->> 'expires_at')::timestamptz = now() + interval '4 hours',
    format('UL-05: expires_at is %s, expected now() + 4h', v_resp ->> 'expires_at');
  v_reqD3 := (v_resp ->> 'unlock_request_id')::uuid;
  select count(*) into v_n from unlock_requests
   where id = v_reqD3 and decided_at is not null and decision_impact is null;
  assert v_n = 1, 'UL-05: an auto-approval must carry decided_at and no Owner impact';

  ---------------------------------------------------------------------------------- UL-06
  v_resp := fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA4, 'ยอดขายวันพฤหัสผิด');
  assert v_resp ->> 'status' = 'PENDING', format('UL-06: -4 with the key at 3 answered %s', v_resp);

  ---------------------------------------------------------------------------------- UL-10
  -- Finding 1: the approval admits writes through its row. The day is never flipped.
  select status into v_rs from daily_reports where id = v_rA3;
  assert v_rs = 'CLOSED', format('UL-10: an approved day reads %s, expected CLOSED', v_rs);

  ---------------------------------------------------------------------------------- UL-11
  v_resp2 := fn_request_unlock(v_key, 'DAILY_REPORT', v_rA3, 'เหตุผลอื่นที่ส่งซ้ำ');
  assert v_resp2 = v_resp, format('UL-11: the replay answered %s, the first call %s', v_resp2, v_resp);
  select count(*) into v_n from unlock_requests where idempotency_key = v_key;
  assert v_n = 1, format('UL-11: a replay wrote %s rows', v_n);
  select reason into v_txt from unlock_requests where id = v_reqD3;
  assert v_txt = 'ยอดขายขาดหนึ่งรายการ', 'UL-11: the replay rewrote the reason';

  ---------------------------------------------------------------------------------- UL-12
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(v_key, 'DAILY_REPORT', v_rA3, 'ขอด้วยคีย์คนอื่น');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'UNLOCK_IDEMPOTENCY_CONFLICT:%';
  end;
  assert v_ok, format('UL-12: another actor''s key got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-21
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA3, 'ขอซ้ำ');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'UNLOCK_ALREADY_OPEN:%';
  end;
  assert v_ok, format('UL-21: a second request on a live unlock got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-07
  -- Retune to 5 with a later-dated row. The line moves and stays inclusive.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'unlock_max_days_back', v_today - 2, p_value_numeric => 5);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_resp := fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA5, 'แก้ยอด -5');
  assert v_resp ->> 'status' = 'APPROVED', format('UL-07: -5 with the key at 5 answered %s', v_resp);
  v_resp := fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA6, 'แก้ยอด -6');
  assert v_resp ->> 'status' = 'PENDING', format('UL-07: -6 with the key at 5 answered %s', v_resp);

  ---------------------------------------------------------------------------------- UL-08
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'unlock_max_days_back', v_today - 1, p_value_numeric => 1);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_resp := fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA1, 'แก้ยอด -1');
  assert v_resp ->> 'status' = 'APPROVED', format('UL-08: -1 with the key at 1 answered %s', v_resp);
  v_resp := fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA2, 'แก้ยอด -2');
  assert v_resp ->> 'status' = 'PENDING', format('UL-08: -2 with the key at 1 answered %s', v_resp);

  ------------------------------------------------------------------------- UL-09, UL-46
  -- 0 is legal and means today only.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_id := fn_set_config(gen_random_uuid(), 'unlock_max_days_back', v_today, p_value_numeric => 0);
  assert v_id is not null, 'UL-46: the writer refused a reach of 0';
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_resp := fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA0, 'แก้ยอดวันนี้หลังปิด');
  assert v_resp ->> 'status' = 'APPROVED', format('UL-09: today with the key at 0 answered %s', v_resp);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  v_resp := fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rB1, 'แก้ยอดเมื่อวาน');
  assert v_resp ->> 'status' = 'PENDING', format('UL-09: yesterday with the key at 0 answered %s', v_resp);

  ---------------------------------------------------------------------------------- UL-14
  -- The window widens who may act, not what they may reach (R28).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rB1, 'ขอข้ามสาขา');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'OUT_OF_SCOPE:%';
  end;
  assert v_ok, format('UL-14: an L2 on another branch got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-16
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'LOT', v_lotM, 'แอดมินสาขาขอปลดล็อต');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'OUT_OF_SCOPE:%';
  end;
  assert v_ok, format('UL-16: an L2 asking for a lot got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-18
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', gen_random_uuid(), 'ไม่มีวันนี้');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'UNLOCK_TARGET_NOT_FOUND:%';
  end;
  assert v_ok, format('UL-18: an unknown day got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-19
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA2, '   ');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'UNLOCK_REASON_REQUIRED:%';
  end;
  assert v_ok, format('UL-19: a blank reason got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(null, 'DAILY_REPORT', v_rA2, 'ไม่มีคีย์');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'IDEMPOTENCY_KEY_REQUIRED:%';
  end;
  assert v_ok, format('UL-19: a null key got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), null, v_rA2, 'ไม่มีชนิด');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'UNLOCK_TARGET_REQUIRED:%';
  end;
  assert v_ok, format('UL-19: a null target type got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-17
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rBopen, 'วันนี้ยังเปิดอยู่');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'TARGET_NOT_CLOSED:%';
  end;
  assert v_ok, format('UL-17: an OPEN day got %s', coalesce(v_err, 'no exception at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'LOT', v_lotS, 'ล็อตยังรมอยู่');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'TARGET_NOT_CLOSED:%';
  end;
  assert v_ok, format('UL-17: a SMOKING lot got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-15
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'LOT', v_lotM, 'ล็อตของคนอื่น');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'OUT_OF_SCOPE:%';
  end;
  assert v_ok, format('UL-15: an L3 on another operator''s lot got %s', coalesce(v_err, 'no exception at all'));

  -- UL-16's other half: an L3 has no day to unlock.
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA2, 'โรงรมขอปลดวัน');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'OUT_OF_SCOPE:%';
  end;
  assert v_ok, format('UL-16: an L3 asking for a day got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-13
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'LOT', v_lotL, 'ขอซ้ำระหว่างรอ');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'UNLOCK_ALREADY_PENDING:%';
  end;
  assert v_ok, format('UL-13: a second lot request while one waits got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-20
  perform set_config('request.jwt.claims', json_build_object('sub', v_gone)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_request_unlock(gen_random_uuid(), 'LOT', v_lotL, 'บัญชีที่ปิดใช้');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NO_ACTOR:%';
  end;
  assert v_ok, format('UL-20: a deactivated operator got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-23
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_decide_unlock(gen_random_uuid(), v_reqL, 'APPROVED', 'แอดมินอนุมัติเอง');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('UL-23: an L2 decision got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-24
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_decide_unlock(gen_random_uuid(), v_reqL, 'APPROVED', '   ');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'DECISION_NOTE_REQUIRED:%';
  end;
  assert v_ok, format('UL-24: an approval with no reason got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-25
  v_ok := false; v_err := null;
  begin
    perform fn_decide_unlock(gen_random_uuid(), v_reqL, 'MAYBE', 'ยังไม่แน่ใจ');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'UNLOCK_DECISION_INVALID:%';
  end;
  assert v_ok, format('UL-25: decision MAYBE got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_decide_unlock(gen_random_uuid(), gen_random_uuid(), 'APPROVED', 'ไม่มีคำขอนี้');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'UNLOCK_REQUEST_NOT_FOUND:%';
  end;
  assert v_ok, format('UL-25: an unknown request got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-26
  -- The deciding Owner is recorded (UAT-12), and the impact is stored with the decision (D07).
  v_resp := fn_decide_unlock(gen_random_uuid(), v_reqL, 'APPROVED', 'ตรวจใบชั่งแล้ว อนุมัติ');
  assert v_resp ->> 'status' = 'APPROVED', format('UL-26: the approval answered %s', v_resp);
  assert (v_resp ->> 'decided_by')::uuid = v_owner, format('UL-26: decided_by is %s', v_resp ->> 'decided_by');
  assert (v_resp ->> 'expires_at')::timestamptz = now() + interval '4 hours',
    format('UL-26: expires_at is %s, expected now() + 4h', v_resp ->> 'expires_at');
  assert jsonb_typeof(v_resp -> 'impact') = 'object', format('UL-26: no impact in %s', v_resp);
  select decided_by, decision_impact, decision_note into v_by, v_imp, v_txt
    from unlock_requests where id = v_reqL;
  assert v_by = v_owner, 'UL-26: the row does not name the deciding Owner';
  assert v_imp = v_resp -> 'impact', 'UL-26: the stored impact differs from the one returned';
  assert v_txt = 'ตรวจใบชั่งแล้ว อนุมัติ', format('UL-26: the note stored is %s', v_txt);

  ---------------------------------------------------------------------------------- UL-27
  v_resp2 := fn_decide_unlock(gen_random_uuid(), v_reqL, 'APPROVED', 'กดอนุมัติซ้ำ');
  assert v_resp2 = v_resp, format('UL-27: the replay answered %s, the decision %s', v_resp2, v_resp);
  select decision_note into v_txt from unlock_requests where id = v_reqL;
  assert v_txt = 'ตรวจใบชั่งแล้ว อนุมัติ', 'UL-27: the replay rewrote the note';

  ---------------------------------------------------------------------------------- UL-28
  v_ok := false; v_err := null;
  begin
    perform fn_decide_unlock(gen_random_uuid(), v_reqL, 'REJECTED', 'เปลี่ยนใจ');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'UNLOCK_ALREADY_DECIDED:%';
  end;
  assert v_ok, format('UL-28: reversing a decision got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-29
  -- R8 + R42 on the lot half, through the receipt ^fix-receipt-state-floor reopened.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_id := null; v_err := null;
  begin
    v_id := fn_record_lot_receipt(gen_random_uuid(), v_lotL, v_day, 97.00);
  exception when others then
    v_err := sqlerrm;
  end;
  assert v_id is not null, format('UL-29: a correction under a live approval was refused: %s', v_err);
  select received_weight_kg into v_kg from lot_receipts where lot_id = v_lotL;
  assert v_kg = 97.00, format('UL-29: the admitted correction stored %s', v_kg);

  update unlock_requests set expires_at = now() - interval '1 minute' where id = v_reqL;
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotL, v_day, 96.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_CLOSED:%';
  end;
  assert v_ok, format('UL-29: a correction after expires_at got %s', coalesce(v_err, 'no exception at all'));

  select status into v_st from v_unlock_requests where unlock_request_id = v_reqL;
  assert v_st = 'EXPIRED', format('UL-29: the L3 reads the expired approval as %s', v_st);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select status into v_st from v_unlock_requests where unlock_request_id = v_reqL;
  assert v_st = 'EXPIRED', format('UL-29: the Owner reads the expired approval as %s', v_st);

  ---------------------------------------------------------------------------------- UL-22
  -- The Owner acting directly: approved at once, the Owner named, and the stale row stored
  -- as EXPIRED on the way (R42's lazy flip).
  v_resp := fn_request_unlock(gen_random_uuid(), 'LOT', v_lotL, 'เจ้าของเปิดแก้เอง');
  assert v_resp ->> 'status' = 'APPROVED', format('UL-22: an L1 lot request answered %s', v_resp);
  assert (v_resp ->> 'decided_by')::uuid = v_owner, format('UL-22: decided_by is %s', v_resp ->> 'decided_by');
  select status into v_st from unlock_requests where id = v_reqL;
  assert v_st = 'EXPIRED', format('UL-22: the stale approval is stored as %s', v_st);
  select decision_impact into v_imp from unlock_requests
   where id = (v_resp ->> 'unlock_request_id')::uuid;
  assert jsonb_typeof(v_imp) = 'object', 'UL-22: the Owner''s own unlock stored no impact';

  ---------------------------------------------------------------------------------- UL-30
  v_imp := fn_unlock_impact('DAILY_REPORT', v_rA8);
  assert (v_imp ->> 'affected_daily_reports')::int = 1
     and (v_imp ->> 'affected_ledger_rows')::int = 2
     and (v_imp ->> 'sales_lines')::int = 2
     and (v_imp ->> 'sales_thb')::numeric = 1020.00
     and (v_imp ->> 'meat_moved_kg')::numeric = 7.00
     and v_imp -> 'profit_thb' = 'null'::jsonb,
    format('UL-30: the day''s impact is %s', v_imp);

  ---------------------------------------------------------------------------------- UL-31
  v_imp := fn_unlock_impact('LOT', v_lotL);
  assert (v_imp ->> 'affected_ledger_rows')::bigint = v_base_rows + 2
     and (v_imp ->> 'meat_moved_kg')::numeric = round(v_base_kg + 7.00, 2)
     and (v_imp ->> 'sales_lines')::int = 2
     and (v_imp ->> 'affected_daily_reports')::int = 1
     and (v_imp ->> 'sales_thb')::numeric = 1020.00,
    format('UL-31: the lot''s impact is %s (baseline %s rows, %s kg)', v_imp, v_base_rows, v_base_kg);

  ---------------------------------------------------------------------------------- UL-33
  v_ok := false; v_err := null;
  begin
    perform fn_unlock_impact('LOT', gen_random_uuid());
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'UNLOCK_TARGET_NOT_FOUND:%';
  end;
  assert v_ok, format('UL-33: an unknown lot got %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-32
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_unlock_impact('DAILY_REPORT', v_rA8);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('UL-32: an L2 read the impact: %s', coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------------------- UL-34
  -- -8 is outside a reach of 0, so it waits, and the Owner sees its impact before deciding.
  v_resp := fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA8, 'ยอดขายวันนั้นขาดหนึ่งกล่อง');
  assert v_resp ->> 'status' = 'PENDING', format('UL-34: -8 answered %s', v_resp);
  v_reqD8 := (v_resp ->> 'unlock_request_id')::uuid;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select impact into v_imp from v_unlock_requests where unlock_request_id = v_reqD8;
  v_imp2 := fn_unlock_impact('DAILY_REPORT', v_rA8);
  assert v_imp = v_imp2, format('UL-34: the panel shows %s, the function says %s', v_imp, v_imp2);

  ---------------------------------------------------------------------------------- UL-35
  -- The day half through lane C's guard: the approval row admits a write to a CLOSED day,
  -- and stops admitting it the moment expires_at passes.
  v_resp := fn_decide_unlock(gen_random_uuid(), v_reqD8, 'APPROVED', 'อนุมัติให้เพิ่มยอดที่ขาด');
  assert v_resp ->> 'status' = 'APPROVED', format('UL-35: the approval answered %s', v_resp);
  select status into v_rs from daily_reports where id = v_rA8;
  assert v_rs = 'CLOSED', format('UL-35: the approved day reads %s, expected CLOSED', v_rs);

  v_ok := true; v_err := null;
  begin
    insert into sales_lines (daily_report_id, product_id, lot_id, qty, unit_price_thb, channel,
                             created_by, pack_weight_kg)
         values (v_rA8, v_prod, v_lotL, 1, 350.00, 'LINE_MAN', v_l2a, 0.50);
  exception when others then
    v_err := sqlerrm; v_ok := false;
  end;
  assert v_ok, format('UL-35: a sale on a CLOSED day under a live approval was refused: %s', v_err);

  update unlock_requests set expires_at = now() - interval '1 minute' where id = v_reqD8;
  v_ok := false; v_err := null;
  begin
    insert into sales_lines (daily_report_id, product_id, lot_id, qty, unit_price_thb, channel,
                             created_by, pack_weight_kg)
         values (v_rA8, v_prod, v_lotL, 1, 350.00, 'LINE_MAN', v_l2a, 0.50);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'REPORT_CLOSED:%';
  end;
  assert v_ok, format('UL-35: a sale after expires_at got %s', coalesce(v_err, 'no exception at all'));
  select status into v_st from v_unlock_requests where unlock_request_id = v_reqD8;
  assert v_st = 'EXPIRED', format('UL-35: the expired approval reads %s', v_st);

  ---------------------------------------------------------------------------------- UL-36
  -- An expired request is not reopened. The requester asks again, as a new row (R42).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2a)::text, true);
  v_resp := fn_request_unlock(gen_random_uuid(), 'DAILY_REPORT', v_rA8, 'ขอแก้อีกครั้ง');
  assert v_resp ->> 'status' = 'PENDING', format('UL-36: asking again answered %s', v_resp);
  assert (v_resp ->> 'unlock_request_id')::uuid <> v_reqD8, 'UL-36: the expired request was reused';
  select status into v_st from unlock_requests where id = v_reqD8;
  assert v_st = 'EXPIRED', format('UL-36: the old request is stored as %s', v_st);

  ---------------------------------------------------------------------------------- UL-37
  -- Still v_l2a. Only branch A's day rows, and never an impact.
  select count(*),
         count(*) filter (where target_type <> 'DAILY_REPORT' or location_id is distinct from v_brA),
         count(*) filter (where impact is not null)
    into v_n, v_m, v_x
    from v_unlock_requests;
  assert v_n > 0, 'UL-37: branch A''s admin reads none of their own requests';
  assert v_m = 0, format('UL-37: branch A''s admin reads %s row(s) outside branch A', v_m);
  assert v_x = 0, format('UL-37: an L2 reads %s impact(s)', v_x);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l2b)::text, true);
  select count(*), count(*) filter (where location_id = v_brA) into v_n, v_m from v_unlock_requests;
  assert v_n > 0 and v_m = 0, format('UL-37: branch B''s admin reads %s rows, %s of them branch A''s', v_n, v_m);

  ---------------------------------------------------------------------------------- UL-38
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  select count(*),
         count(*) filter (where target_type <> 'LOT' or target_id <> v_lotL),
         count(*) filter (where impact is not null)
    into v_n, v_m, v_x
    from v_unlock_requests;
  assert v_n > 0, 'UL-38: the operator reads none of their lot''s requests';
  assert v_m = 0, format('UL-38: the operator reads %s row(s) that are not their lot', v_m);
  assert v_x = 0, format('UL-38: an L3 reads %s impact(s) — money (R20)', v_x);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3b)::text, true);
  select count(*) into v_n from v_unlock_requests where target_id = v_lotL;
  assert v_n = 0, format('UL-38: another operator reads %s of lot L''s requests', v_n);

  ---------------------------------------------------------------------------------- UL-39
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_unlock_requests;
  select count(*) into v_m from unlock_requests;
  assert v_n = v_m, format('UL-39: the Owner reads %s of %s requests', v_n, v_m);

  ---------------------------------------------------------------------------------- UL-40
  -- One open question per target, in the database and not only in the function.
  v_ok := false;
  begin
    insert into unlock_requests (target_type, target_id, requested_by, reason, status)
         values ('DAILY_REPORT', v_rA4, v_l2a, 'ซ้ำโดยตรง', 'PENDING');
  exception when unique_violation then
    v_ok := true;
  end;
  assert v_ok, 'UL-40: a second PENDING row for one day was accepted';

  ---------------------------------------------------------------------------------- UL-41
  v_ok := false;
  begin
    insert into unlock_requests (target_type, target_id, requested_by, reason, status,
                                 decided_by, decided_at)
         values ('DAILY_REPORT', v_rA2, v_l2a, 'ไม่มีวันหมดอายุ', 'APPROVED', v_owner, now());
  exception when check_violation then
    v_ok := true;
  end;
  assert v_ok, 'UL-41: an APPROVED row with no expires_at was accepted (R42)';

  ---------------------------------------------------------------------------------- UL-42
  v_key := gen_random_uuid();
  insert into unlock_requests (target_type, target_id, requested_by, reason, status,
                               decided_by, decided_at, idempotency_key)
       values ('DAILY_REPORT', v_rA6, v_l2a, 'แถวแรก', 'REJECTED', v_owner, now(), v_key);
  v_ok := false;
  begin
    insert into unlock_requests (target_type, target_id, requested_by, reason, status,
                                 decided_by, decided_at, idempotency_key)
         values ('DAILY_REPORT', v_rA5, v_l2a, 'แถวสอง', 'REJECTED', v_owner, now(), v_key);
  exception when unique_violation then
    v_ok := true;
  end;
  assert v_ok, 'UL-42: two requests shared one idempotency key';

  raise exception 'UNLOCK_TEST_PASSED';
end $$;
