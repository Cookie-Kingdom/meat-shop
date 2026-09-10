-- Smoke test for the three triggers that carry real logic:
--   R6a  smoke_daily_logs.input_weight_kg is the sum of its sources
--   R21  SMOKED_MEAT sales/waste lines must name a lot
--   R1   stock_ledger is insert-only
-- Everything happens in one transaction that aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/schema_smoke_test.sql

do $$
declare
  v_user uuid := gen_random_uuid();
  v_loc  uuid;
  v_sup  uuid;
  v_po   uuid;
  v_del  uuid;
  v_lot  uuid;
  v_log  uuid;
  v_prod uuid;
  v_rep  uuid;
  v_led  uuid;
  v_sum  numeric;
  v_ok   boolean;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'smoketest@example.invalid', now(), now());
  insert into profiles (id, display_name, role) values (v_user, 'smoke', 'L1_OWNER');

  insert into locations (code, name_th, kind) values ('CM1', 'ครัวกลาง', 'CHEF_HOUSE')
    returning id into v_loc;
  insert into suppliers (name) values ('Foodiva') returning id into v_sup;
  insert into purchase_orders (po_number, supplier_id, event_date, ordered_weight_kg, created_by)
    values ('PO-SMOKE', v_sup, current_date, 100, v_user) returning id into v_po;
  insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg)
    values (v_po, 1, current_date, 100) returning id into v_del;
  insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                    chef_house_location_id, event_date)
    values ('LOT-SMOKE', v_po, v_del, 100, v_loc, current_date) returning id into v_lot;

  -- R6a: input_weight_kg rolls up from the sources, it is never typed in.
  insert into smoke_daily_logs (lot_id, event_date, recorded_by)
    values (v_lot, current_date, v_user) returning id into v_log;
  insert into smoke_daily_log_sources (smoke_daily_log_id, lot_id, input_weight_kg)
    values (v_log, v_lot, 60);
  select input_weight_kg into v_sum from smoke_daily_logs where id = v_log;
  assert v_sum = 60, format('R6a: expected 60 after insert, got %s', v_sum);

  delete from smoke_daily_log_sources where smoke_daily_log_id = v_log;
  select input_weight_kg into v_sum from smoke_daily_logs where id = v_log;
  assert v_sum = 0, format('R6a: expected 0 after delete, got %s', v_sum);

  -- R21: a meat sale line without a lot is refused.
  -- MEAT_BOX is seeded by migration ...0018 (^ref-42), so this reads it rather than creating
  -- it. A second insert would be a unique violation on products.code.
  select id into v_prod from products where code = 'MEAT_BOX';
  -- shift_started_at is NOT NULL as of migration ...0009 (^ref-38, Finding 3): a report with
  -- no shift open makes ADR-014 undecidable for that row. fn_open_daily_report always sets
  -- now(); this fixture inserts directly, so it has to say so itself.
  insert into daily_reports (location_id, report_date, shift_started_at)
    values (v_loc, current_date, now())
    returning id into v_rep;

  -- created_by is NOT NULL as of migration ...0018 (^ref-42, R32), so both inserts name it.
  v_ok := false;
  begin
    insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, created_by)
      values (v_rep, v_prod, 1, 350, v_user);
  exception when others then
    v_ok := (sqlerrm like 'LOT_REQUIRED%');
  end;
  assert v_ok, 'R21: meat sale line without lot_id should have been refused';

  insert into sales_lines (daily_report_id, product_id, lot_id, qty, unit_price_thb, created_by)
    values (v_rep, v_prod, v_lot, 1, 350, v_user);   -- with a lot it goes through

  -- R1: the ledger takes inserts and nothing else.
  insert into stock_ledger (idempotency_key, item_type, lot_id, location_id, stock_state,
                            movement_type, qty_delta, business_date, event_at, created_by)
    values (gen_random_uuid(), 'SMOKED_MEAT', v_lot, v_loc, 'FROZEN', 'INTAKE',
            75, current_date, now(), v_user)
    returning id into v_led;

  v_ok := false;
  begin
    update stock_ledger set qty_delta = 1 where id = v_led;
  exception when others then
    v_ok := (sqlerrm like 'LEDGER_APPEND_ONLY%');
  end;
  assert v_ok, 'R1: update on stock_ledger should have been refused';

  v_ok := false;
  begin
    delete from stock_ledger where id = v_led;
  exception when others then
    v_ok := (sqlerrm like 'LEDGER_APPEND_ONLY%');
  end;
  assert v_ok, 'R1: delete on stock_ledger should have been refused';

  raise exception 'SMOKE_TEST_PASSED';   -- the only clean way back out
end $$;
