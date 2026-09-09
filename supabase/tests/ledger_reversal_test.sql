-- Failure-case tests for card ^ref-16 — fn_reverse_ledger_entry.
--
-- Covers TC-11, TC-12, TC-13 from TDD-ledger-core.md.
--
-- Each assert is a way a correction fails silently rather than loudly:
--   * the original row is edited or removed instead of reversed, so the trail of what was
--     first believed is gone (ADR-003, R1)
--   * the reversal does not link back, so nothing downstream can pair them (R2)
--   * a row is reversed twice, and the tuple loses stock that was never there
--   * a REVERSAL row is itself reversed, which nets to the original and reads as a
--     third opinion about the same movement
--   * a retry of the pair double-posts, because the two rows do not share one derived key
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/ledger_reversal_test.sql

do $$
declare
  v_actor uuid := '99999999-9999-9999-9999-999999999999';
  v_loc   uuid;
  v_sup   uuid;
  v_po    uuid;
  v_del   uuid;
  v_lot   uuid;
  v_day   date := current_date - 1;
  v_orig  uuid;
  v_rev   uuid;
  v_repl  uuid;
  v_rev2  uuid;
  v_repl2 uuid;
  v_key   uuid := '22222222-0000-0000-0000-000000000001';
  v_key2  uuid := '22222222-0000-0000-0000-000000000002';
  v_key3  uuid := '22222222-0000-0000-0000-000000000003';
  v_l     stock_ledger%rowtype;
  v_qty   numeric;
  v_n     bigint;
  v_ok    boolean;
  v_err   text;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_actor);
  insert into profiles (id, display_name, role, is_active)
       values (v_actor, 'เจ้าของ', 'L1_OWNER', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor)::text, true);

  insert into locations (code, name_th, kind) values ('CH6', 'โรงรมทดสอบ', 'CHEF_HOUSE')
    returning id into v_loc;
  insert into suppliers (name) values ('ผู้ขายทดสอบ') returning id into v_sup;
  insert into purchase_orders (po_number, supplier_id, event_date, ordered_weight_kg, created_by)
       values ('PO-REV-1', v_sup, v_day, 100.00, v_actor) returning id into v_po;
  insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg)
       values (v_po, 1, v_day, 100.00) returning id into v_del;
  insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                    chef_house_location_id, event_date)
       values ('LOT-REV-1', v_po, v_del, 100.00, v_loc, v_day) returning id into v_lot;

  -- The row that was entered wrong: 10.00 kg, where it should have been 12.00.
  v_orig := fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_loc, 'FROZEN', 'INTAKE',
                            10.00, v_day, now(), null, null, v_lot);

  --------------------------------------------------------------------------------- TC-11
  select reversal_id, replacement_id into v_rev, v_repl
    from fn_reverse_ledger_entry(v_key, v_orig, 12.00, 'ชั่งผิด');

  -- The original is still readable. This is the whole point of ADR-003: a correction adds
  -- rows, it never removes the evidence of what was first believed.
  select * into v_l from stock_ledger where id = v_orig;
  assert found, 'TC-11: the original row is gone — it was edited, not reversed';
  assert v_l.qty_delta = 10.00,
    format('TC-11: the original now reads %s; it was modified', v_l.qty_delta);

  select * into v_l from stock_ledger where id = v_rev;
  assert v_l.movement_type = 'REVERSAL',
    format('TC-11: the reversal row is a %s, not a REVERSAL', v_l.movement_type);
  assert v_l.qty_delta = -10.00,
    format('TC-11: the reversal is %s, expected -10.00', v_l.qty_delta);
  assert v_l.reversal_of = v_orig,
    'TC-11: the reversal does not link back to the original (R2)';

  select * into v_l from stock_ledger where id = v_repl;
  assert v_l.qty_delta = 12.00,
    format('TC-11: the replacement is %s, expected 12.00', v_l.qty_delta);
  assert v_l.reversal_of is null,
    'TC-11: the replacement is marked as a reversal — only the reversing row is';
  assert v_l.business_date = v_day,
    'TC-11: the replacement moved the business date; a correction belongs to the day it happened (ADR-007)';

  select balance_qty into v_qty from v_stock_balance
   where lot_id = v_lot and stock_state = 'FROZEN';
  assert v_qty = 12.00, format('TC-11: balance is %s after the correction, expected 12.00', v_qty);

  -- The pair is idempotent as a pair. A retry writes nothing new and hands back the same
  -- two ids, or a dropped connection turns one correction into two.
  select reversal_id, replacement_id into v_rev2, v_repl2
    from fn_reverse_ledger_entry(v_key, v_orig, 12.00, 'ชั่งผิด');
  assert v_rev2 = v_rev and v_repl2 = v_repl,
    'TC-11: a retry of the correction returned different rows';
  select count(*) into v_n from stock_ledger where lot_id = v_lot;
  assert v_n = 3, format('TC-11: expected 3 ledger rows after a retried correction, got %s', v_n);

  --------------------------------------------------------------------------------- TC-12
  -- Reversing the same row again, under a fresh key. Refused: the row is already answered.
  v_ok := false;
  begin
    perform fn_reverse_ledger_entry(v_key2, v_orig, 5.00, 'อีกครั้ง');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%ALREADY_REVERSED%';
  end;
  assert v_ok, format('TC-12: a second reversal of the same row was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));
  select count(*) into v_n from stock_ledger where lot_id = v_lot;
  assert v_n = 3, format('TC-12: the refused reversal still wrote rows (%s total)', v_n);

  --------------------------------------------------------------------------------- TC-13
  -- Reversing a REVERSAL row. Refused: it nets back to the original and reads as a third
  -- opinion about one movement.
  v_ok := false;
  v_err := null;
  begin
    perform fn_reverse_ledger_entry(v_key3, v_rev, null, 'กลับรายการของรายการกลับ');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%NOT_REVERSIBLE%';
  end;
  assert v_ok, format('TC-13: a REVERSAL row was itself reversed (%s)',
                      coalesce(v_err, 'no exception at all'));

  raise exception 'LEDGER_REVERSAL_TEST_PASSED';   -- the only clean way back out
end $$;
