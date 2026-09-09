-- Failure-case tests for card ^ref-15 — v_stock_balance and v_smoke_group_available.
--
-- Covers TC-09, TC-10 and TC-19 from TDD-ledger-core.md. TC-22 (200ms at one year of
-- data) stays Manual — it is a measurement, not an assert.
--
-- Each assert is a way the read layer fails silently rather than loudly:
--   * balance is computed off something other than SUM(qty_delta), so it can drift
--   * two lots sharing a smoke date are merged into one pickable row, and the FIFO
--     picker can no longer name which lot a branch quantity came from (D01, D05, R21)
--   * the picking list is not oldest-first, so FIFO is advisory
--   * an L3 session can read stock (R20, ADR-004, UAT-15)
--
-- On TC-19: the TDD says "refused". There is one database role for application users —
-- `authenticated` — and L1/L2/L3 is a column on `profiles`, so there is nothing to revoke
-- from L3 alone. The view filters on fn_current_role() instead and an L3 session gets
-- zero rows. Still the database deciding, still nothing the UI can undo. PLAN D3.
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/ledger_views_test.sql

do $$
declare
  v_owner uuid := '88888888-8888-8888-8888-888888888881';
  v_cm    uuid := '88888888-8888-8888-8888-888888888883';
  v_loc   uuid;
  v_sup   uuid;
  v_po    uuid;
  v_del   uuid;
  v_del2  uuid;
  v_lot_a uuid;
  v_lot_b uuid;
  v_grp_a uuid;
  v_grp_b uuid;
  v_grp_c uuid;
  v_day   date := current_date - 1;
  v_d1    date := current_date - 5;
  v_d2    date := current_date - 3;
  v_qty   numeric;
  v_n     bigint;
  v_first date;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_cm);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',      'L1_OWNER',       true),
    (v_cm,    'ผู้ปฏิบัติ CM', 'L3_CM_OPERATOR', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  insert into locations (code, name_th, kind) values ('CH7', 'โรงรมทดสอบ', 'CHEF_HOUSE')
    returning id into v_loc;
  insert into suppliers (name) values ('ผู้ขายทดสอบ') returning id into v_sup;
  insert into purchase_orders (po_number, supplier_id, event_date, ordered_weight_kg, created_by)
       values ('PO-VIEW-1', v_sup, v_day, 200.00, v_owner) returning id into v_po;
  -- One delivery per lot: lots.po_delivery_id is UNIQUE, a dispatch round becomes one lot.
  insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg)
       values (v_po, 1, v_day, 100.00) returning id into v_del;

  -- Two lots. D01/D05: they share a smoke date, and that must not make the lot ambiguous.
  insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                    chef_house_location_id, event_date)
       values ('LOT-VIEW-A', v_po, v_del, 100.00, v_loc, v_day) returning id into v_lot_a;
  insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg)
       values (v_po, 2, v_day, 100.00) returning id into v_del2;
  insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                    chef_house_location_id, event_date)
       values ('LOT-VIEW-B', v_po, v_del2, 100.00, v_loc, v_day) returning id into v_lot_b;

  insert into smoke_date_groups (lot_id, smoke_date) values (v_lot_a, v_d1) returning id into v_grp_a;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lot_b, v_d1) returning id into v_grp_b;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lot_a, v_d2) returning id into v_grp_c;

  --------------------------------------------------------------------------------- TC-09
  -- Balance is the sum of the movements, and one tuple is one row.
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_loc, 'FROZEN', 'INTAKE',
                          10.00, v_day, now(), null, null, v_lot_a, v_grp_a);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_loc, 'FROZEN', 'SALE',
                          -3.00, v_day, now(), null, null, v_lot_a, v_grp_a);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_loc, 'FROZEN', 'INTAKE',
                           1.00, v_day, now(), null, null, v_lot_a, v_grp_a);

  select count(*) into v_n from v_stock_balance
   where lot_id = v_lot_a and smoke_date_group_id = v_grp_a;
  assert v_n = 1, format('TC-09: expected 1 balance row for the tuple, got %s', v_n);

  select balance_qty into v_qty from v_stock_balance
   where lot_id = v_lot_a and smoke_date_group_id = v_grp_a;
  assert v_qty = 8.00, format('TC-09: balance is %s, expected 8.00 (+10 -3 +1)', v_qty);

  --------------------------------------------------------------------------------- TC-10
  -- Stock on both D1 lots and on the D2 lot.
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_loc, 'FROZEN', 'INTAKE',
                          5.00, v_day, now(), null, null, v_lot_b, v_grp_b);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_loc, 'FROZEN', 'INTAKE',
                          7.00, v_day, now(), null, null, v_lot_a, v_grp_c);

  -- Two lots on the older smoke date must be TWO rows, each naming its own lot. Merging
  -- them is what makes a branch quantity untraceable back to a supplier batch (ADR-017).
  select count(*), count(distinct lot_id) into v_n, v_qty
    from v_smoke_group_available where smoke_date = v_d1;
  assert v_n = 2, format('TC-10: expected 2 rows on the shared smoke date, got %s', v_n);
  assert v_qty = 2, format('TC-10: the 2 rows name %s distinct lot(s), expected 2', v_qty);

  -- Oldest smoke date first, or FIFO is only advice.
  select smoke_date into v_first from v_smoke_group_available limit 1;
  assert v_first = v_d1,
    format('TC-10: the picking list starts at %s, not the oldest smoke date %s', v_first, v_d1);

  -- A drawn-down group leaves the list; a zero balance is not pickable.
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_loc, 'FROZEN', 'SALE',
                          -5.00, v_day, now(), null, null, v_lot_b, v_grp_b);
  select count(*) into v_n from v_smoke_group_available where smoke_date_group_id = v_grp_b;
  assert v_n = 0, 'TC-10: a group drawn to zero is still offered as pickable';

  --------------------------------------------------------------------------------- TC-19
  -- An L3 session reads no stock. PLAN D3: zero rows, not an error.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  set local role authenticated;

  select count(*) into v_n from v_stock_balance;
  assert v_n = 0, format('R20: an L3 session read %s row(s) of v_stock_balance', v_n);
  select count(*) into v_n from v_smoke_group_available;
  assert v_n = 0, format('R20: an L3 session read %s row(s) of v_smoke_group_available', v_n);

  reset role;

  -- And the Owner still sees it, or the filter is just "deny everyone".
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  set local role authenticated;
  select count(*) into v_n from v_stock_balance;
  assert v_n > 0, 'R20: the Owner reads nothing either — the view filter denies everyone';
  reset role;

  raise exception 'LEDGER_VIEWS_TEST_PASSED';   -- the only clean way back out
end $$;
