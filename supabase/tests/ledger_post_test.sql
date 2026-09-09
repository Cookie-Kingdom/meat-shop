-- Failure-case tests for card ^ref-14 — fn_post_ledger, the ledger write primitive.
--
-- Covers TC-01, TC-02, TC-03, TC-05, TC-06, TC-07, TC-08 from TDD-ledger-core.md.
-- TC-04 (two concurrent draws) needs two sessions and lives in
-- supabase/tests/ledger_concurrency_test.sh — a single psql session cannot prove it.
--
-- Each assert is a way the primitive fails silently rather than loudly:
--   * a retry from a dropped Chiang Mai connection double-posts, or raises so the client
--     retries forever (ADR-005, R4)
--   * a replayed key with a different payload overwrites the original figure
--   * a draw against a tuple with no rows treats SUM-of-nothing as unlimited (BR24)
--   * a meat movement lands with no lot, so no branch quantity traces to a smoke date
--     and a supplier batch (R21, ADR-017)
--   * the function writes its own audit row on top of ^ref-06's trigger, so every
--     movement is audited twice and the log stops being countable (R32)
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/ledger_post_test.sql

do $$
declare
  v_actor  uuid := '66666666-6666-6666-6666-666666666666';
  v_loc    uuid;
  v_sup    uuid;
  v_po     uuid;
  v_del    uuid;
  v_lot    uuid;
  v_day    date := current_date - 1;
  v_key1   uuid := '11111111-0000-0000-0000-000000000001';
  v_key2   uuid := '11111111-0000-0000-0000-000000000002';
  v_key3   uuid := '11111111-0000-0000-0000-000000000003';
  v_key4   uuid := '11111111-0000-0000-0000-000000000004';
  v_key5   uuid := '11111111-0000-0000-0000-000000000005';
  v_key6   uuid := '11111111-0000-0000-0000-000000000006';
  v_id     uuid;
  v_again  uuid;
  v_n      bigint;
  v_qty    numeric;
  v_ok     boolean;
  v_err    text;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_actor);
  insert into profiles (id, display_name, role, is_active)
       values (v_actor, 'ผู้บันทึกสต็อก', 'L1_OWNER', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor)::text, true);

  insert into locations (code, name_th, kind) values ('CH9', 'โรงรมทดสอบ', 'CHEF_HOUSE')
    returning id into v_loc;
  insert into suppliers (name) values ('ผู้ขายทดสอบ') returning id into v_sup;
  insert into purchase_orders (po_number, supplier_id, event_date, ordered_weight_kg, created_by)
       values ('PO-LEDGER-1', v_sup, v_day, 100.00, v_actor) returning id into v_po;
  insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg)
       values (v_po, 1, v_day, 100.00) returning id into v_del;
  insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                    chef_house_location_id, event_date)
       values ('LOT-LEDGER-1', v_po, v_del, 100.00, v_loc, v_day) returning id into v_lot;

  --------------------------------------------------------------------------------- TC-01
  -- Happy path. One movement posts one ledger row, one audit row, and returns the id.
  v_id := fn_post_ledger(
    p_idempotency_key => v_key1,
    p_item_type       => 'SMOKED_MEAT',
    p_location_id     => v_loc,
    p_stock_state     => 'FROZEN',
    p_movement_type   => 'INTAKE',
    p_qty_delta       => 10.00,
    p_business_date   => v_day,
    p_lot_id          => v_lot);

  assert v_id is not null, 'TC-01: fn_post_ledger returned null';

  select count(*) into v_n from stock_ledger where idempotency_key = v_key1;
  assert v_n = 1, format('TC-01: expected 1 ledger row, got %s', v_n);

  select qty_delta, created_by into v_qty, v_again from stock_ledger where id = v_id;
  assert v_qty = 10.00, format('TC-01: qty_delta is %s, not 10.00', v_qty);
  assert v_again = v_actor, 'TC-01: created_by is not the caller — auth.uid() is not wired in';

  -- R32: ^ref-06's generic trigger already audits stock_ledger. If the function writes its
  -- own audit row as well, every movement in the system is logged twice.
  select count(*) into v_n from audit_log where table_name = 'stock_ledger' and row_id = v_id;
  assert v_n = 1, format('TC-01: expected exactly 1 audit row for the movement, got %s', v_n);

  --------------------------------------------------------------------------------- TC-02
  -- The retry. Same key, same payload: no second row, no exception, the original id back.
  v_again := fn_post_ledger(
    p_idempotency_key => v_key1,
    p_item_type       => 'SMOKED_MEAT',
    p_location_id     => v_loc,
    p_stock_state     => 'FROZEN',
    p_movement_type   => 'INTAKE',
    p_qty_delta       => 10.00,
    p_business_date   => v_day,
    p_lot_id          => v_lot);

  assert v_again = v_id, 'TC-02: a retry did not return the original ledger id';
  select count(*) into v_n from stock_ledger where idempotency_key = v_key1;
  assert v_n = 1, format('TC-02: the retry posted a second row (%s rows)', v_n);

  --------------------------------------------------------------------------------- TC-03
  -- Same key, DIFFERENT payload. The key wins; the payload is ignored. A replay must never
  -- be able to move a figure that has already been committed.
  v_again := fn_post_ledger(
    p_idempotency_key => v_key1,
    p_item_type       => 'SMOKED_MEAT',
    p_location_id     => v_loc,
    p_stock_state     => 'FROZEN',
    p_movement_type   => 'INTAKE',
    p_qty_delta       => 999.00,
    p_business_date   => v_day,
    p_lot_id          => v_lot);

  assert v_again = v_id, 'TC-03: a replay with a different payload did not return the original id';
  select qty_delta into v_qty from stock_ledger where id = v_id;
  assert v_qty = 10.00, format('TC-03: the replay overwrote qty_delta to %s', v_qty);
  select count(*) into v_n from stock_ledger where idempotency_key = v_key1;
  assert v_n = 1, format('TC-03: the replay posted a second row (%s rows)', v_n);

  --------------------------------------------------------------------------------- TC-05
  -- A draw larger than the balance. Balance is 10.00; -11.00 must be refused and write
  -- nothing (BR24, R3).
  v_ok := false;
  begin
    perform fn_post_ledger(
      p_idempotency_key => v_key2,
      p_item_type       => 'SMOKED_MEAT',
      p_location_id     => v_loc,
      p_stock_state     => 'FROZEN',
      p_movement_type   => 'SALE',
      p_qty_delta       => -11.00,
      p_business_date   => v_day,
      p_lot_id          => v_lot);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%INSUFFICIENT_STOCK%';
  end;
  assert v_ok, format('TC-05: an over-draw was not refused with INSUFFICIENT_STOCK (%s)',
                      coalesce(v_err, 'no exception at all'));
  select count(*) into v_n from stock_ledger where idempotency_key = v_key2;
  assert v_n = 0, 'TC-05: the refused draw still wrote a row';

  -- The affordable draw of the same shape must still succeed, or the check is just "no".
  v_id := fn_post_ledger(
    p_idempotency_key => v_key3,
    p_item_type       => 'SMOKED_MEAT',
    p_location_id     => v_loc,
    p_stock_state     => 'FROZEN',
    p_movement_type   => 'SALE',
    p_qty_delta       => -4.00,
    p_business_date   => v_day,
    p_lot_id          => v_lot);
  assert v_id is not null, 'TC-05: an affordable draw was refused';

  --------------------------------------------------------------------------------- TC-06
  -- A draw against a tuple that has no rows at all. SUM of no rows is null, not zero —
  -- coalesce it wrong and an empty tuple reads as unlimited stock.
  v_ok := false;
  v_err := null;
  begin
    perform fn_post_ledger(
      p_idempotency_key => v_key4,
      p_item_type       => 'CHILLI_PASTE',
      p_location_id     => v_loc,
      p_stock_state     => 'READY',
      p_movement_type   => 'SALE',
      p_qty_delta       => -1.00,
      p_business_date   => v_day);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%INSUFFICIENT_STOCK%';
  end;
  assert v_ok, format('TC-06: a draw against an empty tuple was allowed (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-07
  -- Zero delta. Refused by the qty_delta <> 0 check constraint; assert it rather than
  -- assume it, because a future ALTER could drop the constraint unnoticed.
  v_ok := false;
  begin
    perform fn_post_ledger(
      p_idempotency_key => v_key5,
      p_item_type       => 'SMOKED_MEAT',
      p_location_id     => v_loc,
      p_stock_state     => 'FROZEN',
      p_movement_type   => 'ADJUSTMENT',
      p_qty_delta       => 0,
      p_business_date   => v_day,
      p_lot_id          => v_lot);
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'TC-07: a zero-delta movement was accepted';
  select count(*) into v_n from stock_ledger where idempotency_key = v_key5;
  assert v_n = 0, 'TC-07: the zero-delta movement wrote a row';

  --------------------------------------------------------------------------------- TC-08
  -- A meat movement with no lot. R21/ADR-017: every meat quantity names its source lot,
  -- or nothing downstream traces back to a smoke date and a supplier batch. The existing
  -- fn_require_lot_for_meat trigger guards sales_lines and waste_records, NOT stock_ledger.
  v_ok := false;
  v_err := null;
  begin
    perform fn_post_ledger(
      p_idempotency_key => v_key6,
      p_item_type       => 'SMOKED_MEAT',
      p_location_id     => v_loc,
      p_stock_state     => 'FROZEN',
      p_movement_type   => 'INTAKE',
      p_qty_delta       => 5.00,
      p_business_date   => v_day);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%LOT_REQUIRED%';
  end;
  assert v_ok, format('TC-08: a SMOKED_MEAT movement with no lot_id was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  raise exception 'LEDGER_POST_TEST_PASSED';   -- the only clean way back out
end $$;
