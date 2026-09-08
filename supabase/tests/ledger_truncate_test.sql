-- Failure-case test: stock_ledger must refuse TRUNCATE.
--
-- ADR-003 and card ^ref-13 say the ledger "accepts INSERT only" and that a correction is
-- a reversal row plus a replacement row. schema_smoke_test.sql already covers UPDATE and
-- DELETE. TRUNCATE is neither, and a `before update or delete` trigger does not fire on
-- it — so the one statement that destroys the entire ledger in a single shot is the one
-- the guard does not see.
--
-- Everything runs in a transaction that aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/ledger_truncate_test.sql

do $$
declare
  v_user  uuid := gen_random_uuid();
  v_loc   uuid;
  v_sup   uuid;
  v_po    uuid;
  v_del   uuid;
  v_lot   uuid;
  v_count bigint;
  v_ok    boolean;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'truncatetest@example.invalid', now(), now());
  insert into profiles (id, display_name, role) values (v_user, 'truncate', 'L1_OWNER');

  insert into locations (code, name_th, kind) values ('CM9', 'ครัวกลาง', 'CHEF_HOUSE')
    returning id into v_loc;
  insert into suppliers (name) values ('Foodiva') returning id into v_sup;
  insert into purchase_orders (po_number, supplier_id, event_date, ordered_weight_kg, created_by)
    values ('PO-TRUNC', v_sup, current_date, 100, v_user) returning id into v_po;
  insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg)
    values (v_po, 1, current_date, 100) returning id into v_del;
  insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                    chef_house_location_id, event_date)
    values ('LOT-TRUNC', v_po, v_del, 100, v_loc, current_date) returning id into v_lot;

  insert into stock_ledger (idempotency_key, item_type, lot_id, location_id, stock_state,
                            movement_type, qty_delta, business_date, event_at, created_by)
    values (gen_random_uuid(), 'SMOKED_MEAT', v_lot, v_loc, 'FROZEN', 'INTAKE',
            75, current_date, now(), v_user);

  -- R1: TRUNCATE is not an INSERT, so it must be refused like UPDATE and DELETE are.
  v_ok := false;
  begin
    truncate stock_ledger cascade;
  exception when others then
    v_ok := (sqlerrm like 'LEDGER_APPEND_ONLY%');
  end;

  select count(*) into v_count from stock_ledger;
  assert v_ok, 'R1: truncate on stock_ledger should have been refused';
  assert v_count = 1, format('R1: ledger lost its rows to truncate, %s left', v_count);

  raise exception 'LEDGER_TRUNCATE_TEST_PASSED';   -- the only clean way back out
end $$;
