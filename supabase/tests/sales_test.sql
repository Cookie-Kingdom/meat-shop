-- Failure-case tests for card ^ref-43: fn_record_sales.
--
-- Contracts assumed from an unmerged lane (lane B, ^ref-40):
--   * fn_require_branch_or_owner(uuid) -> uuid, per PLAN-thaw.md T3;
--   * fn_record_thaw(p_idempotency_key, p_daily_report_id, p_lot_id, p_smoke_date_group_id,
--     p_thawed_weight_kg, p_fifo_override_reason) -> json, per PLAN-thaw.md T5, posting THAW_IN
--     on (SMOKED_MEAT, product NULL, lot, group, branch, READY).
-- The READY stock every sale below draws on is put there by that thaw, as UAT-10 describes.
--
-- Covers TC-16 ... TC-31 of TDD-sales.md, with TC-16 read through PLAN-sales.md B1 (v0.2:57:
-- L1 may sell at any branch). Three cases are added: B2's replay after close, B14's
-- PACK_WEIGHT_INVALID, and a two-line batch that fails on its second line and writes nothing.
-- TC-53 needs two sessions and lives in sales_concurrency_test.sh.
--
-- Each assert catches a way this function fails silently rather than loudly:
--   * a meat sale draws FROZEN and the frozen balance falls (R14)
--   * a sale is priced from today's price, not from the business date's (BR23)
--   * rice or water posts a ledger row, and the first bowl sold raises INSUFFICIENT_STOCK
--   * selling meat also deducts chilli (M6)
--   * a replay writes the batch twice, or a replay that grew inserts its extra lines (R39)
--   * the batch key goes straight to fn_post_ledger, and lines 2 to 5 silently return line 1's id
--   * a partial batch commits its first lines when a later line fails
--   * a retry that lands after the close reads REPORT_CLOSED for a write that succeeded (R4)
--
-- Errors are captured into v_err and asserted after the block, never inside a `when others`
-- handler (see branch_daily_test.sql's header).
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/sales_test.sql

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_off    uuid := gen_random_uuid();   -- a deactivated Owner holding a live token
  v_adm_a  uuid := gen_random_uuid();   -- L2 at branch A
  v_adm_b  uuid := gen_random_uuid();   -- L2 at branch B
  v_cm     uuid := gen_random_uuid();   -- L3, and a member of branch A
  v_day    date := date '2026-05-04';
  v_bra    uuid;
  v_brb    uuid;
  v_lotA   uuid;
  v_lotB   uuid;
  v_gA     uuid;
  v_gB     uuid;
  v_rep    uuid;                        -- branch A, v_day
  v_repb   uuid;                        -- branch B, v_day
  v_rep4   uuid;                        -- branch B, four days back
  v_rep3   uuid;                        -- branch B, three days back
  v_box    uuid;
  v_addon  uuid;
  v_chilli uuid;
  v_rice   uuid;
  v_water  uuid;
  v_k1     uuid := gen_random_uuid();
  v_k2     uuid := gen_random_uuid();
  v_k3     uuid := gen_random_uuid();
  v_k5     uuid := gen_random_uuid();
  v_lines  jsonb;
  v_five   jsonb;
  v_res    json;
  v_ids    uuid[];
  v_ids2   uuid[];
  v_err    text;
  v_ok     boolean;
  v_n      bigint;
  v_n2     bigint;
  v_led    bigint;
  v_rows   bigint;
  v_kg     numeric;
  v_txt    text;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_off), (v_adm_a), (v_adm_b), (v_cm);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',                'L1_OWNER',        true),
    (v_off,   'เจ้าของที่ปิดบัญชีแล้ว',      'L1_OWNER',        false),
    (v_adm_a, 'แอดมินสาขาเอ',            'L2_BRANCH_ADMIN', true),
    (v_adm_b, 'แอดมินสาขาบี',            'L2_BRANCH_ADMIN', true),
    (v_cm,    'ผู้ปฏิบัติงานเชียงใหม่',      'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind, rice_model)
       values ('BRA43', 'สาขาเอ', 'BRANCH', 'EXTERNAL_COOKED') returning id into v_bra;
  insert into locations (code, name_th, kind, rice_model)
       values ('BRB43', 'สาขาบี', 'BRANCH', 'SELF_COOK') returning id into v_brb;
  -- The L3 is a member of branch A. TC-16 is a real test only because of this row.
  insert into user_locations (profile_id, location_id) values
    (v_adm_a, v_bra), (v_adm_b, v_brb), (v_cm, v_bra);

  -- Two lots smoked on ONE date: D01's ordinary afternoon, and TC-23's two lines. Opening-lot
  -- shape (^ref-62), inserted directly, because the chain that smokes a lot is not under test.
  insert into lots (lot_code, is_opening, state, event_date)
       values ('LOT-43A', true, 'LOT_CLOSED', v_day - 5) returning id into v_lotA;
  insert into lots (lot_code, is_opening, state, event_date)
       values ('LOT-43B', true, 'LOT_CLOSED', v_day - 5) returning id into v_lotB;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotA, v_day - 5) returning id into v_gA;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lotB, v_day - 5) returning id into v_gB;

  select id into v_box    from products where code = 'MEAT_BOX';
  select id into v_addon  from products where code = 'MEAT_ADDON_SEALED';
  select id into v_chilli from products where code = 'CHILLI_TUBE';
  select id into v_rice   from products where code = 'RICE_KG';
  select id into v_water  from products where code = 'WATER_BOTTLE';

  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_bra, v_day, now(), v_adm_a) returning id into v_rep;
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_brb, v_day, now(), v_adm_b) returning id into v_repb;

  -- Frozen meat and chilli land at branch A directly, because the legs that bring them are
  -- not under test. Chilli lands on fn_record_opening_balance's tuple: READY, with its
  -- product id, and no lot.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_bra, 'FROZEN', 'TRANSFER_IN',
                         10.00, v_day - 1, p_lot_id => v_lotA, p_smoke_date_group_id => v_gA);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_bra, 'FROZEN', 'TRANSFER_IN',
                         5.00, v_day - 1, p_lot_id => v_lotB, p_smoke_date_group_id => v_gB);
  perform fn_post_ledger(gen_random_uuid(), 'CHILLI_PASTE', v_bra, 'READY', 'TRANSFER_IN',
                         100, v_day - 1, p_product_id => v_chilli);

  -- UAT-10's first half, through lane B's thaw: 3.00 of lot A's 10.00, and 1.00 of lot B.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  perform fn_record_thaw(p_idempotency_key     => gen_random_uuid(),
                         p_daily_report_id     => v_rep,
                         p_lot_id              => v_lotA,
                         p_smoke_date_group_id => v_gA,
                         p_thawed_weight_kg    => 3.00);
  perform fn_record_thaw(p_idempotency_key     => gen_random_uuid(),
                         p_daily_report_id     => v_rep,
                         p_lot_id              => v_lotB,
                         p_smoke_date_group_id => v_gB,
                         p_thawed_weight_kg    => 1.00);

  v_lines := jsonb_build_array(jsonb_build_object(
    'product_code', 'MEAT_BOX', 'qty', 12, 'lot_id', v_lotA, 'smoke_date_group_id', v_gA));

  ------------------------------------------------------------------- guards, before any row
  --------------------------------------------------------------------------------- TC-16
  -- As B1 rewrites it. The L3 holds a user_locations row at branch A and is refused on ROLE.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, v_lines);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-16: an L3 recorded a sale, got [%s]', coalesce(v_err, 'no error at all'));

  -- Right role, wrong branch.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, v_lines);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN_LOCATION%',
    format('TC-16: branch B''s admin sold at branch A, got [%s]', coalesce(v_err, 'no error at all'));

  -- A report id that does not exist reads the same to an L2, so nothing leaks.
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), gen_random_uuid(), v_lines);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN_LOCATION%',
    format('TC-16: an L2 probing a missing report got [%s], expected FORBIDDEN_LOCATION', coalesce(v_err, 'no error at all'));

  -- Only an L1 gets as far as REPORT_NOT_FOUND.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), gen_random_uuid(), v_lines);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_NOT_FOUND%',
    format('TC-16: an L1 with a missing report got [%s]', coalesce(v_err, 'no error at all'));

  -- A deactivated Owner holding a live token reads as NO_ACTOR, not FORBIDDEN (R31).
  perform set_config('request.jwt.claims', json_build_object('sub', v_off)::text, true);
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, v_lines);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'NO_ACTOR%',
    format('TC-16: a deactivated Owner got [%s], expected NO_ACTOR', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);

  v_err := null;
  begin
    perform fn_record_sales(null, v_rep, v_lines);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'IDEMPOTENCY_KEY_REQUIRED%',
    format('a null key got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, '[]'::jsonb);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'SALES_LINES_REQUIRED%',
    format('an empty batch got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, '{"product_code": "MEAT_BOX"}'::jsonb);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'SALES_LINES_REQUIRED%',
    format('an object instead of an array got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-19
  -- No price on or before the business date. CONFIG_NOT_SET naming the SKU, never a
  -- defaulted 350 (ADR-023, BR23).
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, v_lines);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'CONFIG_NOT_SET%' and v_err like '%MEAT_BOX%',
    format('TC-19: an unpriced MEAT_BOX got [%s]', coalesce(v_err, 'no error at all'));

  -- The Owner enters the prices. A LATER MEAT_BOX price exists too, so TC-21 can show the
  -- business date's price was taken and not the newest one.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_product_price(gen_random_uuid(), v_box,    date '2026-01-01', 350.00);
  perform fn_set_product_price(gen_random_uuid(), v_box,    v_day + 1,         380.00);
  perform fn_set_product_price(gen_random_uuid(), v_addon,  date '2026-01-01', 320.00);
  perform fn_set_product_price(gen_random_uuid(), v_chilli, date '2026-01-01',  20.00);
  perform fn_set_product_price(gen_random_uuid(), v_rice,   date '2026-01-01',  40.00);
  perform fn_set_product_price(gen_random_uuid(), v_water,  date '2026-01-01',  10.00);

  --------------------------------------------------------------------------------- TC-20
  -- Priced, but avg_pack_weight_kg unset. BR04: the system does not guess the pack weight.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, v_lines);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'CONFIG_NOT_SET%' and v_err like '%avg_pack_weight_kg%',
    format('TC-20: no pack weight got [%s]', coalesce(v_err, 'no error at all'));

  select count(*) into v_n from sales_lines;
  assert v_n = 0, format('TC-19/TC-20: %s sales line(s) survived refused calls', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'avg_pack_weight_kg', date '2026-01-01',
                        p_value_numeric => 0.20);
  -- Branch B's own row has three decimals. Scope beats recency (R36), so a sale at B resolves
  -- it and must refuse rather than silently store 0.21 against a 0.205 draw.
  perform fn_set_config(gen_random_uuid(), 'avg_pack_weight_kg', date '2026-01-01',
                        p_value_numeric => 0.205, p_scope_location_id => v_brb);

  ----------------------------------------------------------------- PACK_WEIGHT_INVALID (B14)
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_repb, v_lines);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'PACK_WEIGHT_INVALID%',
    format('B14: a 0.205 kg pack weight got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-27
  -- The source, refused by the function before the trigger could do it (R21).
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(jsonb_build_object(
      'product_code', 'MEAT_BOX', 'qty', 1, 'smoke_date_group_id', v_gA)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'LOT_REQUIRED%',
    format('TC-27: a meat line with no lot got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(jsonb_build_object(
      'product_code', 'MEAT_BOX', 'qty', 1, 'lot_id', v_lotA)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'SMOKE_GROUP_REQUIRED%',
    format('TC-27: a meat line with no smoke-date group got [%s]', coalesce(v_err, 'no error at all'));

  -- Lot B's group under lot A's name. Refused by name, not read as an empty tuple.
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(jsonb_build_object(
      'product_code', 'MEAT_BOX', 'qty', 1, 'lot_id', v_lotA, 'smoke_date_group_id', v_gB)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'LOT_REQUIRED%' and v_err like '%' || v_lotB::text || '%',
    format('TC-27: lot A with lot B''s group got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------- the line's shape (BR21)
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(jsonb_build_object(
      'product_code', 'NOT_A_SKU', 'qty', 1)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'PRODUCT_UNKNOWN%' and v_err like '%NOT_A_SKU%',
    format('an unknown SKU got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(jsonb_build_object(
      'product_code', 'MEAT_BOX', 'qty', 12.5, 'lot_id', v_lotA, 'smoke_date_group_id', v_gA)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'QTY_NOT_WHOLE_UNITS%',
    format('12.5 boxes got [%s] — half a box that was never packed (BR21)', coalesce(v_err, 'no error at all'));

  foreach v_txt in array array['0', '-1', '1.234', '"12"'] loop
    v_err := null;
    begin
      perform fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(
        jsonb_build_object('product_code', 'RICE_KG') || jsonb_build_object('qty', v_txt::jsonb)));
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'SALES_QTY_INVALID%',
      format('a qty of %s got [%s]', v_txt, coalesce(v_err, 'no error at all'));
  end loop;

  -- A two-line batch whose SECOND line fails writes nothing at all. Line 1 is valid and
  -- has stock behind it.
  select count(*) into v_led from stock_ledger;
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, v_lines || jsonb_build_array(
      jsonb_build_object('product_code', 'MEAT_BOX', 'qty', 1, 'smoke_date_group_id', v_gA)));
  exception when others then v_err := sqlerrm;
  end;
  select count(*) into v_n  from sales_lines;
  select count(*) into v_n2 from stock_ledger;
  assert v_err like 'LOT_REQUIRED%' and v_n = 0 and v_n2 = v_led,
    format('a batch failing on line 2 left %s sales line(s) and %s ledger row(s) behind, got [%s]',
           v_n, v_n2 - v_led, coalesce(v_err, 'no error at all'));

  ---------------------------------------------------------------- the happy path, once
  --------------------------------------------------------------------------------- TC-21
  -- 3.00 kg thawed, 0.20 kg a pack, 12 boxes: READY falls 2.40 on lot A's tuple, FROZEN does
  -- not move, and both snapshots are on the row (R14, R29).
  select count(*) into v_led from stock_ledger;
  v_res := fn_record_sales(v_k1, v_rep, v_lines);
  v_ids := array(select json_array_elements_text(v_res -> 'sales_line_ids')::uuid);
  assert cardinality(v_ids) = 1, format('TC-21: %s line id(s) returned for one line', cardinality(v_ids));

  select sum(qty_delta) into v_kg from stock_ledger
   where item_type = 'SMOKED_MEAT' and location_id = v_bra and stock_state = 'READY'
     and lot_id = v_lotA and smoke_date_group_id = v_gA;
  assert v_kg = 0.60, format('TC-21: lot A reads %s kg READY after selling 2.40 of 3.00', v_kg);

  select sum(qty_delta) into v_kg from stock_ledger
   where item_type = 'SMOKED_MEAT' and location_id = v_bra and stock_state = 'FROZEN'
     and lot_id = v_lotA;
  assert v_kg = 7.00, format('TC-21: lot A reads %s kg FROZEN — a sale deducts READY only (R14)', v_kg);

  select count(*) into v_n from stock_ledger
   where source_table = 'sales_lines' and source_id = v_ids[1]
     and movement_type = 'SALE' and stock_state = 'READY' and qty_delta = -2.40
     and lot_id = v_lotA and smoke_date_group_id = v_gA and product_id is null
     and business_date = v_day and location_id = v_bra;
  select count(*) into v_n2 from stock_ledger;
  assert v_n = 1 and v_n2 = v_led + 1,
    format('TC-21: expected exactly one SALE -2.40 on (lot A, group, READY, no product) dated %s; found %s, and %s new row(s)',
           v_day, v_n, v_n2 - v_led);

  select count(*) into v_n from sales_lines
   where id = v_ids[1] and unit_price_thb = 350.00 and pack_weight_kg = 0.20 and qty = 12
     and channel = 'LINE_MAN' and created_by = v_adm_a and seq = 1 and idempotency_key = v_k1
     and lot_id = v_lotA and smoke_date_group_id = v_gA;
  assert v_n = 1, 'TC-21: the row does not carry 350.00 (the business date''s price), 0.20, LINE_MAN, the actor and its key';

  assert (v_res ->> 'ready_remaining_kg')::numeric = 1.60,
    format('TC-21: ready_remaining_kg is %s, expected 1.60 (0.60 of lot A + 1.00 of lot B)', v_res ->> 'ready_remaining_kg');
  assert (v_res ->> 'chilli_paste_remaining_tubes')::numeric = 100,
    format('TC-21: chilli_paste_remaining_tubes is %s, expected 100', v_res ->> 'chilli_paste_remaining_tubes');

  --------------------------------------------------------------------------------- TC-26
  -- Selling meat deducts nothing else (UAT-11, M6).
  select coalesce(sum(qty_delta), 0) into v_kg from stock_ledger
   where item_type = 'CHILLI_PASTE' and location_id = v_bra;
  assert v_kg = 100, format('TC-26: a meat sale moved chilli to %s', v_kg);
  select count(*) into v_n from stock_ledger where item_type in ('COOKED_RICE', 'RAW_RICE');
  assert v_n = 0, format('TC-26: %s rice ledger row(s) exist after a meat sale', v_n);

  --------------------------------------------------------------------------------- TC-22
  -- The box and the sealed add-on are two SKUs: two rows, two prices, two deductions, and
  -- neither implies the other (D03.1, UAT-16).
  v_res := fn_record_sales(v_k2, v_rep, jsonb_build_array(
    jsonb_build_object('product_code', 'MEAT_BOX',          'qty', 1, 'lot_id', v_lotA, 'smoke_date_group_id', v_gA),
    jsonb_build_object('product_code', 'MEAT_ADDON_SEALED', 'qty', 1, 'lot_id', v_lotA, 'smoke_date_group_id', v_gA)));
  select count(*) into v_n from sales_lines
   where idempotency_key = v_k2
     and ((product_id = v_box and unit_price_thb = 350.00 and seq = 1)
       or (product_id = v_addon and unit_price_thb = 320.00 and seq = 2));
  assert v_n = 2, format('TC-22: %s of the two SKU lines carry their own price', v_n);
  select count(*) into v_n from stock_ledger l join sales_lines s on s.id = l.source_id
   where s.idempotency_key = v_k2 and l.qty_delta = -0.20;
  assert v_n = 2, format('TC-22: %s of two deductions at 0.20 kg', v_n);

  --------------------------------------------------------------------------------- TC-23
  -- Two lots on one smoke date: two lines, two tuples, each naming its lot (D01, D05, R21).
  v_res := fn_record_sales(v_k3, v_rep, jsonb_build_array(
    jsonb_build_object('product_code', 'MEAT_BOX', 'qty', 1, 'lot_id', v_lotA, 'smoke_date_group_id', v_gA),
    jsonb_build_object('product_code', 'MEAT_BOX', 'qty', 2, 'lot_id', v_lotB, 'smoke_date_group_id', v_gB)));
  select count(*) into v_n from stock_ledger l join sales_lines s on s.id = l.source_id
   where s.idempotency_key = v_k3
     and ((l.lot_id = v_lotA and l.qty_delta = -0.20 and s.lot_id = v_lotA)
       or (l.lot_id = v_lotB and l.qty_delta = -0.40 and s.lot_id = v_lotB));
  assert v_n = 2, format('TC-23: %s of two lot-named deductions', v_n);
  select sum(qty_delta) into v_kg from stock_ledger
   where item_type = 'SMOKED_MEAT' and location_id = v_bra and stock_state = 'READY' and lot_id = v_lotA;
  assert v_kg = 0.00, format('TC-23: lot A reads %s kg READY, expected 0.00', v_kg);

  --------------------------------------------------------------------------------- TC-24
  -- Chilli deducts in tubes: receive 100, sell 12, the system says 88 (M6). No lot, no kg.
  v_res := fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(
    jsonb_build_object('product_code', 'CHILLI_TUBE', 'qty', 12)));
  assert (v_res ->> 'chilli_paste_remaining_tubes')::numeric = 88,
    format('TC-24: chilli reads %s tubes after selling 12 of 100', v_res ->> 'chilli_paste_remaining_tubes');
  select count(*) into v_n from stock_ledger
   where source_id = (select (v_res -> 'sales_line_ids' ->> 0)::uuid)
     and item_type = 'CHILLI_PASTE' and product_id = v_chilli and lot_id is null
     and stock_state = 'READY' and qty_delta = -12;
  assert v_n = 1, 'TC-24: the chilli SALE is not -12 tubes on (CHILLI_PASTE, CHILLI_TUBE, no lot, READY)';
  select count(*) into v_n from sales_lines
   where id = (select (v_res -> 'sales_line_ids' ->> 0)::uuid) and pack_weight_kg is null;
  assert v_n = 1, 'TC-24: a chilli line carries a pack weight — the snapshot is meat-only';

  --------------------------------------------------------------------------------- TC-25
  -- Rice and water are written and priced, and post NOTHING (Finding 10, BR08). A rice SALE
  -- would draw on a tuple with no intake and raise INSUFFICIENT_STOCK on the first bowl.
  select count(*) into v_led from stock_ledger;
  v_res := fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(
    jsonb_build_object('product_code', 'RICE_KG',      'qty', 8.50),
    jsonb_build_object('product_code', 'WATER_BOTTLE', 'qty', 6)));
  v_ids2 := array(select json_array_elements_text(v_res -> 'sales_line_ids')::uuid);
  select count(*) into v_n from sales_lines
   where id = any (v_ids2)
     and ((product_id = v_rice and qty = 8.50 and unit_price_thb = 40.00)
       or (product_id = v_water and qty = 6 and unit_price_thb = 10.00));
  select count(*) into v_n2 from stock_ledger;
  assert v_n = 2 and v_n2 = v_led,
    format('TC-25: %s of 2 rice/water rows priced, and %s ledger row(s) posted for untracked SKUs', v_n, v_n2 - v_led);

  --------------------------------------------------------------------------------- TC-28
  -- Over-selling lot B: 20 boxes (4.00 kg) against 0.60 kg ready. INSUFFICIENT_READY_STOCK
  -- naming the lot, not the bare R3 name, and nothing written.
  select count(*) into v_rows from sales_lines;
  select count(*) into v_led  from stock_ledger;
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(jsonb_build_object(
      'product_code', 'MEAT_BOX', 'qty', 20, 'lot_id', v_lotB, 'smoke_date_group_id', v_gB)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'INSUFFICIENT_READY_STOCK%' and v_err like '%LOT-43B%' and v_err like '%3.40%',
    format('TC-28: over-selling got [%s], expected INSUFFICIENT_READY_STOCK naming LOT-43B and the 3.40 kg shortfall',
           coalesce(v_err, 'no error at all'));
  select count(*) into v_n  from sales_lines;
  select count(*) into v_n2 from stock_ledger;
  assert v_n = v_rows and v_n2 = v_led,
    format('TC-28: a refused sale left %s line(s) and %s ledger row(s)', v_n - v_rows, v_n2 - v_led);

  --------------------------------------------------------------------------------- TC-29
  -- Five stock-tracked lines, then the same key and the same five lines: the same ids, five
  -- rows, five ledger rows (R4). The replay returns before any stock is read, so lot B being
  -- empty by then does not refuse it.
  v_five := jsonb_build_array(
    jsonb_build_object('product_code', 'MEAT_BOX',          'qty', 1, 'lot_id', v_lotB, 'smoke_date_group_id', v_gB),
    jsonb_build_object('product_code', 'MEAT_ADDON_SEALED', 'qty', 1, 'lot_id', v_lotB, 'smoke_date_group_id', v_gB),
    jsonb_build_object('product_code', 'CHILLI_TUBE',       'qty', 1),
    jsonb_build_object('product_code', 'CHILLI_TUBE',       'qty', 2),
    jsonb_build_object('product_code', 'MEAT_BOX',          'qty', 1, 'lot_id', v_lotB, 'smoke_date_group_id', v_gB));
  v_res := fn_record_sales(v_k5, v_rep, v_five);
  v_ids := array(select json_array_elements_text(v_res -> 'sales_line_ids')::uuid);

  v_res := fn_record_sales(v_k5, v_rep, v_five);
  v_ids2 := array(select json_array_elements_text(v_res -> 'sales_line_ids')::uuid);
  assert v_ids2 = v_ids, format('TC-29: the replay returned %s, the first call %s', v_ids2, v_ids);

  -- The same payload with qty spelled 1.0: still the same batch (the stored form is 2dp).
  v_res := fn_record_sales(v_k5, v_rep, jsonb_set(v_five, '{0,qty}', '1.0'::jsonb));
  assert array(select json_array_elements_text(v_res -> 'sales_line_ids')::uuid) = v_ids,
    'TC-29: a replay spelling qty 1.0 for 1 was not recognised as the same batch';

  select count(*) into v_n  from sales_lines  where idempotency_key = v_k5;
  select count(*) into v_n2 from stock_ledger where source_id = any (v_ids);
  assert v_n = 5 and v_n2 = 5,
    format('TC-29: after three calls on one key, %s rows and %s ledger rows — expected 5 and 5', v_n, v_n2);
  select sum(qty_delta) into v_kg from stock_ledger
   where item_type = 'SMOKED_MEAT' and location_id = v_bra and stock_state = 'READY' and lot_id = v_lotB;
  assert v_kg = 0.00, format('TC-29: lot B reads %s kg READY — the replay drew it twice', v_kg);

  --------------------------------------------------------------------------------- TC-30
  -- The replay that grew, and the replay that moved report: both conflict and write nothing.
  v_err := null;
  begin
    perform fn_record_sales(v_k5, v_rep, v_five || jsonb_build_array(
      jsonb_build_object('product_code', 'WATER_BOTTLE', 'qty', 1)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'SALES_IDEMPOTENCY_CONFLICT%',
    format('TC-30: a six-line replay of a five-line key got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_err := null;
  begin
    perform fn_record_sales(v_k5, v_repb, v_five);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'SALES_IDEMPOTENCY_CONFLICT%',
    format('TC-30: the same key on another report got [%s]', coalesce(v_err, 'no error at all'));

  select count(*) into v_n from sales_lines where idempotency_key = v_k5;
  assert v_n = 5, format('TC-30: the conflicting replays left %s rows on the key, expected 5', v_n);

  --------------------------------------------------------------------------------- TC-31
  -- One ledger row per stock-tracked line, each on md5(key || ':' || seq). The batch key never
  -- reaches fn_post_ledger, or lines 2 to 5 would silently return line 1's id.
  select count(*), count(distinct l.idempotency_key) into v_n, v_n2
    from sales_lines s
    join stock_ledger l on l.source_table = 'sales_lines' and l.source_id = s.id
   where s.idempotency_key = v_k5
     and l.idempotency_key = md5(v_k5::text || ':' || s.seq)::uuid;
  assert v_n = 5 and v_n2 = 5, format('TC-31: %s ledger rows on derived keys (%s distinct), expected 5 and 5', v_n, v_n2);
  select count(*) into v_n from stock_ledger where idempotency_key = v_k5;
  assert v_n = 0, 'TC-31: the batch key itself was posted to the ledger';
  -- A second batch on a new key has its own set.
  select count(*) into v_n
    from sales_lines s join stock_ledger l on l.source_id = s.id
   where s.idempotency_key = v_k2 and l.idempotency_key = md5(v_k2::text || ':' || s.seq)::uuid;
  assert v_n = 2, format('TC-31: batch K2 has %s derived ledger rows, expected 2', v_n);

  ------------------------------------------------------------------- the Owner sells (B1)
  v_res := fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(
    jsonb_build_object('product_code', 'WATER_BOTTLE', 'qty', 1)));
  select count(*) into v_n from sales_lines
   where id = (select (v_res -> 'sales_line_ids' ->> 0)::uuid) and created_by = v_owner;
  assert v_n = 1, 'B1: an Owner''s sale at branch A is not signed by the Owner (v0.2:57)';

  --------------------------------------------------------------------------------- TC-17
  -- A CLOSED day. REPORT_CLOSED naming the date, raised by the FUNCTION (the trigger is the
  -- backstop, and its message cannot be rendered in Thai by name alone).
  update daily_reports set status = 'CLOSED', closed_by = v_adm_a, closed_at = now() where id = v_rep;
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(
      jsonb_build_object('product_code', 'WATER_BOTTLE', 'qty', 1)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_CLOSED%' and v_err like '%no sale can be recorded%'
     and v_err like '%' || v_day::text || '%',
    format('TC-17: a sale against a CLOSED day got [%s]', coalesce(v_err, 'no error at all'));

  ------------------------------------------------------------ replay after close (B2)
  -- K1 committed while the day was open and its response was "lost". The retry lands after
  -- the close and must return the original ids, not REPORT_CLOSED (R4).
  v_res := fn_record_sales(v_k1, v_rep, v_lines);
  v_ids := array(select json_array_elements_text(v_res -> 'sales_line_ids')::uuid);
  select count(*) into v_n from sales_lines where idempotency_key = v_k1;
  assert cardinality(v_ids) = 1 and v_n = 1,
    format('B2: a replay after close returned %s id(s) and the key holds %s row(s)', cardinality(v_ids), v_n);

  -- UNLOCKED accepts the correction it was reopened for.
  update daily_reports set status = 'UNLOCKED' where id = v_rep;
  v_ok := false;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep, jsonb_build_array(
      jsonb_build_object('product_code', 'WATER_BOTTLE', 'qty', 1)));
    v_ok := true;
  exception when others then v_err := sqlerrm;
  end;
  assert v_ok, format('TC-17: an UNLOCKED day refused a sale: [%s]', v_err);

  ------------------------------------------------------------------------------ grants
  assert has_function_privilege('authenticated', 'public.fn_record_sales(uuid, uuid, jsonb)', 'EXECUTE'),
    'authenticated cannot execute fn_record_sales — no branch can sell';
  assert not has_function_privilege('anon', 'public.fn_record_sales(uuid, uuid, jsonb)', 'EXECUTE'),
    'anon can execute fn_record_sales';

  --------------------------------------------------------------------------------- TC-18
  -- LAST, because it closes the opening window for the rest of the transaction. With the
  -- window shut and unlock_max_days_back = 3, four days back is refused and three is accepted
  -- (R28's inclusive boundary). Water only: it needs no stock, so this is the date rule alone.
  insert into opening_balance_close (closed_by, closed_idempotency_key)
       values (v_owner, gen_random_uuid());
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'unlock_max_days_back', date '2026-01-01',
                        p_value_numeric => 3);
  -- OPEN reports, because R28 binds an OPEN day only (PLAN-sales.md B21). Branch B's v_day
  -- report goes UNLOCKED first, to free the branch's one OPEN slot (daily_reports_one_open).
  update daily_reports set status = 'UNLOCKED' where id = v_repb;
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_brb, current_date - 4, now(), v_adm_b) returning id into v_rep4;

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_err := null;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep4, jsonb_build_array(
      jsonb_build_object('product_code', 'WATER_BOTTLE', 'qty', 1)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'BACKDATE_NOT_ALLOWED%' and v_err like '%' || (current_date - 4)::text || '%',
    format('TC-18: an OPEN day four days back got [%s]', coalesce(v_err, 'no error at all'));

  -- B21: the same day, once UNLOCKED, is the escalation and is not asked the window again
  -- (v0.2 D07, UAT-18: past three days the Owner unlocks).
  update daily_reports set status = 'UNLOCKED' where id = v_rep4;
  v_ok := false;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep4, jsonb_build_array(
      jsonb_build_object('product_code', 'WATER_BOTTLE', 'qty', 1)));
    v_ok := true;
  exception when others then v_err := sqlerrm;
  end;
  assert v_ok, format('B21: an UNLOCKED day four days back was refused by R28: [%s]', v_err);

  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_brb, current_date - 3, now(), v_adm_b) returning id into v_rep3;
  v_ok := false;
  begin
    perform fn_record_sales(gen_random_uuid(), v_rep3, jsonb_build_array(
      jsonb_build_object('product_code', 'WATER_BOTTLE', 'qty', 1)));
    v_ok := true;
  exception when others then v_err := sqlerrm;
  end;
  assert v_ok, format('TC-18: an OPEN day exactly three days back was refused — R28''s boundary is inclusive: [%s]', v_err);

  raise exception 'SALES_TEST_PASSED';   -- the only clean way back out
end $$;
