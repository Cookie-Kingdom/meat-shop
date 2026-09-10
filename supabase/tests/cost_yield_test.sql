-- Cards ^ref-31 (v_lot_yield) — TC-01 ... TC-08 of v.0.1/ref-31-33-cost/TDD-cost.md.
-- Contract assumed from an unmerged lane: none (every function called is on develop at 9362eca).
--
-- ONE do $$ BLOCK, for lot_close_test.sql's reason: the harness pipes each file into psql
-- without --single-transaction, and the closing raise can only roll back the block it is in.
--
-- The lots are closed through fn_close_lot, never by setting LOT_CLOSED: the view reads the
-- lots.loss_weight_kg the close stores, so a lot closed by hand would test nothing. The one
-- raw balance (lot P's 98.00 kg) is posted with fn_post_ledger directly, the tuple
-- fn_confirm_transport_receipt leaves behind — the transport legs are not under test here.
--
-- ROLE READS RUN AS `authenticated`, NOT AS THE SUPERUSER (PLAN-cost Finding 1). A view's
-- function calls run with the caller's privileges; a superuser session would pass a view that
-- calls an ungranted function and every real L1 read would then fail.
--
-- Everything runs in a transaction that aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/cost_yield_test.sql

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_l2     uuid := gen_random_uuid();
  v_l3     uuid := gen_random_uuid();
  v_day    date := date '2026-05-04';
  v_chef   uuid;
  v_branch uuid;
  v_sup    uuid;
  v_po     uuid;
  v_lotP   uuid;   -- 100 / 98 / 96.50 / 75.00 — UAT-02
  v_lotQ   uuid;   -- same, pre-smoke weight never entered
  v_lotS   uuid;   -- logged, still SMOKING
  v_lot80  uuid;   -- output 80.00: 20.00%, silent
  v_lot79  uuid;   -- output 79.99: 20.01%, alerts
  v_open   uuid;   -- ^ref-62's opening lot
  v_row    record;
  v_n      bigint;
  v_closed bigint;
  v_txt    text;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',               'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',            'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่',    'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind) values ('CH31', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('BR31', 'สาขาทดสอบ', 'BRANCH')
    returning id into v_branch;
  insert into user_locations (profile_id, location_id) values (v_l3, v_chef), (v_l2, v_branch);
  insert into suppliers (name) values ('ฟู้ดดีว่า') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_text => 'true');
  perform fn_set_config(gen_random_uuid(), 'yield_alert_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);

  v_po    := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);
  v_lotP  := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotQ  := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotS  := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lot80 := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lot79 := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);

  update lots set state = 'IN_TRANSIT', assigned_operator_id = v_l3
   where id in (v_lotP, v_lotQ, v_lotS, v_lot80, v_lot79);

  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 'FROZEN', 'TRANSFER_IN',
                         98.00, v_day, p_lot_id => v_lotP);

  -- ^ref-62's shape, inserted directly: the opening path is not under test here.
  insert into lots (lot_code, is_opening, state, event_date)
    values ('OPEN-31', true, 'LOT_CLOSED', v_day) returning id into v_open;

  -- Receipts, logs, bags and closes through the RPCs, as the operator.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);

  perform fn_record_lot_receipt(gen_random_uuid(), v_lotP,  v_day, 98.00, 96.50);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotQ,  v_day, 98.00);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotS,  v_day, 98.00, 96.50);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lot80, v_day, 98.00, 96.50);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lot79, v_day, 98.00, 96.50);

  -- P smokes over two days: 50.00 kg in for 40.00 kg of bags, then 46.50 for 35.00. Output 75.
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotP, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotP, 'input_weight_kg', 50.00)));
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotP, v_day + 1,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotP, 'input_weight_kg', 46.50)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotP, v_day,
                             array(select 0.50::numeric from generate_series(1, 80)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotP, v_day + 1,
                             array(select 0.50::numeric from generate_series(1, 70)));

  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotQ, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotQ, 'input_weight_kg', 96.00)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lotQ, v_day,
                             array(select 0.50::numeric from generate_series(1, 150)));

  -- S has a log and no bags, and is never closed.
  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotS, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lotS, 'input_weight_kg', 40.00)));

  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lot80, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lot80, 'input_weight_kg', 96.50)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lot80, v_day,
                             array(select 0.50::numeric from generate_series(1, 160)));

  perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lot79, v_day,
    jsonb_build_array(jsonb_build_object('lot_id', v_lot79, 'input_weight_kg', 96.50)));
  perform fn_record_lot_bags(gen_random_uuid(), v_lot79, v_day,
                             array(select 0.50::numeric from generate_series(1, 159)) || 0.49::numeric);

  perform fn_close_lot(gen_random_uuid(), v_lotP);
  perform fn_close_lot(gen_random_uuid(), v_lotQ);
  perform fn_close_lot(gen_random_uuid(), v_lot80);
  perform fn_close_lot(gen_random_uuid(), v_lot79);

  -- Every figure below is read as the Owner.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-01
  -- UAT-02. The divisor is the Foodiva dispatch weight: 25 / 100, never 25 / 98 = 25.51 or
  -- (98 − 75) / 98 = 23.47.
  select * into v_row from v_lot_yield where lot_id = v_lotP;
  assert v_row.lot_id is not null, 'TC-01: closed lot P has no v_lot_yield row';
  assert v_row.loss_pct = 25.00,
    format('TC-01: lot P reads loss_pct %s, expected 25.00 (dispatch base, ADR-011)', v_row.loss_pct);
  assert v_row.loss_weight_kg = 25.00,
    format('TC-01: lot P reads loss_weight_kg %s, expected 25.00', v_row.loss_weight_kg);
  assert v_row.output_weight_kg = 75.00,
    format('TC-01: lot P reads output_weight_kg %s, expected 75.00', v_row.output_weight_kg);
  assert v_row.foodiva_sent_weight_kg = 100.00 and v_row.cm_received_weight_kg = 98.00
     and v_row.pre_smoke_weight_kg = 96.50,
    format('TC-01: lot P reads weights %s / %s / %s, expected 100.00 / 98.00 / 96.50',
           v_row.foodiva_sent_weight_kg, v_row.cm_received_weight_kg, v_row.pre_smoke_weight_kg);
  -- The separately named Chiang Mai figure: 75 / 96.50 = 77.72.
  assert v_row.smoke_yield_pct = 77.72,
    format('TC-01: lot P reads smoke_yield_pct %s, expected 77.72 (pre-smoke base)', v_row.smoke_yield_pct);
  assert v_row.po_id = v_po, 'TC-01: lot P does not trace back to its purchase order';

  --------------------------------------------------------------------------------- TC-02
  -- No pre-smoke weight: the smoke yield is "incomplete data" (v0.2 line 349), never a
  -- division by zero and never borrowed from the received weight. Loss is unaffected.
  select * into v_row from v_lot_yield where lot_id = v_lotQ;
  assert v_row.lot_id is not null, 'TC-02: closed lot Q has no v_lot_yield row';
  assert v_row.smoke_yield_pct is null,
    format('TC-02: lot Q, with no pre-smoke weight, reads smoke_yield_pct %s', v_row.smoke_yield_pct);
  assert v_row.loss_pct = 25.00,
    format('TC-02: lot Q reads loss_pct %s, expected 25.00', v_row.loss_pct);

  --------------------------------------------------------------------------------- TC-03
  -- R17: a lot still smoking is never evaluated for final loss.
  select state::text into v_txt from lots where id = v_lotS;
  assert v_txt = 'SMOKING', format('TC-03: fixture lot S is %s, expected SMOKING', v_txt);
  select count(*) into v_n from v_lot_yield where lot_id = v_lotS;
  assert v_n = 0, 'TC-03: a lot still SMOKING has a v_lot_yield row (R17)';

  --------------------------------------------------------------------------------- TC-04
  -- ADR-011's naming rule as a catalogue fact: "loss" names the dispatch-base figures and
  -- nothing else, and there is no money in a yield view.
  select string_agg(column_name::text, ', ' order by column_name), count(*) into v_txt, v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'v_lot_yield'
     and column_name like '%loss%';
  assert v_n = 2 and v_txt = 'loss_pct, loss_weight_kg',
    format('TC-04: v_lot_yield has %s "loss" column(s): %s — only the dispatch-base pair may', v_n, v_txt);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'v_lot_yield'
     and (column_name like '%\_thb' or column_name like '%price%' or column_name like '%cost%');
  assert v_n = 0, format('TC-04: v_lot_yield carries %s money column(s)', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'v_lot_yield'
     and column_name = 'smoke_yield_pct';
  assert v_n = 1, 'TC-04: smoke_yield_pct is not a column of its own (R16a)';

  --------------------------------------------------------------------------------- TC-07
  -- R16 through fn_check_variance: 80.00 of 100 is silent, 79.99 alerts. The view reports the
  -- alert that was raised rather than drawing a boundary of its own.
  select * into v_row from v_lot_yield where lot_id = v_lot80;
  assert v_row.loss_pct = 20.00 and not v_row.yield_alert,
    format('TC-07: output 80.00 reads loss_pct %s, yield_alert %s — expected 20.00 and false',
           v_row.loss_pct, v_row.yield_alert);
  assert v_row.alert_threshold_pct = 20.00,
    format('TC-07: alert_threshold_pct reads %s, expected 20.00', v_row.alert_threshold_pct);

  select * into v_row from v_lot_yield where lot_id = v_lot79;
  assert v_row.loss_pct = 20.01 and v_row.yield_alert,
    format('TC-07: output 79.99 reads loss_pct %s, yield_alert %s — expected 20.01 and true',
           v_row.loss_pct, v_row.yield_alert);

  --------------------------------------------------------------------------------- TC-08
  -- ADR-021: an opening lot has no dispatch weight, so it has no Loss base and no row.
  select count(*) into v_n from v_lot_yield where lot_id = v_open;
  assert v_n = 0, 'TC-08: an opening lot has a v_lot_yield row';

  --------------------------------------------------------------------------------- TC-06
  -- ^ref-64: exactly one session-role grant, and it is SELECT to authenticated.
  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'v_lot_yield'
     and grantee in ('anon', 'authenticated');
  assert v_n = 1, format('TC-06: v_lot_yield holds %s session-role grant(s), not 1', v_n);

  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'v_lot_yield'
     and grantee = 'authenticated' and privilege_type = 'SELECT';
  assert v_n = 1, 'TC-06: v_lot_yield is not readable by authenticated';

  --------------------------------------------------------------------------------- TC-05
  -- R34, R20 — as a real `authenticated` session. L1 sees every closed lot; the operator who
  -- smoked them and a branch admin see nothing. The L1 read is also Finding 1's proof: the
  -- threshold lookup needs no function grant.
  select count(*) into v_closed from lots where state >= 'LOT_CLOSED' and not is_opening;

  set local role authenticated;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_lot_yield;
  assert v_n = v_closed and v_n >= 4,
    format('TC-05: L1 reads %s of %s closed lot(s) as authenticated', v_n, v_closed);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  select count(*) into v_n from v_lot_yield;
  assert v_n = 0, format('TC-05: the assigned L3 reads %s v_lot_yield row(s) — yield is L1 only', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  select count(*) into v_n from v_lot_yield;
  assert v_n = 0, format('TC-05: an L2 reads %s v_lot_yield row(s)', v_n);

  reset role;

  raise exception 'COST_YIELD_TEST_PASSED';   -- the only clean way back out
end $$;
