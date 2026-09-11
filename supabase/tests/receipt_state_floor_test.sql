-- Card ^fix-receipt-state-floor — fn_record_lot_receipt's state guard is a floor, and the
-- upper end belongs to fn_guard_lot_closed (R8, R42).
--
-- Covers RSF-01 ... RSF-09 from v.0.1/ref-08-unlock/TDD-unlock.md.
-- Assumes no contract from an unmerged lane: unlock_requests rows are inserted directly, in
-- the column shape ...0002 created and fn_guard_lot_closed (...0013) reads.
--
-- The acceptance line, one assertion per clause:
--   a correction at LOT_CLOSED or beyond, under an approved unexpired unlock, is ACCEPTED (RSF-05);
--   the same correction without one is refused by fn_guard_lot_closed, NOT by LOT_STATE_INVALID
--   (RSF-04, RSF-06, RSF-07, RSF-08);
--   a receipt against PO_CREATED is still refused (RSF-01).
-- RSF-03 pins the behaviour change: a correction at SMOKING is accepted now.
-- RSF-09 pins what the floor must not open: an opening lot never receives.
--
-- One do $$ block that raises at the end, so nothing persists (see production_test.sql).
-- Run:  psql "$DATABASE_URL" -f supabase/tests/receipt_state_floor_test.sql

do $$
declare
  v_ok     boolean;
  v_err    text;
  v_n      bigint;
  v_kg     numeric;
  v_state  lot_state;
  v_id     uuid;
  v_day    date := date '2026-05-04';
  v_owner  uuid := gen_random_uuid();
  v_l3     uuid := gen_random_uuid();
  v_chef   uuid;
  v_sup    uuid;
  v_po     uuid;
  v_lotP   uuid;   -- PO_CREATED
  v_lotT   uuid;   -- IN_TRANSIT, first receipt
  v_lotS   uuid;   -- SMOKING
  v_lotC   uuid;   -- LOT_CLOSED, then under an unlock, then expired
  v_lotK   uuid;   -- LOT_CLOSED with a PENDING unlock only
  v_lotR   uuid;   -- RETURN_SCHEDULED
  v_lotO   uuid;   -- an opening lot
  v_unlock uuid;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',         'L1_OWNER',       true),
    (v_l3,    'ผู้ปฏิบัติงานโรงรม', 'L3_CM_OPERATOR', true);

  insert into locations (code, name_th, kind) values ('RSF1', 'โรงรมทดสอบ', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into user_locations (profile_id, location_id) values (v_l3, v_chef);
  insert into suppliers (name) values ('Foodiva RSF') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_json => 'true'::jsonb);

  v_po   := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);
  v_lotP := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotT := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotS := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotC := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotK := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotR := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);

  -- The dispatch leg is not what this card tests, so states and assignments are set directly.
  update lots set assigned_operator_id = v_l3
   where id in (v_lotP, v_lotT, v_lotS, v_lotC, v_lotK, v_lotR);
  update lots set state = 'IN_TRANSIT' where id in (v_lotT, v_lotS, v_lotC, v_lotK, v_lotR);

  -- An opening lot has no round at all (lots_round_or_opening), and ^ref-62 never assigns it
  -- an operator. This one gets one directly, because that is the only way the RPC can reach
  -- the guard for it at all.
  insert into lots (lot_code, is_opening, state, event_date, assigned_operator_id)
       values ('RSF-OPENING', true, 'LOT_CLOSED', v_day, v_l3)
    returning id into v_lotO;

  -- Every lot that must hold a receipt signs for 98 kg while IN_TRANSIT (TC-13's path).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotS, v_day, 98.00);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotC, v_day, 98.00);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotK, v_day, 98.00);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotR, v_day, 98.00);

  update lots set state = 'SMOKING'          where id = v_lotS;
  update lots set state = 'LOT_CLOSED'       where id in (v_lotC, v_lotK);
  update lots set state = 'RETURN_SCHEDULED' where id = v_lotR;

  -------------------------------------------------------------------------------- RSF-01
  -- The floor's own refusal. Meat still on Foodiva's floor cannot be signed for.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotP, v_day, 98.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_STATE_INVALID:%';
  end;
  assert v_ok, format('RSF-01: a receipt at PO_CREATED got %s', coalesce(v_err, 'no exception at all'));
  select count(*) into v_n from lot_receipts where lot_id = v_lotP;
  assert v_n = 0, format('RSF-01: a refused receipt left %s row(s)', v_n);

  -------------------------------------------------------------------------------- RSF-02
  -- The first receipt at IN_TRANSIT is unchanged, and still advances the lot.
  v_id := fn_record_lot_receipt(gen_random_uuid(), v_lotT, v_day, 98.00);
  assert v_id is not null, 'RSF-02: the IN_TRANSIT receipt returned no id';
  select state into v_state from lots where id = v_lotT;
  assert v_state = 'CM_RECEIVED', format('RSF-02: the lot is at %s, expected CM_RECEIVED', v_state);

  -------------------------------------------------------------------------------- RSF-03
  -- THE BEHAVIOUR CHANGE. The old range refused this, and nothing in R8 does.
  v_err := null; v_id := null;
  begin
    v_id := fn_record_lot_receipt(gen_random_uuid(), v_lotS, v_day, 97.00);
  exception when others then
    v_err := sqlerrm;
  end;
  assert v_id is not null, format('RSF-03: a correction at SMOKING was refused: %s', v_err);
  select received_weight_kg into v_kg from lot_receipts where lot_id = v_lotS;
  assert v_kg = 97.00, format('RSF-03: the SMOKING correction stored %s, expected 97.00', v_kg);
  select state into v_state from lots where id = v_lotS;
  assert v_state = 'SMOKING', format('RSF-03: a correction moved the lot to %s', v_state);

  -------------------------------------------------------------------------------- RSF-04
  -- Closed, no unlock: the TRIGGER refuses, by its own name. LOT_STATE_INVALID here would mean
  -- the function is still answering a question that belongs to R8.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotC, v_day, 97.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_CLOSED:%';
  end;
  assert v_ok, format('RSF-04: a correction on a closed lot got %s', coalesce(v_err, 'no exception at all'));
  assert v_err not like 'LOT_STATE_INVALID:%', 'RSF-04: the function refused before the trigger could';
  select received_weight_kg into v_kg from lot_receipts where lot_id = v_lotC;
  assert v_kg = 98.00, format('RSF-04: the refused correction left %s, expected 98.00', v_kg);

  -------------------------------------------------------------------------------- RSF-05
  -- The card's point. An approved, unexpired unlock admits the correction.
  insert into unlock_requests (target_type, target_id, requested_by, reason, status,
                               decided_by, decided_at, expires_at)
  values ('LOT', v_lotC, v_l3, 'ชั่งน้ำหนักรับเข้าผิด', 'APPROVED',
          v_owner, now(), now() + interval '1 hour')
  returning id into v_unlock;

  v_err := null; v_id := null;
  begin
    v_id := fn_record_lot_receipt(gen_random_uuid(), v_lotC, v_day, 97.00);
  exception when others then
    v_err := sqlerrm;
  end;
  assert v_id is not null, format('RSF-05: an approved, unexpired unlock was refused: %s', v_err);
  select received_weight_kg into v_kg from lot_receipts where lot_id = v_lotC;
  assert v_kg = 97.00, format('RSF-05: the admitted correction stored %s, expected 97.00', v_kg);
  select state into v_state from lots where id = v_lotC;
  assert v_state = 'LOT_CLOSED', format('RSF-05: the unlock moved the lot to %s', v_state);

  -------------------------------------------------------------------------------- RSF-06
  -- now() is fixed for the transaction, so expires_at moves behind it instead (TC-52).
  update unlock_requests set expires_at = now() - interval '1 minute' where id = v_unlock;
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotC, v_day, 96.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_CLOSED:%';
  end;
  assert v_ok, format('RSF-06: an expired unlock admitted a correction (%s)', coalesce(v_err, 'no exception at all'));
  select received_weight_kg into v_kg from lot_receipts where lot_id = v_lotC;
  assert v_kg = 97.00, format('RSF-06: the refused correction left %s, expected 97.00', v_kg);

  -------------------------------------------------------------------------------- RSF-07
  -- A request that nobody has approved admits nothing.
  insert into unlock_requests (target_type, target_id, requested_by, reason, status)
  values ('LOT', v_lotK, v_l3, 'รออนุมัติ', 'PENDING');
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotK, v_day, 97.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_CLOSED:%';
  end;
  assert v_ok, format('RSF-07: a PENDING unlock admitted a correction (%s)', coalesce(v_err, 'no exception at all'));

  -------------------------------------------------------------------------------- RSF-08
  -- "Or beyond": the enum's order carries it, and the function no longer lists states.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotR, v_day, 97.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_CLOSED:%';
  end;
  assert v_ok, format('RSF-08: a correction at RETURN_SCHEDULED got %s', coalesce(v_err, 'no exception at all'));

  -------------------------------------------------------------------------------- RSF-09
  -- What a bare floor would have opened. The trigger exempts opening lots (ADR-021), so the
  -- function's own refusal is the only thing in front of this write.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotO, v_day, 10.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_STATE_INVALID:%';
  end;
  assert v_ok, format('RSF-09: a receipt against an opening lot got %s', coalesce(v_err, 'no exception at all'));
  select count(*) into v_n from lot_receipts where lot_id = v_lotO;
  assert v_n = 0, format('RSF-09: an opening lot holds %s receipt row(s)', v_n);

  raise exception 'RECEIPT_STATE_FLOOR_TEST_PASSED';
end $$;
