-- Card ^ref-29 — fn_close_lot. Covers TC-38 ... TC-58 from TDD-lots.md except TC-48 (moved
-- to ^ref-32 with the cost) and TC-54 (two sessions: production_concurrency_test.sh).
--
-- ONE do $$ BLOCK, for production_test.sql's reason: the harness pipes each file into psql
-- without --single-transaction, and the closing raise can only roll back the block it is in.
--
-- The transport legs are ^ref-22's and not under test here, so the one raw balance this file
-- needs — lot P's 98.00 kg at the chef house — is posted with fn_post_ledger directly, the
-- tuple fn_confirm_transport_receipt leaves behind. Lot states before the receipt, and
-- RETURN_SCHEDULED for TC-47 (^ref-34 is not built), are set directly too.
--
-- Everything runs in a transaction that aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/lot_close_test.sql

do $$
declare
  v_owner   uuid := gen_random_uuid();
  v_l3      uuid := gen_random_uuid();
  v_l3b     uuid := gen_random_uuid();
  v_day     date := date '2026-05-04';
  v_chef    uuid;
  v_central uuid;
  v_sup     uuid;
  v_po      uuid;
  v_lotP    uuid;   -- 100 / 98 / 96.50 / 75.00, with a raw ledger balance
  v_lotQ    uuid;   -- same, post-drain never entered
  v_lot80   uuid;   -- output 80.00: 20.00%, silent
  v_lot79   uuid;   -- output 79.99: 20.01%, alerts
  v_lotN    uuid;   -- no receipt
  v_lotM    uuid;   -- a log whose sources were lost
  v_lotS    uuid;   -- a log whose roll-up was forced off its sources
  v_g1      uuid;
  v_log     uuid;
  v_run     uuid;
  v_key     uuid := gen_random_uuid();
  v_resp    jsonb;
  v_resp2   jsonb;
  v_payload jsonb;
  v_at      timestamptz;
  v_unlock  uuid;
  v_ok      boolean;
  v_err     text;
  v_txt     text;
  v_n       bigint;
  v_kg      numeric;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l3), (v_l3b);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',                 'L1_OWNER',       true),
    (v_l3,    'ผู้ปฏิบัติงานคนที่หนึ่ง',     'L3_CM_OPERATOR', true),
    (v_l3b,   'ผู้ปฏิบัติงานคนที่สอง',      'L3_CM_OPERATOR', true);

  insert into locations (code, name_th, kind) values ('CH29', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('CEN29', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  -- v_l3b is at the SAME chef house: NOT_ASSIGNED_OPERATOR, not FORBIDDEN_LOCATION.
  insert into user_locations (profile_id, location_id) values (v_l3, v_chef), (v_l3b, v_chef);
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

  v_po    := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);
  v_lotP  := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotQ  := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lot80 := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lot79 := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotN  := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotM  := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotS  := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);

  update lots set state = 'IN_TRANSIT', assigned_operator_id = v_l3
   where id in (v_lotP, v_lotQ, v_lot80, v_lot79, v_lotN, v_lotM, v_lotS);

  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 'FROZEN', 'TRANSFER_IN',
                         98.00, v_day, p_lot_id => v_lotP);

  -- Receipts, logs and bags through the RPCs, as the operator.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);

  perform fn_record_lot_receipt(gen_random_uuid(), v_lotP,  v_day, 98.00, 96.50);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotQ,  v_day, 98.00);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lot80, v_day, 98.00, 96.50);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lot79, v_day, 98.00, 96.50);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotM,  v_day, 98.00, 96.50);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotS,  v_day, 98.00, 96.50);

  -- P smokes over two days, 40.00 kg then 35.00 kg of bags: output 75.00.
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotP, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotP, 'input_weight_kg', 50.00)));
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotP, v_day + 1,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotP, 'input_weight_kg', 46.50)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotP, v_day,
                             array(select 0.50::numeric from generate_series(1, 80)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotP, v_day + 1,
                             array(select 0.50::numeric from generate_series(1, 70)));
  select id into v_g1 from smoke_date_groups where lot_id = v_lotP and smoke_date = v_day;

  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotQ, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotQ, 'input_weight_kg', 96.00)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotQ, v_day,
                             array(select 0.50::numeric from generate_series(1, 150)));

  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lot80, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lot80, 'input_weight_kg', 96.50)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lot80, v_day,
                             array(select 0.50::numeric from generate_series(1, 160)));

  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lot79, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lot79, 'input_weight_kg', 96.50)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lot79, v_day,
                             array(select 0.50::numeric from generate_series(1, 159)) || 0.49::numeric);

  --------------------------------------------------------------------------------- TC-43
  -- No receipt, and then a receipt with no log: both are LOT_NOT_READY, and TC-43 is what
  -- keeps a lot from being closed without ever passing SMOKING (TDD open question 4).
  v_ok := false; v_err := null;
  begin
    perform fn_close_lot(gen_random_uuid(), v_lotN);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_NOT_READY:%';
  end;
  assert v_ok, format('TC-43: a lot with no receipt got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_close_lot(gen_random_uuid(), v_lotM);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_NOT_READY:%';
  end;
  assert v_ok, format('TC-43: a lot with a receipt and no log got %s',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-44
  -- A log whose sources are gone. The RPC cannot produce this (INPUT_SOURCES_REQUIRED), so
  -- the sources are deleted directly — the state a bad write from 2027 would leave.
  v_log := fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotM, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotM, 'input_weight_kg', 96.50)));
  delete from smoke_daily_log_sources where smoke_daily_log_id = v_log;

  v_ok := false; v_err := null;
  begin
    perform fn_close_lot(gen_random_uuid(), v_lotM);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'INPUT_WEIGHT_MISSING:%';
  end;
  assert v_ok, format('TC-44: a sourceless log got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-45
  v_log := fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotS, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotS, 'input_weight_kg', 96.50)));
  update smoke_daily_logs set input_weight_kg = 90.00 where id = v_log;

  v_ok := false; v_err := null;
  begin
    perform fn_close_lot(gen_random_uuid(), v_lotS);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'SOURCE_SUM_MISMATCH:%';
  end;
  assert v_ok, format('TC-45: a roll-up off its sources got %s', coalesce(v_err, 'no exception at all'));

  -- Nothing the three refusals touched was written.
  select count(*) into v_n from lots
   where id in (v_lotN, v_lotM, v_lotS) and (state >= 'LOT_CLOSED' or closed_at is not null);
  assert v_n = 0, format('TC-43..45: %s refused lot(s) were closed anyway', v_n);
  select count(*) into v_n from stock_ledger where movement_type = 'PRODUCTION';
  assert v_n = 0, format('TC-43..45: a refused close posted %s PRODUCTION row(s)', v_n);

  --------------------------------------------------------------------------------- TC-55
  -- The database refuses a non-assigned operator, screen or no screen (ADR-004). Automated
  -- here rather than left Manual: it is a property of the RPC, not of CM 05.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3b)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_close_lot(gen_random_uuid(), v_lotP);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_ASSIGNED_OPERATOR:%';
  end;
  assert v_ok, format('TC-55: an operator not assigned to the lot got %s',
                      coalesce(v_err, 'no exception at all'));

  ------------------------------------------------------------------ TC-46, before the close
  -- The negative half is the test that matters (Seam 4): while the lot smokes, the weight is
  -- on (lot, null) and NOTHING is on any group. A fixture that checks totals only passes with
  -- the weight on the wrong tuple.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select balance_qty into v_kg from v_stock_balance
   where lot_id = v_lotP and smoke_date_group_id is null and location_id = v_chef
     and stock_state = 'FROZEN';
  assert v_kg = 98.00, format('TC-46: before close (lot, null) holds %s, expected 98.00', v_kg);
  select count(*) into v_n from v_stock_balance
   where lot_id = v_lotP and smoke_date_group_id is not null;
  assert v_n = 0, format('TC-46: %s group tuple(s) hold weight before close', v_n);

  --------------------------------------------------------------------------------- TC-49
  -- Inverted by ADR-024: "a lot may be closed and priced later". No smoke-fee band exists in
  -- this file at all, and the close below succeeds anyway.
  select count(*) into v_n from smoke_fee_tiers;
  assert v_n = 0, format('TC-49: the fixture has %s smoke-fee band(s); it must have none', v_n);

  ------------------------------------------------------------------------- close lot P
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_resp := fn_close_lot(v_key, v_lotP);

  --------------------------------------------------------------------------------- TC-42
  select state::text, closed_at into v_txt, v_at from lots where id = v_lotP;
  assert v_txt = 'LOT_CLOSED' and v_at is not null,
    format('TC-42: lot P is %s with closed_at %s after close', v_txt, v_at);
  select count(*) into v_n from lots where id = v_lotP and closed_by = v_l3;
  assert v_n = 1, 'TC-42: closed_by is not the operator who closed it';

  --------------------------------------------------------------------------------- TC-57
  -- UAT-15: "ตรวจ API และ export ด้วย". The body is exactly these keys, and the group rows are
  -- exactly theirs — a loss_pct, a yield_alert or a cost_thb added back fails here by name.
  select string_agg(k, ',' order by k) into v_txt from jsonb_object_keys(v_resp) k;
  assert v_txt = 'closed_at,lot_code,lot_id,smoke_date_groups,state',
    format('TC-57: the response carries keys %s', v_txt);
  select string_agg(k, ',' order by k) into v_txt
    from jsonb_object_keys(v_resp -> 'smoke_date_groups' -> 0) k;
  assert v_txt = 'bag_count,packed_weight_kg,smoke_date',
    format('TC-57: a group row in the response carries keys %s', v_txt);
  assert jsonb_array_length(v_resp -> 'smoke_date_groups') = 2
     and (v_resp -> 'smoke_date_groups' -> 0 ->> 'packed_weight_kg')::numeric = 40.00
     and (v_resp -> 'smoke_date_groups' -> 1 ->> 'bag_count')::integer = 70,
    format('TC-57: the response groups read %s', v_resp -> 'smoke_date_groups');

  ------------------------------------------------------------------- TC-46, after the close
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select coalesce(sum(balance_qty), 0) into v_kg from v_stock_balance
   where lot_id = v_lotP and smoke_date_group_id is null and location_id = v_chef
     and stock_state = 'FROZEN';
  assert v_kg = 0, format('TC-46: after close (lot, null) still holds %s', v_kg);

  select string_agg(g.smoke_date || '=' || b.balance_qty, ',' order by g.smoke_date) into v_txt
    from v_stock_balance b join smoke_date_groups g on g.id = b.smoke_date_group_id
   where b.lot_id = v_lotP and b.location_id = v_chef and b.stock_state = 'FROZEN';
  assert v_txt = format('%s=40.00,%s=35.00', v_day, v_day + 1),
    format('TC-46: the groups hold %s after close', v_txt);

  select count(*), sum(qty_delta) into v_n, v_kg from stock_ledger
   where lot_id = v_lotP and movement_type = 'PRODUCTION';
  assert v_n = 3 and v_kg = -23.00,
    format('TC-46: %s PRODUCTION row(s) netting %s, expected 3 netting -23.00 (ADR-025)', v_n, v_kg);

  -- BR17: closing creates no transport job.
  select count(*) into v_n from transport_lines where lot_id = v_lotP;
  assert v_n = 0, format('BR17: the close created %s transport line(s)', v_n);
  select count(*) into v_n from transport_runs;
  assert v_n = 0, format('BR17: the close created %s transport run(s)', v_n);

  ------------------------------------------------------------------------ TC-38, TC-39
  -- The figures reach the Owner, not the caller. Dispatch 100, received 98, post-drain 96.50,
  -- output 75: Loss 25.00 — not 23.47 (/98) and not 22.28 (/96.50); smoke yield 77.72 —
  -- not 76.53 (/98).
  select count(*) into v_n from notifications where lot_id = v_lotP and kind = 'YIELD_ALERT';
  assert v_n = 1, format('TC-38: lot P raised %s YIELD_ALERT(s), expected 1', v_n);
  select payload into v_payload from notifications where lot_id = v_lotP and kind = 'YIELD_ALERT';
  assert (v_payload ->> 'loss_pct')::numeric = 25.00,
    format('TC-38: loss_pct reads %s, expected 25.00 on the dispatch base (R16a)', v_payload ->> 'loss_pct');
  assert (v_payload ->> 'smoke_yield_pct')::numeric = 77.72,
    format('TC-39: smoke_yield_pct reads %s, expected 77.72 on the pre-smoke base (Finding 9)',
           v_payload ->> 'smoke_yield_pct');
  select count(*) into v_n from notifications
   where lot_id = v_lotP and kind = 'YIELD_ALERT' and target_role = 'L1_OWNER';
  assert v_n = 1, 'TC-38: the YIELD_ALERT is not addressed to L1';

  --------------------------------------------------------------------------------- TC-53
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_resp2 := fn_close_lot(v_key, v_lotP);
  assert v_resp2 = v_resp, format('TC-53: the replay answered %s, the close answered %s', v_resp2, v_resp);
  select count(*) into v_n from stock_ledger where lot_id = v_lotP and movement_type = 'PRODUCTION';
  assert v_n = 3, format('TC-53: a replay left %s PRODUCTION rows, expected 3', v_n);
  select count(*) into v_n from lots where id = v_lotP and closed_at = v_at;
  assert v_n = 1, 'TC-53: a replay moved closed_at';
  select count(*) into v_n from notifications where lot_id = v_lotP;
  assert v_n = 1, format('TC-53: a replay raised a second alert (%s)', v_n);

  --------------------------------------------------------------------------------- TC-58
  v_ok := false; v_err := null;
  begin
    perform fn_close_lot(gen_random_uuid(), v_lotP);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_ALREADY_CLOSED:%';
  end;
  assert v_ok, format('TC-58: a second close under a new key got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-59
  -- The lost weight is stored, once: dispatch 100, output 75 → 25.00 kg (UAT-02, BR03). It
  -- survived TC-53's replay and TC-58's refusal unchanged, it is not in either response
  -- (UAT-15 — TC-57's key list says so too, this says it by name), and no lot that has not
  -- closed carries one.
  select loss_weight_kg into v_kg from lots where id = v_lotP;
  assert v_kg = 25.00, format('TC-59: lot P stored loss_weight_kg %s, expected 25.00', v_kg);
  assert not (v_resp ? 'loss_weight_kg') and not (v_resp2 ? 'loss_weight_kg'),
    'TC-59: the close response carries loss_weight_kg';
  select count(*) into v_n from lots where loss_weight_kg is not null and state < 'LOT_CLOSED';
  assert v_n = 0, format('TC-59: %s lot(s) that never closed carry a lost weight', v_n);
  select (payload ->> 'loss_weight_kg')::numeric into v_kg
    from notifications where lot_id = v_lotP and kind = 'YIELD_ALERT';
  assert v_kg = 25.00, format('TC-59: the alert carries %s, not the stored 25.00', v_kg);

  --------------------------------------------------------------------------------- TC-50
  -- The lock is a refusal, not a state value (Seam 5): the log RPC's own guard is a floor, so
  -- it reaches the write and fn_guard_lot_closed refuses it.
  v_ok := false; v_err := null;
  begin
    perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotP, v_day + 2,
      jsonb_build_array(jsonb_build_object('lot_id', v_lotP, 'input_weight_kg', 1.00)));
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_CLOSED:%';
  end;
  assert v_ok, format('TC-50: a log against a closed lot got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-51
  insert into unlock_requests (target_type, target_id, requested_by, reason, status,
                               decided_by, decided_at, expires_at)
  values ('LOT', v_lotP, v_l3, 'ลืมบันทึกน้ำหนักวันที่สาม', 'APPROVED',
          v_owner, now(), now() + interval '1 hour')
  returning id into v_unlock;

  v_log := null;
  begin
    v_log := fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotP, v_day + 2,
      jsonb_build_array(jsonb_build_object('lot_id', v_lotP, 'input_weight_kg', 1.00)));
  exception when others then
    v_err := sqlerrm;
  end;
  assert v_log is not null, format('TC-51: an approved, unexpired unlock was refused: %s', v_err);

  --------------------------------------------------------------------------------- TC-52
  -- "now() advanced past expires_at": now() is fixed for the transaction, so expires_at moves
  -- behind it instead. Same comparison, and no sweep anywhere in it (R42).
  update unlock_requests set expires_at = now() - interval '1 minute' where id = v_unlock;
  v_ok := false; v_err := null;
  begin
    perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotP, v_day + 3,
      jsonb_build_array(jsonb_build_object('lot_id', v_lotP, 'input_weight_kg', 1.00)));
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_CLOSED:%';
  end;
  assert v_ok, format('TC-52: an expired unlock admitted a write (%s)', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-40
  perform fn_close_lot(gen_random_uuid(), v_lotQ);
  select payload into v_payload from notifications where lot_id = v_lotQ and kind = 'YIELD_ALERT';
  assert v_payload -> 'smoke_yield_pct' = 'null'::jsonb
     and (v_payload ->> 'loss_pct')::numeric = 25.00,
    format('TC-40: with no post-drain weight the payload reads %s', v_payload);

  ------------------------------------------------------------------------ TC-41, TC-42
  perform fn_close_lot(gen_random_uuid(), v_lot80);
  select count(*) into v_n from notifications where lot_id = v_lot80;
  assert v_n = 0, format('TC-41: 20.00%% raised %s notification(s); the boundary is > (R16)', v_n);

  perform fn_close_lot(gen_random_uuid(), v_lot79);
  select count(*), max(payload ->> 'loss_pct') into v_n, v_txt
    from notifications where lot_id = v_lot79 and kind = 'YIELD_ALERT';
  assert v_n = 1 and v_txt::numeric = 20.01,
    format('TC-41: 20.01%% raised %s alert(s) reading %s', v_n, v_txt);
  select state::text into v_txt from lots where id = v_lot79;
  assert v_txt = 'LOT_CLOSED', format('TC-42: the alerting lot is %s — the alert must not block (R16b)', v_txt);

  --------------------------------------------------------------------------------- TC-47
  -- F8's dispatch off a closed lot's group now finds weight there. Without the close's
  -- +40.00 this is INSUFFICIENT_STOCK: the tuple would be empty (Seam 4).
  update lots set state = 'RETURN_SCHEDULED' where id = v_lotP;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_run := fn_create_transport_run(gen_random_uuid(), 'CM_TO_FOODIVA', v_day + 5,
                                   p_run_cost_thb => 1500.00, p_lot_ids => array[v_lotP]);
  v_ok := true; v_err := null;
  begin
    perform fn_dispatch_transport_line(gen_random_uuid(), v_run, v_lotP, v_g1, v_chef,
                                       v_central, 40.00);
  exception when others then
    v_err := sqlerrm; v_ok := false;
  end;
  assert v_ok, format('TC-47: dispatching a closed lot''s group failed: %s', v_err);
  select coalesce(sum(balance_qty), 0) into v_kg from v_stock_balance
   where smoke_date_group_id = v_g1 and location_id = v_chef and stock_state = 'FROZEN';
  assert v_kg = 0, format('TC-47: the group still holds %s at the chef house after dispatch', v_kg);

  raise exception 'LOT_CLOSE_TEST_PASSED';
end $$;
