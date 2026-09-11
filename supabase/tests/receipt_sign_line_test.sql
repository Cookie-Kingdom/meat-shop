-- Card ^fix-cm02-sign-line — CM 02 signs the lot's Foodiva -> CM truck, in the same transaction
-- as the receipt row (fn_record_lot_receipt -> fn_confirm_transport_receipt).
--
-- Covers SL-01 ... SL-08 from v.0.1/ready-fix-cm02-sign-line/TDD-cm02-sign-line.md.
-- The path with no line at all is production_test.sql TC-14, unchanged.
--
-- The acceptance line, one assertion per clause:
--   the unsigned FOODIVA_TO_CM line is signed with CM 02's weight and reason, as the chef (SL-01);
--   OW 02's ค้างรับ no longer lists it as unsigned; a short receipt stays as a partial (SL-01, SL-02);
--   the chef house holds the received weight FROZEN on (lot, group = null) (SL-01, SL-02);
--   a correction after signing does not sign it twice (SL-03, SL-04).
-- SL-05 ... SL-08 are the refusals and the bound.
--
-- One do $$ block that raises at the end, so nothing persists (see production_test.sql).
-- Run:  psql "$DATABASE_URL" -f supabase/tests/receipt_sign_line_test.sql

do $$
declare
  v_ok     boolean;
  v_err    text;
  v_n      bigint;
  v_kg     numeric;
  v_txt    text;
  v_who    uuid;
  v_key    uuid;
  v_rec    uuid;
  v_rec2   uuid;
  v_day    date := date '2026-05-04';
  v_owner  uuid := gen_random_uuid();
  v_l3     uuid := gen_random_uuid();
  v_chef   uuid;
  v_sup    uuid;
  v_po     uuid;
  v_run    uuid;
  v_lotA   uuid;   -- full receipt, then replay, CM 03 and a correction
  v_lotB   uuid;   -- short receipt
  v_lotC   uuid;   -- refused: no reason
  v_lotD   uuid;   -- refused: partial receipt off
  v_lotE   uuid;   -- two trucks
  v_lotF   uuid;   -- closed, under an unlock
  v_lineA  uuid;
  v_lineB  uuid;
  v_lineC  uuid;
  v_lineF  uuid;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',         'L1_OWNER',       true),
    (v_l3,    'ผู้ปฏิบัติงานโรงรม', 'L3_CM_OPERATOR', true);

  insert into locations (code, name_th, kind) values ('SL1', 'โรงรมทดสอบ', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into user_locations (profile_id, location_id) values (v_l3, v_chef);
  insert into suppliers (name) values ('Foodiva SL') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', date '2026-01-01',
                        p_value_text => 'BY_LOT_WEIGHT');
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', date '2026-01-01',
                        p_value_text => 'true');
  -- SL-06 receives on this date and no other test does (transport_test.sql TC-24's shape).
  perform fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', date '2026-06-01',
                        p_value_text => 'false');

  v_po   := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);
  v_lotA := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotB := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotC := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotD := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotE := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotF := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);

  perform fn_assign_lot_operator(gen_random_uuid(), l, v_l3)
     from unnest(array[v_lotA, v_lotB, v_lotC, v_lotD, v_lotE, v_lotF]) l;

  -- One truck per lot, as D01 makes them — except lot E, which goes on two.
  v_run   := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', v_day, 'รถกระบะ', false, 4500.00);
  v_lineA := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotA, null, null, v_chef, 100.00);
  v_lineB := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotB, null, null, v_chef, 100.00);
  v_lineC := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotC, null, null, v_chef, 100.00);
  perform    fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotD, null, null, v_chef, 100.00);
  perform    fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotE, null, null, v_chef, 60.00);
  v_lineF := fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotF, null, null, v_chef, 100.00);
  v_run   := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', v_day, 'รถกระบะ', false, 3000.00);
  perform    fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotE, null, null, v_chef, 40.00);

  -- Lot F closed before this fix, with its truck never signed. Set directly: the close is not
  -- what this card tests, and a real close would need smoke logs and bags.
  update lots set state = 'LOT_CLOSED' where id = v_lotF;
  insert into unlock_requests (target_type, target_id, requested_by, reason, status,
                               decided_by, decided_at, expires_at)
  values ('LOT', v_lotF, v_l3, 'ชั่งน้ำหนักรับเข้าผิด', 'APPROVED',
          v_owner, now(), now() + interval '1 hour');

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);

  -------------------------------------------------------------------------------- SL-01
  -- THE DEFECT. CM 02 at the full weight signs the truck and puts the meat on the shelf.
  v_key := gen_random_uuid();
  v_rec := fn_record_lot_receipt(v_key, v_lotA, v_day + 1, 100.00);

  select received_weight_kg, received_by, receipt_idempotency_key::text
    into v_kg, v_who, v_txt
    from transport_lines where id = v_lineA;
  assert v_kg = 100.00,
    format('SL-01: CM 02 left the Foodiva -> CM line at %s, not signed at 100.00', coalesce(v_kg::text, 'unsigned'));
  assert v_who = v_l3, 'SL-01: the line was not signed by the calling chef';
  assert v_txt = v_key::text, 'SL-01: the line was not signed under CM 02''s own key';

  select coalesce(sum(qty_delta), 0) into v_kg from stock_ledger
   where lot_id = v_lotA and location_id = v_chef and smoke_date_group_id is null
     and stock_state = 'FROZEN';
  assert v_kg = 100.00, format('SL-01: the chef house holds %s kg FROZEN of lot A, expected 100.00', v_kg);

  select coalesce(sum(qty_delta), 0) into v_kg from stock_ledger
   where lot_id = v_lotA and location_id = v_chef and stock_state = 'IN_TRANSIT';
  assert v_kg = 0, format('SL-01: %s kg of lot A still on the truck', v_kg);

  select count(*) into v_n from lot_receipts where lot_id = v_lotA;
  assert v_n = 1, format('SL-01: %s receipt rows for lot A', v_n);
  select state::text into v_txt from lots where id = v_lotA;
  assert v_txt = 'CM_RECEIVED', format('SL-01: lot A is at %s, not CM_RECEIVED', v_txt);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_outstanding_receipts where lot_id = v_lotA;
  assert v_n = 0, format('SL-01: OW 02 still lists lot A in ค้างรับ (%s row(s))', v_n);
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);

  -------------------------------------------------------------------------------- SL-02
  -- A short receipt signs at what arrived; the shortfall stays on the truck as a partial,
  -- listed in ค้างรับ until D06 settlement (the amended acceptance line).
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotB, v_day + 1, 98.00);

  select received_weight_kg into v_kg from transport_lines where id = v_lineB;
  assert v_kg = 98.00, format('SL-02: the line was signed at %s, not 98.00', coalesce(v_kg::text, 'unsigned'));

  select coalesce(sum(qty_delta), 0) into v_kg from stock_ledger
   where lot_id = v_lotB and location_id = v_chef and smoke_date_group_id is null
     and stock_state = 'FROZEN';
  assert v_kg = 98.00, format('SL-02: the chef house holds %s kg FROZEN of lot B, expected 98.00', v_kg);

  select coalesce(sum(qty_delta), 0) into v_kg from stock_ledger
   where lot_id = v_lotB and location_id = v_chef and stock_state = 'IN_TRANSIT';
  assert v_kg = 2.00, format('SL-02: %s kg of lot B left on the truck, expected 2.00', v_kg);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select outstanding_weight_kg into v_kg from v_outstanding_receipts where lot_id = v_lotB;
  assert v_kg = 2.00,
    format('SL-02: OW 02 shows lot B at %s outstanding, expected a partial of 2.00', coalesce(v_kg::text, 'no row'));
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);

  -------------------------------------------------------------------------------- SL-03
  -- A dropped connection replays SL-01 under the same key.
  select count(*) into v_n from stock_ledger where lot_id = v_lotA;
  v_rec2 := fn_record_lot_receipt(v_key, v_lotA, v_day + 1, 100.00);
  assert v_rec2 = v_rec, 'SL-03: the replay returned a different receipt id';
  assert (select count(*) from stock_ledger where lot_id = v_lotA) = v_n,
    'SL-03: the replay posted ledger rows';

  -------------------------------------------------------------------------------- SL-04
  -- CM 03, then a correction, each under a new key. The line is already signed: neither
  -- visit signs it again, and neither is refused for trying (LINE_ALREADY_RECEIVED).
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotA, v_day + 1, 100.00, 96.50);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotA, v_day + 1, 99.00);

  assert (select count(*) from stock_ledger where lot_id = v_lotA) = v_n,
    'SL-04: CM 03 or the correction posted ledger rows';
  select received_weight_kg into v_kg from transport_lines where id = v_lineA;
  assert v_kg = 100.00, format('SL-04: the correction moved the signed line to %s', v_kg);
  select received_weight_kg into v_kg from lot_receipts where lot_id = v_lotA;
  assert v_kg = 99.00, format('SL-04: the correction left the receipt at %s, expected 99.00', v_kg);

  -------------------------------------------------------------------------------- SL-05
  -- One transaction. 70 of 100 with no reason is refused, and the truck stays unsigned.
  select count(*) into v_n from stock_ledger where lot_id = v_lotC;
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotC, v_day + 1, 70.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'VARIANCE_REASON_REQUIRED:%';
  end;
  assert v_ok, format('SL-05: 70 of 100 with no reason got %s', coalesce(v_err, 'no exception at all'));
  select receipt_idempotency_key::text into v_txt from transport_lines where id = v_lineC;
  assert v_txt is null, 'SL-05: the refused receipt still signed the truck';
  assert (select count(*) from stock_ledger where lot_id = v_lotC) = v_n,
    'SL-05: the refused receipt posted ledger rows';
  assert not exists (select 1 from lot_receipts where lot_id = v_lotC),
    'SL-05: the refused receipt wrote a receipt row';
  select state::text into v_txt from lots where id = v_lotC;
  assert v_txt = 'IN_TRANSIT', format('SL-05: the refused receipt moved lot C to %s', v_txt);

  -------------------------------------------------------------------------------- SL-06
  -- The movement's own rules still run: partial receipt is off on this date.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotD, date '2026-06-01', 95.00,
                                  null, 'เนื้อหายระหว่างทาง');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'PARTIAL_RECEIPT_NOT_ALLOWED:%';
  end;
  assert v_ok, format('SL-06: a short receipt with partial receipt off got %s', coalesce(v_err, 'no exception at all'));
  assert not exists (select 1 from lot_receipts where lot_id = v_lotD),
    'SL-06: the refused receipt wrote a receipt row';

  -------------------------------------------------------------------------------- SL-07
  -- Two trucks, one weight: refused rather than guessed.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotE, v_day + 1, 100.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'RECEIPT_LINE_AMBIGUOUS:%';
  end;
  assert v_ok, format('SL-07: a lot on two trucks got %s', coalesce(v_err, 'no exception at all'));
  select count(*) into v_n from transport_lines where lot_id = v_lotE and receipt_idempotency_key is not null;
  assert v_n = 0, format('SL-07: %s of lot E''s trucks were signed', v_n);
  assert not exists (select 1 from lot_receipts where lot_id = v_lotE),
    'SL-07: the refused receipt wrote a receipt row';

  -------------------------------------------------------------------------------- SL-08
  -- A closed lot's old unsigned truck stays unsigned: its close drew no raw weight, and
  -- nothing would ever draw it now.
  select count(*) into v_n from stock_ledger where lot_id = v_lotF;
  v_err := null; v_rec := null;
  begin
    v_rec := fn_record_lot_receipt(gen_random_uuid(), v_lotF, v_day + 1, 97.00);
  exception when others then
    v_err := sqlerrm;
  end;
  assert v_rec is not null, format('SL-08: the unlocked correction was refused: %s', v_err);
  select received_weight_kg into v_kg from lot_receipts where lot_id = v_lotF;
  assert v_kg = 97.00, format('SL-08: the correction stored %s, expected 97.00', v_kg);
  select receipt_idempotency_key::text into v_txt from transport_lines where id = v_lineF;
  assert v_txt is null, 'SL-08: CM 02 signed a closed lot''s truck';
  assert (select count(*) from stock_ledger where lot_id = v_lotF) = v_n,
    'SL-08: CM 02 posted ledger rows for a closed lot';

  raise exception 'RECEIPT_SIGN_LINE_TEST_PASSED';
end $$;
