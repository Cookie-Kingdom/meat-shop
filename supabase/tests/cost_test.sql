-- Card ^ref-32 — v_lot_cost and fn_set_smoke_fee_override. TC-13 ... TC-22 of
-- v.0.1/ref-31-33-cost/TDD-cost.md (TC-16 is the old TDD-lots TC-48, moved here with the cost).
-- Contract assumed from an unmerged lane: none (every function called is on develop at 9362eca).
--
-- THE WHOLE CHAIN RUNS THROUGH THE RPCs, because R30 is a property of the chain: the outbound
-- truck (dispatch, allocate, CM receipt), the operator's receipt, logs, bags and close, the
-- pickup date, the return truck (dispatch, allocate, central receipt). The only direct write is
-- TC-21's closed_at shift, which stands in for "closed a month ago", and ^ref-62's opening lot.
--
-- CONFIG IS SET AT 2026-01-01 and every lot closes today, so priced_at (the close date) sees it.
-- TC-13 reads before the brine rate and the tier exist. It does not assert BRINE_PCT, because a
-- seed migration (^ref-61) may ship brine_pct_of_meat pre-filled; the rate and the tier are
-- BLOCK keys and are never seeded.
--
-- ROLE READS RUN AS `authenticated` (TC-22), for PLAN-cost Finding 1.
--
-- ONE do $$ BLOCK, for lot_close_test.sql's reason. Everything runs in a transaction that aborts
-- on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/cost_test.sql

do $$
declare
  v_owner   uuid := gen_random_uuid();
  v_l2      uuid := gen_random_uuid();
  v_l3      uuid := gen_random_uuid();
  v_day     date := date '2026-05-04';
  v_chef    uuid;
  v_central uuid;
  v_branch  uuid;
  v_sup     uuid;
  v_po1     uuid;
  v_po2     uuid;
  v_lotX    uuid;   -- dispatch 100, received 98, pre-smoke 96.50, output 75 in one group
  v_lotZ    uuid;   -- same weights, output in two groups; only one goes back
  v_lotF    uuid;   -- dispatch 60, never received
  v_lotG    uuid;   -- dispatch 40, never received
  v_lotN    uuid;   -- a PO with no price
  v_open    uuid;   -- ^ref-62's opening lot
  v_tier    uuid;
  v_run1    uuid;
  v_run2    uuid;
  v_run3    uuid;
  v_lineX   uuid;
  v_lineZ   uuid;
  v_retX    uuid;
  v_retZ    uuid;
  v_gX      uuid;
  v_gZ1     uuid;
  v_closed  date;
  v_row     record;
  v_n       bigint;
  v_n2      bigint;
  v_ok      boolean;
  v_err     text;
  v_id      uuid;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',               'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',            'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',    'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind) values ('CH32', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('CEN32', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  insert into locations (code, name_th, kind) values ('BR32', 'สาขาทดสอบ', 'BRANCH')
    returning id into v_branch;
  insert into user_locations (profile_id, location_id) values (v_l3, v_chef), (v_l2, v_branch);
  insert into suppliers (name) values ('Foodiva') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'yield_alert_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'freight_alloc_method', date '2026-01-01',
                        p_value_text => 'BY_LOT_WEIGHT');
  perform fn_set_config(gen_random_uuid(), 'partial_receipt_allowed', date '2026-01-01',
                        p_value_text => 'true');

  v_po1  := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);
  v_po2  := fn_create_po(gen_random_uuid(), v_sup, v_day, 100.00);            -- no price
  v_lotX := fn_add_po_delivery(gen_random_uuid(), v_po1, v_day, 100.00, v_chef);
  v_lotZ := fn_add_po_delivery(gen_random_uuid(), v_po1, v_day, 100.00, v_chef);
  v_lotF := fn_add_po_delivery(gen_random_uuid(), v_po1, v_day,  60.00, v_chef);
  v_lotG := fn_add_po_delivery(gen_random_uuid(), v_po1, v_day,  40.00, v_chef);
  v_lotN := fn_add_po_delivery(gen_random_uuid(), v_po2, v_day,  50.00, v_chef);
  update lots set assigned_operator_id = v_l3 where id in (v_lotX, v_lotZ);

  -- ^ref-62's shape, inserted directly: the opening path is not under test here.
  insert into lots (lot_code, is_opening, state, event_date)
    values ('OPEN-32', true, 'LOT_CLOSED', v_day) returning id into v_open;

  --------------------------------------------------------------------------------- TC-13
  -- ADR-023: before the brine rate and any smoke-fee band exist, the row is still there, the
  -- parts that cannot be resolved are NULL — not 0 — and the view says which ones.
  select * into v_row from v_lot_cost where lot_id = v_lotX;
  assert v_row.lot_id is not null, 'TC-13: lot X has no v_lot_cost row before its config exists';
  assert v_row.brine_cost_thb is null and v_row.smoke_fee_computed_thb is null
     and v_row.smoke_fee_thb is null,
    format('TC-13: with no rate and no band lot X reads brine %s, smoke fee %s / %s — expected null, never 0',
           v_row.brine_cost_thb, v_row.smoke_fee_computed_thb, v_row.smoke_fee_thb);
  assert v_row.missing_inputs @> array['LOT_OPEN', 'BRINE_RATE', 'SMOKE_FEE_RATE', 'OUTBOUND_FREIGHT']::text[],
    format('TC-13: lot X names %s as missing', v_row.missing_inputs);
  assert not v_row.is_complete, 'TC-13: lot X reads complete with no config at all';
  assert v_row.meat_cost_thb = 25000.00 and v_row.total_cost_thb = 25000.00,
    format('TC-13: lot X reads meat %s, total %s — expected 25000.00 and the known parts only',
           v_row.meat_cost_thb, v_row.total_cost_thb);

  select * into v_row from v_lot_cost where lot_id = v_lotN;
  assert v_row.lot_id is not null, 'TC-13: lot N has no v_lot_cost row';
  assert v_row.meat_cost_thb is null and v_row.total_cost_thb is null
     and v_row.missing_inputs @> array['MEAT_PRICE']::text[],
    format('TC-13: a PO with no price reads meat %s, total %s, missing %s',
           v_row.meat_cost_thb, v_row.total_cost_thb, v_row.missing_inputs);

  -- PLAN Finding 7: the opening lot's cost is opening_costs's, not this view's.
  select count(*) into v_n from v_lot_cost where lot_id = v_open;
  assert v_n = 0, 'TC-13: an opening lot has a v_lot_cost row';

  -------------------------------------------------------------------- the config lands
  perform fn_set_config(gen_random_uuid(), 'brine_pct_of_meat', date '2026-01-01',
                        p_value_numeric => 10.00);
  perform fn_set_config(gen_random_uuid(), 'brine_cost_thb_per_kg', date '2026-01-01',
                        p_value_numeric => 20.00);
  -- ADR-024's expected shape: one open band [0, ∞), PER_KG.
  perform fn_set_smoke_fee_tier(gen_random_uuid(), date '2026-01-01',
    '[{"min_weight_kg": 0, "max_weight_kg": null, "rate_thb": 50.00, "rate_basis": "PER_KG"}]'::jsonb);
  select id into v_tier from smoke_fee_tiers where effective_from = date '2026-01-01';

  -------------------------------------------------------------------- the outbound trucks
  v_run1  := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', v_day + 1,
                                     'รถห้องเย็น', false, 1500.00);
  v_lineX := fn_dispatch_transport_line(gen_random_uuid(), v_run1, v_lotX, null, null, v_chef, 100.00);
  v_lineZ := fn_dispatch_transport_line(gen_random_uuid(), v_run1, v_lotZ, null, null, v_chef, 100.00);

  -- Dispatched, not yet allocated: the outbound freight is still missing.
  select * into v_row from v_lot_cost where lot_id = v_lotX;
  assert v_row.missing_inputs @> array['OUTBOUND_FREIGHT']::text[] and v_row.freight_outbound_thb is null,
    format('TC-16: an unallocated outbound line reads %s THB, missing %s',
           v_row.freight_outbound_thb, v_row.missing_inputs);

  perform fn_allocate_freight(gen_random_uuid(), v_run1);                  -- 750.00 / 750.00

  v_run2 := fn_create_transport_run(gen_random_uuid(), 'FOODIVA_TO_CM', v_day + 1,
                                    'รถกระบะ', false, 1000.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lotF, null, null, v_chef, 60.00);
  perform fn_dispatch_transport_line(gen_random_uuid(), v_run2, v_lotG, null, null, v_chef, 40.00);
  perform fn_allocate_freight(gen_random_uuid(), v_run2);

  --------------------------------------------------------------------------------- TC-15
  -- UAT-06: 1,000 THB over 60 / 40 kg is 600 / 400, and that is what each lot carries.
  select freight_outbound_thb into v_row from v_lot_cost where lot_id = v_lotF;
  assert v_row.freight_outbound_thb = 600.00,
    format('TC-15: lot F carries %s THB of outbound freight, expected 600.00', v_row.freight_outbound_thb);
  select freight_outbound_thb into v_row from v_lot_cost where lot_id = v_lotG;
  assert v_row.freight_outbound_thb = 400.00,
    format('TC-15: lot G carries %s THB of outbound freight, expected 400.00', v_row.freight_outbound_thb);

  -------------------------------------------------------- Chiang Mai receives, smokes, closes
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_lineX, v_day + 2, 98.00);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_lineZ, v_day + 2, 98.00);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotX, v_day + 2, 98.00, 96.50);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotZ, v_day + 2, 98.00, 96.50);

  -- X: one day, 150 bags of 0.50 — output 75.00 in one group.
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotX, v_day + 3,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotX, 'input_weight_kg', 96.50)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotX, v_day + 3,
                             array(select 0.50::numeric from generate_series(1, 150)));

  -- Z: two days, 40.00 then 35.00 — output 75.00 in two groups.
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotZ, v_day + 3,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotZ, 'input_weight_kg', 50.00)));
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotZ, v_day + 4,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotZ, 'input_weight_kg', 46.50)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotZ, v_day + 3,
                             array(select 0.50::numeric from generate_series(1, 80)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotZ, v_day + 4,
                             array(select 0.50::numeric from generate_series(1, 70)));

  perform fn_close_lot(gen_random_uuid(), v_lotX);
  perform fn_close_lot(gen_random_uuid(), v_lotZ);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-14
  -- BR10, ADR-024: every base is the Foodiva dispatch weight. 50 THB/kg on 100 kg is 5000.00 —
  -- not 3750.00 (×75, the output) and not 4900.00 (×98, the CM received weight).
  select * into v_row from v_lot_cost where lot_id = v_lotX;
  assert v_row.state = 'LOT_CLOSED', format('TC-14: lot X is %s after close', v_row.state);
  assert v_row.meat_cost_thb = 25000.00,
    format('TC-14: meat reads %s, expected 25000.00 (250 × 100)', v_row.meat_cost_thb);
  assert v_row.brine_cost_thb = 200.00,
    format('TC-14: brine reads %s, expected 200.00 (100 × 10%% × 20)', v_row.brine_cost_thb);
  assert v_row.smoke_fee_computed_thb = 5000.00,
    format('TC-14: the smoke fee reads %s, expected 5000.00 (50 × dispatch 100; 3750 is ×output, 4900 ×received)',
           v_row.smoke_fee_computed_thb);
  assert v_row.smoke_fee_thb = 5000.00 and not v_row.smoke_fee_is_overridden,
    format('TC-14: smoke_fee_thb %s, overridden %s', v_row.smoke_fee_thb, v_row.smoke_fee_is_overridden);
  assert v_row.smoke_fee_rate_thb = 50.00 and v_row.smoke_fee_rate_basis = 'PER_KG'
     and v_row.smoke_fee_tier_id = v_tier,
    format('TC-14: the fee does not trace to its band (%s, %s, %s)',
           v_row.smoke_fee_rate_thb, v_row.smoke_fee_rate_basis, v_row.smoke_fee_tier_id);
  assert v_row.po_id = v_po1 and v_row.meat_unit_price_thb_per_kg = 250.00,
    'TC-14: the meat cost does not trace to its PO and unit price';

  --------------------------------------------------------------------------------- TC-16
  -- R30: closed, and still not final. The return leg has not happened and the meat is still
  -- FROZEN at the chef house; every other input has landed.
  assert not v_row.is_complete
     and v_row.missing_inputs = array['RETURN_FREIGHT', 'CHEF_HOUSE_STOCK']::text[],
    format('TC-16: after close lot X reads complete=%s, missing %s', v_row.is_complete, v_row.missing_inputs);
  assert v_row.freight_outbound_thb = 750.00 and v_row.total_cost_thb = 30950.00,
    format('TC-16: after close lot X reads outbound %s, total %s — expected 750.00 and 30950.00',
           v_row.freight_outbound_thb, v_row.total_cost_thb);
  assert v_row.chef_house_frozen_kg = 75.00,
    format('TC-16: lot X holds %s kg at the chef house after close, expected 75.00', v_row.chef_house_frozen_kg);

  -- The return truck: pickup dates, then one run carrying all of X and only Z's first day.
  select closed_at::date into v_closed from lots where id = v_lotX;
  perform fn_set_return_pickup_date(gen_random_uuid(), v_lotX, v_closed);
  perform fn_set_return_pickup_date(gen_random_uuid(), v_lotZ, v_closed);
  v_run3 := fn_create_transport_run(gen_random_uuid(), 'CM_TO_FOODIVA', v_day + 5,
                                    'รถห้องเย็น', false, 1150.00, array[v_lotX, v_lotZ]);
  select id into v_gX  from smoke_date_groups where lot_id = v_lotX;
  select id into v_gZ1 from smoke_date_groups where lot_id = v_lotZ and smoke_date = v_day + 3;
  v_retX := fn_dispatch_transport_line(gen_random_uuid(), v_run3, v_lotX, v_gX,  v_chef, v_central, 75.00);
  v_retZ := fn_dispatch_transport_line(gen_random_uuid(), v_run3, v_lotZ, v_gZ1, v_chef, v_central, 40.00);

  select * into v_row from v_lot_cost where lot_id = v_lotX;
  assert v_row.missing_inputs = array['RETURN_FREIGHT', 'RETURN_RECEIPT']::text[],
    format('TC-16: dispatched, unallocated, unreceived — lot X names %s', v_row.missing_inputs);

  perform fn_allocate_freight(gen_random_uuid(), v_run3);      -- 1150 × 75/115, × 40/115

  select * into v_row from v_lot_cost where lot_id = v_lotX;
  assert v_row.missing_inputs = array['RETURN_RECEIPT']::text[] and v_row.freight_return_thb = 750.00,
    format('TC-16: allocated, unreceived — lot X names %s with return freight %s',
           v_row.missing_inputs, v_row.freight_return_thb);
  assert not v_row.is_complete, 'TC-16: a return leg still on the road reads complete';

  perform fn_confirm_transport_receipt(gen_random_uuid(), v_retX, v_day + 6, 75.00);
  perform fn_confirm_transport_receipt(gen_random_uuid(), v_retZ, v_day + 6, 40.00);

  select * into v_row from v_lot_cost where lot_id = v_lotX;
  assert v_row.is_complete and cardinality(v_row.missing_inputs) = 0,
    format('TC-16: with the return received lot X reads complete=%s, missing %s',
           v_row.is_complete, v_row.missing_inputs);
  assert v_row.freight_share_thb = 1500.00 and v_row.total_cost_thb = 31700.00,
    format('TC-16: lot X reads freight %s, total %s — expected 1500.00 and 31700.00',
           v_row.freight_share_thb, v_row.total_cost_thb);

  -- Z's return line is allocated and received, and its second day is still at the chef house.
  -- FROZEN left behind is what keeps it open, and nothing else does.
  select * into v_row from v_lot_cost where lot_id = v_lotZ;
  assert not v_row.is_complete
     and v_row.missing_inputs = array['CHEF_HOUSE_STOCK']::text[]
     and v_row.chef_house_frozen_kg = 35.00,
    format('TC-16: lot Z, half returned, reads complete=%s, missing %s, %s kg at the chef house',
           v_row.is_complete, v_row.missing_inputs, v_row.chef_house_frozen_kg);

  --------------------------------------------------------------------------------- TC-17
  -- R41: 0.00 is a free run, honoured as such — never read as "unset".
  perform fn_set_smoke_fee_override(gen_random_uuid(), v_lotX, 0.00, 'ร้านรมควันให้ฟรีรอบนี้');
  select * into v_row from v_lot_cost where lot_id = v_lotX;
  assert v_row.smoke_fee_thb = 0.00 and v_row.smoke_fee_is_overridden,
    format('TC-17: an override of 0.00 reads smoke_fee_thb %s, overridden %s',
           v_row.smoke_fee_thb, v_row.smoke_fee_is_overridden);
  assert v_row.smoke_fee_computed_thb = 5000.00,
    format('TC-17: the computed fee beside the override reads %s, expected 5000.00', v_row.smoke_fee_computed_thb);
  assert v_row.total_cost_thb = 26700.00,
    format('TC-17: a free run leaves the total at %s, expected 26700.00', v_row.total_cost_thb);

  --------------------------------------------------------------------------------- TC-18
  -- The named refusals, each in its own sub-block so a refusal rolls back only itself.
  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_override(null, v_lotX, 100.00, 'ส่วนลด');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'IDEMPOTENCY_KEY_REQUIRED:%';
  end;
  assert v_ok, format('TC-18: a null key got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_override(gen_random_uuid(), v_lotX, -1.00, 'ส่วนลด');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'SMOKE_FEE_OVERRIDE_INVALID:%';
  end;
  assert v_ok, format('TC-18: a negative override got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_override(gen_random_uuid(), v_lotX, 100.00, null);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'SMOKE_FEE_REASON_REQUIRED:%';
  end;
  assert v_ok, format('TC-18: an override with no reason got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_override(gen_random_uuid(), v_lotX, 100.00, '   ');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'SMOKE_FEE_REASON_REQUIRED:%';
  end;
  assert v_ok, format('TC-18: an override with a blank reason got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_override(gen_random_uuid(), gen_random_uuid(), 100.00, 'ส่วนลด');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_NOT_FOUND:%';
  end;
  assert v_ok, format('TC-18: an unknown lot got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_set_smoke_fee_override(gen_random_uuid(), v_open, 100.00, 'ส่วนลด');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_IS_OPENING:%';
  end;
  assert v_ok, format('TC-18: an opening lot got %s', coalesce(v_err, 'no exception at all'));

  -- R20, BR15: a price is the Owner's. The operator who smoked the lot and a branch admin are
  -- refused — before the lot is even looked up, so an unknown lot is FORBIDDEN too.
  foreach v_id in array array[v_l3, v_l2] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_id)::text, true);
    v_ok := false; v_err := null;
    begin
      perform fn_set_smoke_fee_override(gen_random_uuid(), v_lotX, 100.00, 'ส่วนลด');
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
    end;
    assert v_ok, format('TC-18: %s setting an override got %s',
                        (select role from profiles where id = v_id), coalesce(v_err, 'no exception at all'));

    v_ok := false; v_err := null;
    begin
      perform fn_set_smoke_fee_override(gen_random_uuid(), gen_random_uuid(), 100.00, 'ส่วนลด');
    exception when others then
      v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
    end;
    assert v_ok, format('TC-18: %s probing an unknown lot got %s',
                        (select role from profiles where id = v_id), coalesce(v_err, 'no exception at all'));
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  select count(*) into v_n from lots
   where id = v_lotX and smoke_fee_override_thb = 0.00
     and smoke_fee_override_reason = 'ร้านรมควันให้ฟรีรอบนี้';
  assert v_n = 1, 'TC-18: a refused override moved lot X''s standing override';

  --------------------------------------------------------------------------------- TC-19
  -- R41, R30: a discount is agreed after the run. Lot X is well past close — its return leg
  -- has landed at central — and the override is still accepted.
  select count(*) into v_n from lots where id = v_lotX and state > 'LOT_CLOSED';
  assert v_n = 1, 'TC-19: the fixture expected lot X past LOT_CLOSED';
  perform fn_set_smoke_fee_override(gen_random_uuid(), v_lotX, 4500.00, 'ส่วนลดตามที่ตกลงกับโรงรม');
  select * into v_row from v_lot_cost where lot_id = v_lotX;
  assert v_row.smoke_fee_thb = 4500.00 and v_row.smoke_fee_override_reason = 'ส่วนลดตามที่ตกลงกับโรงรม',
    format('TC-19: a closed lot''s override reads %s (%s)', v_row.smoke_fee_thb, v_row.smoke_fee_override_reason);

  --------------------------------------------------------------------------------- TC-20
  -- R4: the standing value again, under a new key, is a retry and writes nothing — not even an
  -- audit row. Then a clear, which takes no reason and returns the lot to the rate; the audit
  -- before-snapshot is the record of what was cleared (R32, PLAN Finding 8).
  select count(*) into v_n from audit_log where table_name = 'lots' and row_id = v_lotX;
  perform fn_set_smoke_fee_override(gen_random_uuid(), v_lotX, 4500, '  ส่วนลดตามที่ตกลงกับโรงรม ');
  select count(*) into v_n2 from audit_log where table_name = 'lots' and row_id = v_lotX;
  assert v_n2 = v_n, format('TC-20: a replay of the standing override wrote %s audit row(s)', v_n2 - v_n);

  perform fn_set_smoke_fee_override(gen_random_uuid(), v_lotX, null, null);
  select * into v_row from v_lot_cost where lot_id = v_lotX;
  assert v_row.smoke_fee_override_thb is null and v_row.smoke_fee_override_reason is null
     and v_row.smoke_fee_thb = 5000.00 and not v_row.smoke_fee_is_overridden,
    format('TC-20: after a clear lot X reads override %s / %s, fee %s, overridden %s',
           v_row.smoke_fee_override_thb, v_row.smoke_fee_override_reason,
           v_row.smoke_fee_thb, v_row.smoke_fee_is_overridden);

  select count(*) into v_n from audit_log
   where table_name = 'lots' and row_id = v_lotX and action = 'UPDATE'
     and before ->> 'smoke_fee_override_reason' = 'ส่วนลดตามที่ตกลงกับโรงรม'
     and after  ->> 'smoke_fee_override_reason' is null;
  assert v_n = 1, format('TC-20: %s audit row(s) record what the clear removed, expected 1', v_n);

  -- Clearing a lot that has no override is a retry too.
  select count(*) into v_n from audit_log where table_name = 'lots' and row_id = v_lotX;
  perform fn_set_smoke_fee_override(gen_random_uuid(), v_lotX, null, 'ignored on a clear');
  select count(*) into v_n2 from audit_log where table_name = 'lots' and row_id = v_lotX;
  assert v_n2 = v_n, 'TC-20: clearing an already-clear lot wrote an audit row';

  --------------------------------------------------------------------------------- TC-21
  -- BR23. Lot X is made "closed a month ago" (the fixture's one direct write — the close itself
  -- is fn_close_lot's and happened above). A band set and a brine rate dated yesterday are after
  -- its priced_at and do not move it; an open lot, priced today, does move.
  update lots set closed_at = closed_at - interval '30 days' where id = v_lotX;
  perform fn_set_smoke_fee_tier(gen_random_uuid(), current_date - 1,
    '[{"min_weight_kg": 0, "max_weight_kg": null, "rate_thb": 80.00, "rate_basis": "PER_KG"}]'::jsonb);
  perform fn_set_config(gen_random_uuid(), 'brine_cost_thb_per_kg', current_date - 1,
                        p_value_numeric => 99.00);

  select * into v_row from v_lot_cost where lot_id = v_lotX;
  assert v_row.smoke_fee_computed_thb = 5000.00 and v_row.smoke_fee_rate_thb = 50.00
     and v_row.brine_cost_thb = 200.00,
    format('TC-21: a later rate moved closed lot X to fee %s (rate %s), brine %s',
           v_row.smoke_fee_computed_thb, v_row.smoke_fee_rate_thb, v_row.brine_cost_thb);

  select * into v_row from v_lot_cost where lot_id = v_lotF;
  assert v_row.smoke_fee_computed_thb = 4800.00 and v_row.brine_cost_thb = 594.00,
    format('TC-21: open lot F, priced today, reads fee %s and brine %s — expected 4800.00 and 594.00',
           v_row.smoke_fee_computed_thb, v_row.brine_cost_thb);

  --------------------------------------------------------------------------------- TC-22
  -- R20, ADR-004, as a real `authenticated` session. The operator cannot select either override
  -- column off lots — an error, not a blank — and reads no v_lot_cost row; nor does a branch
  -- admin. The Owner does, which also proves the view's config reads need no function grant.
  select count(*) into v_n2 from lots where not is_opening;

  set local role authenticated;

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false;
  begin
    perform smoke_fee_override_thb from lots limit 1;
  exception when insufficient_privilege then
    v_ok := true;
  end;
  assert v_ok, 'TC-22: an L3 session could select lots.smoke_fee_override_thb (R20)';

  v_ok := false;
  begin
    perform smoke_fee_override_reason from lots limit 1;
  exception when insufficient_privilege then
    v_ok := true;
  end;
  assert v_ok, 'TC-22: an L3 session could select lots.smoke_fee_override_reason (R20)';

  select count(*) into v_n from v_lot_cost;
  assert v_n = 0, format('TC-22: the L3 reads %s v_lot_cost row(s) — every column is a price', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  select count(*) into v_n from v_lot_cost;
  assert v_n = 0, format('TC-22: an L2 reads %s v_lot_cost row(s)', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_lot_cost;
  assert v_n = v_n2 and v_n >= 5,
    format('TC-22: the Owner reads %s of %s lot(s) as authenticated', v_n, v_n2);

  reset role;

  raise exception 'COST_TEST_PASSED';   -- the only clean way back out
end $$;
