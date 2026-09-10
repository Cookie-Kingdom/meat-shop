-- Failure-case tests for card ^ref-45: v_branch_diff and fn_close_daily_report.
--
-- Contracts assumed from unmerged lanes:
--   * lane B (^ref-40): fn_require_branch_or_owner(uuid) -> uuid (PLAN-thaw.md T3), and
--     fn_record_thaw(p_idempotency_key, p_daily_report_id, p_lot_id, p_smoke_date_group_id,
--     p_thawed_weight_kg, p_fifo_override_reason) -> json (T5), posting THAW_IN on
--     (SMOKED_MEAT, product NULL, lot, group, branch, READY), with an UNLOCKED report exempt
--     from R28;
--   * lane D (^ref-50): v_material_alerts (161) with location_id, packaging_code,
--     remaining_qty, full_stock_qty and is_low. The material_alerts assertions branch on
--     to_regclass, so this file is correct whether or not lane D has merged.
--
-- Covers TC-38 ... TC-52 of TDD-sales.md, read through PLAN-sales.md B5-B8, B20 and B22:
--   * TC-40 is 0.50 of 3.00 = 16.67%, WITHIN. The TDD said OVER_THRESHOLD, and
--     fn_check_variance cannot produce that.
--   * TC-46 is 11 packs + 0.10 waste against 3.00: 0.70 kg = 23.33%.
--   * The Diff gate runs BEFORE R13 (B6), so an over-band day reads DIFF_OVER_THRESHOLD, not
--     READY_STOCK_NOT_ZERO.
--   * TC-52's material_alerts is null only where the list is not computed (B20).
-- TC-54 needs two sessions and lives in sales_concurrency_test.sh.
--
-- Each scenario runs at its own branch, so one scenario's stock cannot leak into another's
-- Diff: A for UAT-10, K for the in-band remainder, M for the over-band Diff, Z for the zero
-- expected, R for the materials and rice gates, T and W for the clock and its config.
--
-- The rice gate's rice_records rows and the materials gate's physical_counts row are inserted
-- directly, as the migration owner. Lane D's writers are coded at the same time as this file,
-- and the gates are about what those rows say, not about who wrote them (TDD Seam 7, said here
-- out loud).
--
-- Errors are captured into v_err and asserted after the block (see branch_daily_test.sql).
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/day_close_test.sql

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_off    uuid := gen_random_uuid();   -- a deactivated Owner holding a live token
  v_adm_a  uuid := gen_random_uuid();
  v_adm_b  uuid := gen_random_uuid();
  v_cm     uuid := gen_random_uuid();
  v_day    date := date '2026-05-04';
  v_bkk    date := (now() at time zone 'Asia/Bangkok')::date;
  v_bra    uuid;  v_brb uuid;  v_brk uuid;  v_brm uuid;
  v_brz    uuid;  v_brr uuid;  v_brt uuid;  v_brw uuid;
  v_lot    uuid;
  v_grp    uuid;
  v_repA   uuid;  v_repB  uuid;  v_repB2 uuid;  v_repK uuid;  v_repM uuid;
  v_repZ0  uuid;  v_repZ  uuid;  v_repR  uuid;  v_repT  uuid;  v_repW uuid;
  v_box    uuid;
  v_pkg    uuid;
  v_kClose uuid := gen_random_uuid();
  v_res    json;
  v_res2   json;
  v_diff   record;
  v_err    text;
  v_ok     boolean;
  v_n      bigint;
  v_n2     bigint;
  v_led    bigint;
  v_audit  bigint;
  v_kg     numeric;
  v_pct    numeric;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_off), (v_adm_a), (v_adm_b), (v_cm);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',                'L1_OWNER',        true),
    (v_off,   'เจ้าของที่ปิดบัญชีแล้ว',      'L1_OWNER',        false),
    (v_adm_a, 'แอดมินสาขาเอ',            'L2_BRANCH_ADMIN', true),
    (v_adm_b, 'แอดมินสาขาบี',            'L2_BRANCH_ADMIN', true),
    (v_cm,    'ผู้ปฏิบัติงานเชียงใหม่',      'L3_CM_OPERATOR',  true);

  -- rice_model is null everywhere except R, so the rice gate is off unless it is under test.
  insert into locations (code, name_th, kind) values ('BRA45', 'สาขาเอ',  'BRANCH') returning id into v_bra;
  insert into locations (code, name_th, kind) values ('BRB45', 'สาขาบี',  'BRANCH') returning id into v_brb;
  insert into locations (code, name_th, kind) values ('BRK45', 'สาขาเค',  'BRANCH') returning id into v_brk;
  insert into locations (code, name_th, kind) values ('BRM45', 'สาขาเอ็ม', 'BRANCH') returning id into v_brm;
  insert into locations (code, name_th, kind) values ('BRZ45', 'สาขาแซด', 'BRANCH') returning id into v_brz;
  insert into locations (code, name_th, kind, rice_model)
       values ('BRR45', 'สาขาอาร์', 'BRANCH', 'EXTERNAL_COOKED') returning id into v_brr;
  insert into locations (code, name_th, kind) values ('BRT45', 'สาขาที',  'BRANCH') returning id into v_brt;
  insert into locations (code, name_th, kind) values ('BRW45', 'สาขาดับบลิว', 'BRANCH') returning id into v_brw;
  insert into user_locations (profile_id, location_id) values
    (v_adm_a, v_bra), (v_adm_b, v_brb), (v_cm, v_bra);

  insert into lots (lot_code, is_opening, state, event_date)
       values ('LOT-45A', true, 'LOT_CLOSED', v_day - 5) returning id into v_lot;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lot, v_day - 5) returning id into v_grp;
  select id into v_box from products where code = 'MEAT_BOX';

  insert into daily_reports (location_id, report_date, shift_started_at, opened_by) values
    (v_bra, v_day, now(), v_adm_a), (v_brb, v_day, now(), v_adm_b), (v_brk, v_day, now(), v_owner),
    (v_brm, v_day, now(), v_owner), (v_brz, v_day, now(), v_owner), (v_brr, v_day, now(), v_owner),
    (v_brw, v_day, now(), v_owner), (v_brt, v_bkk, now(), v_owner);
  select id into v_repA from daily_reports where location_id = v_bra;
  select id into v_repB from daily_reports where location_id = v_brb;
  select id into v_repK from daily_reports where location_id = v_brk;
  select id into v_repM from daily_reports where location_id = v_brm;
  select id into v_repZ from daily_reports where location_id = v_brz;
  select id into v_repR from daily_reports where location_id = v_brr;
  select id into v_repT from daily_reports where location_id = v_brt;
  select id into v_repW from daily_reports where location_id = v_brw;
  -- Z's previous day, reopened: TC-47 thaws on it and wastes on today.
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by)
       values (v_brz, v_day - 1, now(), 'UNLOCKED', v_owner) returning id into v_repZ0;
  -- B's day two days back, reopened: TC-49 closes it in the morning.
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by)
       values (v_brb, current_date - 2, now(), 'UNLOCKED', v_adm_b) returning id into v_repB2;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_set_config(gen_random_uuid(), 'business_day_close_earliest', date '2026-01-01',
                        p_value_text => '21:00');
  perform fn_set_config(gen_random_uuid(), 'business_day_close_earliest', date '2026-01-01',
                        p_value_text => '23:59', p_scope_location_id => v_brt);
  perform fn_set_config(gen_random_uuid(), 'business_day_close_earliest', date '2026-01-01',
                        p_value_text => 'สามทุ่ม', p_scope_location_id => v_brw);
  perform fn_set_config(gen_random_uuid(), 'avg_pack_weight_kg', date '2026-01-01',
                        p_value_numeric => 0.20);
  perform fn_set_product_price(gen_random_uuid(), v_box, date '2026-01-01', 350.00);

  -- UAT-10's "frozen 10" at each meat branch, landed directly (the legs are not under test).
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_bra, 'FROZEN', 'TRANSFER_IN',
                         10.00, v_day - 1, p_lot_id => v_lot, p_smoke_date_group_id => v_grp);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_brk, 'FROZEN', 'TRANSFER_IN',
                         10.00, v_day - 1, p_lot_id => v_lot, p_smoke_date_group_id => v_grp);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_brm, 'FROZEN', 'TRANSFER_IN',
                         10.00, v_day - 1, p_lot_id => v_lot, p_smoke_date_group_id => v_grp);
  perform fn_post_ledger(gen_random_uuid(), 'SMOKED_MEAT', v_brz, 'FROZEN', 'TRANSFER_IN',
                         10.00, v_day - 2, p_lot_id => v_lot, p_smoke_date_group_id => v_grp);

  ------------------------------------------------------------------- guards, before any row
  --------------------------------------------------------------------------------- TC-43
  -- Another branch's L2, an L3 holding a membership row at A, and a deactivated Owner.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), v_repA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN_LOCATION%',
    format('TC-43: branch B''s admin closed branch A, got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), v_repA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-43: an L3 closed a branch day, got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_off)::text, true);
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), v_repA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'NO_ACTOR%',
    format('TC-43: a deactivated Owner got [%s], expected NO_ACTOR (R31)', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), gen_random_uuid());
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN_LOCATION%',
    format('TC-43: an L2 probing a missing report got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_close_daily_report(null, v_repA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'IDEMPOTENCY_KEY_REQUIRED%',
    format('a null key got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), gen_random_uuid());
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_NOT_FOUND%',
    format('TC-43: an L1 with a missing report got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------- scenario A: UAT-10, whole
  -- Frozen 10, thaw 3, 0.20 kg a pack, sell 12 packs, waste 0.60 -> Diff 0, ready 0, and
  -- frozen still 7 (v0.2:217, UAT-10).
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  perform fn_record_thaw(p_idempotency_key => gen_random_uuid(), p_daily_report_id => v_repA,
                         p_lot_id => v_lot, p_smoke_date_group_id => v_grp, p_thawed_weight_kg => 3.00);
  perform fn_record_sales(gen_random_uuid(), v_repA, jsonb_build_array(jsonb_build_object(
    'product_code', 'MEAT_BOX', 'qty', 12, 'lot_id', v_lot, 'smoke_date_group_id', v_grp)));
  perform fn_record_waste(gen_random_uuid(), v_repA, 'SMOKED_MEAT', 'READY', 0.60,
                          'เนื้อละลายเหลือปลายวัน', v_lot, v_grp);

  --------------------------------------------------------------------------------- TC-38
  select * into v_diff from v_branch_diff where location_id = v_bra and business_date = v_day;
  assert found, 'TC-38: v_branch_diff has no row for branch A on the UAT-10 day';
  assert v_diff.ready_in_kg = 3.00 and v_diff.sold_pack_qty = 12 and v_diff.sold_kg = 2.40
     and v_diff.wasted_kg = 0.60 and v_diff.diff_kg = 0.00
     and v_diff.variance_pct = 0.00 and v_diff.verdict = 'WITHIN',
    format('TC-38: UAT-10 reads ready_in %s, packs %s, sold %s, wasted %s, diff %s, %s%% %s — expected 3.00 / 12 / 2.40 / 0.60 / 0.00 / 0.00 WITHIN',
           v_diff.ready_in_kg, v_diff.sold_pack_qty, v_diff.sold_kg, v_diff.wasted_kg,
           v_diff.diff_kg, v_diff.variance_pct, v_diff.verdict);
  select sum(qty_delta) into v_kg from stock_ledger
   where item_type = 'SMOKED_MEAT' and location_id = v_bra and stock_state = 'FROZEN';
  assert v_kg = 7.00, format('TC-38: FROZEN reads %s at A, expected 7.00 — nothing deducted twice', v_kg);

  -- No money anywhere in the view (Finding 8, R20).
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'v_branch_diff'
     and (column_name like '%thb%' or column_name like '%price%' or column_name like '%cost%');
  assert v_n = 0, format('TC-38: v_branch_diff carries %s money column(s)', v_n);

  --------------------------------------------------------------------------------- TC-39
  -- The role scope, in the WHERE (R34). The branch's own L2 sees its rows and nothing else.
  select count(*) filter (where location_id = v_bra), count(*) filter (where location_id <> v_bra)
    into v_n, v_n2 from v_branch_diff;
  assert v_n >= 1 and v_n2 = 0,
    format('TC-39: A''s admin reads %s row(s) at A and %s elsewhere', v_n, v_n2);

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  select count(*) into v_n from v_branch_diff where location_id = v_bra;
  assert v_n = 0, format('TC-39: B''s admin reads %s of A''s Diff rows', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  select count(*) into v_n from v_branch_diff;
  assert v_n = 0, format('TC-39: an L3 reads %s Diff row(s)', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_branch_diff where location_id = v_bra;
  assert v_n >= 1, 'TC-39: the Owner cannot read branch A''s Diff — the filter is "deny everyone"';

  ------------------------------------------------- the close, by the branch's own L2 (TC-43)
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  select count(*) into v_led from stock_ledger;
  select count(*) into v_audit from audit_log where table_name = 'daily_reports' and row_id = v_repA;

  v_res := fn_close_daily_report(v_kClose, v_repA, 'ปิดวันตามปกติ');
  select count(*) into v_n from daily_reports
   where id = v_repA and status = 'CLOSED' and closed_by = v_adm_a and closed_at is not null
     and close_idempotency_key = v_kClose and remark = 'ปิดวันตามปกติ';
  assert v_n = 1 and (v_res ->> 'status') = 'CLOSED' and (v_res ->> 'daily_report_id')::uuid = v_repA,
    format('TC-43: the branch''s own L2 did not close the reconciled day: %s', v_res);

  --------------------------------------------------------------------------------- TC-50
  -- One audit row, from R32's trigger on the UPDATE, and no ledger row: closing moves no stock.
  select count(*) into v_n  from stock_ledger;
  select count(*) into v_n2 from audit_log where table_name = 'daily_reports' and row_id = v_repA;
  assert v_n = v_led and v_n2 = v_audit + 1,
    format('TC-50: the close wrote %s ledger row(s) and %s audit row(s), expected 0 and 1', v_n - v_led, v_n2 - v_audit);

  --------------------------------------------------------------------------------- TC-52
  -- The key is always present. It is null only where the list is not computed: here, because
  -- lane D's view is absent. Once the view exists, the OPEN day's close carries an array.
  -- It is '[]' because nothing is seeded, and nothing is low (B20).
  assert (v_res::jsonb) ? 'material_alerts', 'TC-52: the close response has no material_alerts key';
  if to_regclass('public.v_material_alerts') is null then
    assert json_typeof(v_res -> 'material_alerts') = 'null',
      format('TC-52: material_alerts is %s with no v_material_alerts to compute it from', v_res -> 'material_alerts');
  else
    assert json_typeof(v_res -> 'material_alerts') = 'array',
      format('TC-52: material_alerts is %s for an OPEN day with v_material_alerts present', v_res -> 'material_alerts');
  end if;

  --------------------------------------------------------------------------------- TC-51
  -- The retry after a dropped connection: the original body, and nothing written. It is NOT
  -- REPORT_ALREADY_CLOSED.
  v_res2 := fn_close_daily_report(v_kClose, v_repA, 'ปิดวันตามปกติ');
  select count(*) into v_n2 from audit_log where table_name = 'daily_reports' and row_id = v_repA;
  assert (v_res2 ->> 'closed_at') = (v_res ->> 'closed_at') and (v_res2 ->> 'status') = 'CLOSED'
     and v_n2 = v_audit + 1,
    format('TC-51: the retry returned %s and left %s audit rows (expected the original body and %s)',
           v_res2, v_n2, v_audit + 1);

  --------------------------------------------------------------------------------- TC-44
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), v_repA);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_ALREADY_CLOSED%' and v_err like '%' || v_day::text || '%',
    format('TC-44: a second close under a new key got [%s]', coalesce(v_err, 'no error at all'));

  ------------------------------------------------------ scenario K: inside the band (TC-40)
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  perform fn_record_thaw(p_idempotency_key => gen_random_uuid(), p_daily_report_id => v_repK,
                         p_lot_id => v_lot, p_smoke_date_group_id => v_grp, p_thawed_weight_kg => 3.00);
  perform fn_record_sales(gen_random_uuid(), v_repK, jsonb_build_array(jsonb_build_object(
    'product_code', 'MEAT_BOX', 'qty', 12, 'lot_id', v_lot, 'smoke_date_group_id', v_grp)));
  perform fn_record_waste(gen_random_uuid(), v_repK, 'SMOKED_MEAT', 'READY', 0.10,
                          'เนื้อละลายเหลือปลายวัน', v_lot, v_grp);

  --------------------------------------------------------------------------------- TC-40
  -- Inflow, not balance. 0.50 is unaccounted: 0.50 of 3.00 is 16.67%, inside the band. The
  -- TDD's "OVER_THRESHOLD" here was an arithmetic slip (PLAN-sales.md B6).
  select * into v_diff from v_branch_diff where location_id = v_brk and business_date = v_day;
  assert v_diff.ready_in_kg = 3.00 and v_diff.sold_kg = 2.40 and v_diff.wasted_kg = 0.10
     and v_diff.diff_kg = 0.50 and v_diff.variance_pct = 16.67 and v_diff.verdict = 'WITHIN',
    format('TC-40: K reads ready_in %s, sold %s, wasted %s, diff %s, %s%% %s — expected 3.00 / 2.40 / 0.10 / 0.50 / 16.67 WITHIN',
           v_diff.ready_in_kg, v_diff.sold_kg, v_diff.wasted_kg, v_diff.diff_kg,
           v_diff.variance_pct, v_diff.verdict);

  --------------------------------------------------------------------------------- TC-45
  -- Inside the band, the gate that speaks is R13, naming the 0.50 kg and its lot.
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), v_repK);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'READY_STOCK_NOT_ZERO%' and v_err like '%0.50%' and v_err like '%LOT-45A%',
    format('TC-45: 0.50 kg left READY got [%s]', coalesce(v_err, 'no error at all'));

  -- The leftover goes to waste (BR19), and then the day closes.
  perform fn_record_waste(gen_random_uuid(), v_repK, 'SMOKED_MEAT', 'READY', 0.50,
                          'เนื้อละลายเหลือปลายวัน', v_lot, v_grp);
  v_res := fn_close_daily_report(gen_random_uuid(), v_repK);
  assert (v_res ->> 'status') = 'CLOSED', format('TC-45: K did not close once READY was written off: %s', v_res);

  ---------------------------------------------------- scenario M: over the band (TC-46, TC-42)
  -- 11 packs (2.20) and 0.10 waste out of 3.00: 0.70 kg, 23.33%. Asked BEFORE R13 (B6), so
  -- the day reads DIFF_OVER_THRESHOLD, the only variance in the system that refuses (Seam 6).
  perform fn_record_thaw(p_idempotency_key => gen_random_uuid(), p_daily_report_id => v_repM,
                         p_lot_id => v_lot, p_smoke_date_group_id => v_grp, p_thawed_weight_kg => 3.00);
  perform fn_record_sales(gen_random_uuid(), v_repM, jsonb_build_array(jsonb_build_object(
    'product_code', 'MEAT_BOX', 'qty', 11, 'lot_id', v_lot, 'smoke_date_group_id', v_grp)));
  perform fn_record_waste(gen_random_uuid(), v_repM, 'SMOKED_MEAT', 'READY', 0.10,
                          'เนื้อละลายเหลือปลายวัน', v_lot, v_grp);

  select * into v_diff from v_branch_diff where location_id = v_brm and business_date = v_day;
  assert v_diff.diff_kg = 0.70 and v_diff.variance_pct = 23.33 and v_diff.verdict = 'OVER_THRESHOLD',
    format('TC-46: M reads diff %s at %s%% %s — expected 0.70 at 23.33 OVER_THRESHOLD',
           v_diff.diff_kg, v_diff.variance_pct, v_diff.verdict);
  v_pct := v_diff.variance_pct;

  --------------------------------------------------------------------------------- TC-46
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), v_repM);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'DIFF_OVER_THRESHOLD%' and v_err like '%0.70%',
    format('TC-46: a 23.33%% Diff got [%s] — expected DIFF_OVER_THRESHOLD naming 0.70 kg, and before R13', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-42
  -- The view (ALERT) and the close (BLOCK) agree on the same fixture to the satang (Seam 6).
  assert v_err like '%' || v_pct::text || ' percent%',
    format('TC-42: the view says %s%% and the close raised [%s]', v_pct, v_err);
  select count(*) into v_n from daily_reports where id = v_repM and status = 'OPEN';
  assert v_n = 1, 'TC-46: the refused close changed the report''s status';

  -------------------------------------------------------- scenario Z: zero expected (TC-47)
  -- Meat thawed on Z's reopened yesterday and written off today: today has no inflow, so the
  -- Diff has nothing to divide by. REASON_REQUIRED, and the close demands a remark (R22, B7).
  perform fn_record_thaw(p_idempotency_key => gen_random_uuid(), p_daily_report_id => v_repZ0,
                         p_lot_id => v_lot, p_smoke_date_group_id => v_grp, p_thawed_weight_kg => 1.00);
  perform fn_record_waste(gen_random_uuid(), v_repZ, 'SMOKED_MEAT', 'READY', 1.00,
                          'เนื้อละลายจากวันที่แก้ย้อนหลัง', v_lot, v_grp);

  select * into v_diff from v_branch_diff where location_id = v_brz and business_date = v_day;
  assert v_diff.ready_in_kg = 0.00 and v_diff.wasted_kg = 1.00
     and v_diff.variance_pct is null and v_diff.verdict = 'REASON_REQUIRED',
    format('TC-47: Z reads ready_in %s, wasted %s, %s%% %s — expected 0.00 / 1.00 / null / REASON_REQUIRED',
           v_diff.ready_in_kg, v_diff.wasted_kg, v_diff.variance_pct, v_diff.verdict);

  --------------------------------------------------------------------------------- TC-47
  foreach v_err in array array[null, '   '] loop
    v_ok := false;
    begin
      perform fn_close_daily_report(gen_random_uuid(), v_repZ, v_err);
    exception when others then
      v_ok := sqlerrm like 'DIFF_REASON_REQUIRED%';
    end;
    assert v_ok, format('TC-47: a zero-expected day closed on remark [%s], or failed for another reason', v_err);
  end loop;

  v_res := fn_close_daily_report(gen_random_uuid(), v_repZ, 'เนื้อที่ละลายไว้เมื่อวานถูกทิ้ง');
  select count(*) into v_n from daily_reports
   where id = v_repZ and status = 'CLOSED' and remark = 'เนื้อที่ละลายไว้เมื่อวานถูกทิ้ง';
  assert v_n = 1, format('TC-47: with a remark the zero-expected day did not close with it: %s', v_res);

  --------------------------------------------------------------------------------- TC-49
  -- An UNLOCKED day two days back closes whatever the hour. The 21:00 gate is about the day's
  -- own shift (B8). Re-closing a past day computes no material list, so it is null (B20).
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_res := fn_close_daily_report(gen_random_uuid(), v_repB2);
  assert (v_res ->> 'status') = 'CLOSED' and json_typeof(v_res -> 'material_alerts') = 'null',
    format('TC-49: an UNLOCKED day two days back did not close, or computed alerts: %s', v_res);

  --------------------------------------------------------------------------------- TC-48
  -- Too early. T's own row says 23:59, on a report dated today in Bangkok. Scope beats recency
  -- (R36). Skipped in the last minute of the Bangkok day, the only minute it cannot be early.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  if (now() at time zone 'Asia/Bangkok')::time < time '23:59' then
    v_err := null;
    begin
      perform fn_close_daily_report(gen_random_uuid(), v_repT);
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'CLOSE_TOO_EARLY%' and v_err like '%23:59%',
      format('TC-48: a close before 23:59 on today''s report got [%s]', coalesce(v_err, 'no error at all'));
  else
    raise notice 'TC-48 skipped: it is 23:59 or later in Bangkok, the one minute the close cannot be early';
  end if;

  -- A close time that is not a time is refused, never read as 21:00 (B8).
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), v_repW);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'CONFIG_WRONG_TYPE%' and v_err like '%business_day_close_earliest%',
    format('B8: a close time of [สามทุ่ม] got [%s]', coalesce(v_err, 'no error at all'));

  ----------------------------------------------- scenario R: the two completeness gates
  -- Materials: derived from packaging_items, so it bites the moment one is active (Finding 6).
  insert into packaging_items (code, name_th, unit)
       values ('BOX-45', 'กล่องทดสอบ', 'ใบ') returning id into v_pkg;
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), v_repR);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'MATERIAL_COUNT_INCOMPLETE%' and v_err like '%BOX-45%',
    format('Finding 6: an uncounted active material got [%s]', coalesce(v_err, 'no error at all'));

  insert into physical_counts (daily_report_id, location_id, event_date, item_type,
                               packaging_item_id, counted_qty, system_qty, created_by)
       values (v_repR, v_brr, v_day, 'PACKAGING', v_pkg, 50, 50, v_owner);

  -- Rice: R has a rice model, so no rice row at all is refused ...
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), v_repR);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'RICE_RECORD_MISSING%',
    format('Finding 6: a rice-model branch with no rice record got [%s]', coalesce(v_err, 'no error at all'));

  -- ... and so is the morning write alone, because tomorrow's carry-in is the evening figure
  -- (B22, relayed from lane D).
  insert into rice_records (daily_report_id, location_id, event_date, model, cooked_received_kg, created_by)
       values (v_repR, v_brr, v_day, 'EXTERNAL_COOKED', 10.00, v_owner);
  v_err := null;
  begin
    perform fn_close_daily_report(gen_random_uuid(), v_repR);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'RICE_RECORD_MISSING%',
    format('B22: a morning-only rice record got [%s]', coalesce(v_err, 'no error at all'));

  update rice_records set cooked_remaining_kg = 2.00 where daily_report_id = v_repR;
  v_res := fn_close_daily_report(gen_random_uuid(), v_repR);
  assert (v_res ->> 'status') = 'CLOSED', format('R did not close once counted and riced: %s', v_res);
  if to_regclass('public.v_material_alerts') is not null then
    -- BOX-45 has no full-stock level, so is_low is null: listed as not configured, never as
    -- fine (R9).
    assert json_array_length(v_res -> 'material_alerts') = 1
       and (v_res -> 'material_alerts' -> 0 ->> 'packaging_item_code') = 'BOX-45'
       and json_typeof(v_res -> 'material_alerts' -> 0 -> 'is_low') = 'null',
      format('B20: R''s material_alerts is %s, expected one unconfigured BOX-45 row', v_res -> 'material_alerts');
  end if;
  update packaging_items set is_active = false where id = v_pkg;

  --------------------------------------------------------------------------------- TC-41
  -- The config change that must not move a closed figure. A 0.22 pack weight effective ON the
  -- UAT-10 day itself: config would now resolve 0.22 for that date, and the Diff still reads
  -- 2.40 because it reads the ledger (R29, BR23, Seam 2).
  perform fn_set_config(gen_random_uuid(), 'avg_pack_weight_kg', v_day, p_value_numeric => 0.22);
  select * into v_diff from v_branch_diff where location_id = v_bra and business_date = v_day;
  assert v_diff.sold_kg = 2.40 and v_diff.diff_kg = 0.00,
    format('TC-41: after 0.22 was dated onto the day, A reads sold %s and diff %s — a closed Diff moved', v_diff.sold_kg, v_diff.diff_kg);

  ------------------------------------------------------------------------------ grants
  assert has_function_privilege('authenticated', 'public.fn_close_daily_report(uuid, uuid, text)', 'EXECUTE'),
    'authenticated cannot execute fn_close_daily_report';
  assert not has_function_privilege('anon', 'public.fn_close_daily_report(uuid, uuid, text)', 'EXECUTE'),
    'anon can execute fn_close_daily_report';
  assert has_table_privilege('authenticated', 'public.v_branch_diff', 'SELECT')
     and not has_table_privilege('anon', 'public.v_branch_diff', 'SELECT'),
    'v_branch_diff grants are wrong: authenticated must read it, anon must not';

  raise exception 'DAY_CLOSE_TEST_PASSED';   -- the only clean way back out
end $$;
