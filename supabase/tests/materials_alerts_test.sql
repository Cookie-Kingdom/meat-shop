-- Failure-case tests for card ^ref-50 — v_material_alerts.
--
-- Covers TC-63 ... TC-73 from TDD-materials.md.
--
-- Assumes no unmerged lane's contract. It does account for one: lane I's ^ref-61 seeds
-- material_alert_ratio = 0.20, and TC-65 is about that key being UNSET, so the seeded row is
-- deleted inside this aborted transaction and re-added at a date the test controls. Every
-- population assert is filtered to this file's own locations and items, so a seeded branch or
-- material cannot move a count.
--
-- Each assert is a way the alert fails silently rather than loudly:
--   * an unconfigured material reads as out of stock, or as fine (R9, the card's acceptance)
--   * exactly 20% alerts, and the Owner reorders stock that is not low (BR20, UAT-13)
--   * a newer global level overrides a branch's own level (scope beats recency)
--   * a future-dated level is used today
--   * an older count wins over today's
--   * receiving new stock moves the base or the remainder (BR20)
--   * an L2 reads another branch's shelf, or an L2 cannot read the ratio at all
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/materials_alerts_test.sql

do $$
declare
  v_owner   uuid := '50505050-5050-5050-5050-505050505001';   -- L1
  v_adm_a   uuid := '50505050-5050-5050-5050-505050505002';   -- L2 at A
  v_adm_b   uuid := '50505050-5050-5050-5050-505050505003';   -- L2 at B
  v_cm      uuid := '50505050-5050-5050-5050-505050505004';   -- L3, also a member of A
  v_bra     uuid;
  v_brb     uuid;
  v_cen     uuid;
  v_chf     uuid;
  v_i199    uuid;
  v_i200    uuid;
  v_i201    uuid;
  v_inofull uuid;
  v_inever  uuid;
  v_iscope  uuid;
  v_ifuture uuid;
  v_iold    uuid;
  v_items   uuid[];
  v_rep_a   uuid;
  v_a       record;
  v_n       bigint;
begin
  delete from config_settings where key = 'material_alert_ratio';

  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_adm_a), (v_adm_b), (v_cm);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',       'L1_OWNER',        true),
    (v_adm_a, 'ผู้ดูแลสาขา ก', 'L2_BRANCH_ADMIN', true),
    (v_adm_b, 'ผู้ดูแลสาขา ข', 'L2_BRANCH_ADMIN', true),
    (v_cm,    'ผู้ปฏิบัติ CM',  'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind, rice_model)
       values ('A50A', 'สาขาวัสดุ ก', 'BRANCH', 'EXTERNAL_COOKED') returning id into v_bra;
  insert into locations (code, name_th, kind, rice_model)
       values ('A50B', 'สาขาวัสดุ ข', 'BRANCH', 'SELF_COOK') returning id into v_brb;
  insert into locations (code, name_th, kind) values ('A50C', 'คลังกลางวัสดุ', 'CENTRAL')
    returning id into v_cen;
  insert into locations (code, name_th, kind) values ('A50H', 'โรงรมวัสดุ', 'CHEF_HOUSE')
    returning id into v_chf;
  insert into user_locations (profile_id, location_id) values
    (v_adm_a, v_bra), (v_adm_b, v_brb), (v_cm, v_bra);

  insert into packaging_items (code, name_th, unit) values ('A50-199', 'กล่องสกรีน',  'ใบ')   returning id into v_i199;
  insert into packaging_items (code, name_th, unit) values ('A50-200', 'กระดาษรอง',   'แผ่น') returning id into v_i200;
  insert into packaging_items (code, name_th, unit) values ('A50-201', 'ถุงซิปเนื้อ', 'ใบ')   returning id into v_i201;
  insert into packaging_items (code, name_th, unit) values ('A50-NOF', 'ถุงซิปข้าว',  'ใบ')   returning id into v_inofull;
  insert into packaging_items (code, name_th, unit) values ('A50-NEV', 'ถุงหิ้วกระดาษ', 'ใบ') returning id into v_inever;
  insert into packaging_items (code, name_th, unit) values ('A50-SCP', 'สติกเกอร์โลโก้', 'ดวง') returning id into v_iscope;
  insert into packaging_items (code, name_th, unit) values ('A50-FUT', 'การ์ดวิธีอุ่น', 'ใบ') returning id into v_ifuture;
  insert into packaging_items (code, name_th, unit, is_active) values ('A50-OLD', 'วัสดุเลิกใช้', 'ใบ', false)
    returning id into v_iold;
  v_items := array[v_i199, v_i200, v_i201, v_inofull, v_inever, v_iscope, v_ifuture, v_iold];

  -- Full levels. v_inofull has none at all: R9's "not configured" is the absence of a row.
  insert into packaging_full_stock (packaging_item_id, location_id, full_stock_qty, effective_from, created_by) values
    (v_i199,    null,  1000, current_date - 30, v_owner),
    (v_i200,    null,  1000, current_date - 30, v_owner),
    (v_i201,    null,  1000, current_date - 30, v_owner),
    (v_inever,  null,  1000, current_date - 30, v_owner),
    -- Newer global 1,000 against an older branch-A 500: the branch row must win at A.
    (v_iscope,  null,  1000, current_date - 1,  v_owner),
    (v_iscope,  v_bra,  500, current_date - 20, v_owner),
    -- In force: 100. Not yet in force: 10.
    (v_ifuture, null,   100, current_date - 10, v_owner),
    (v_ifuture, null,    10, current_date + 5,  v_owner),
    (v_iold,    null,  1000, current_date - 30, v_owner);

  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_bra, current_date, now(), v_adm_a) returning id into v_rep_a;

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);

  -- An older, ad-hoc count of 50 for v_i201. Today's count of 201 must be the one read.
  insert into physical_counts (daily_report_id, location_id, event_date, item_type,
                               packaging_item_id, counted_qty, system_qty, created_by)
       values (null, v_bra, current_date - 3, 'PACKAGING', v_i201, 50, 0, v_adm_a);

  -- Today's BR 08 count at A, through the writer. v_inever is deliberately not counted, and
  -- nothing is counted at B.
  perform fn_record_physical_count(gen_random_uuid(), v_rep_a, jsonb_build_array(
    jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_i199,    'counted_qty', 199),
    jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_i200,    'counted_qty', 200),
    jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_i201,    'counted_qty', 201),
    jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_inofull, 'counted_qty', 5),
    jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_iscope,  'counted_qty', 120),
    jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_ifuture, 'counted_qty', 15)));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-65
  -- No ratio row in force. Every alert is unknown, and none reads as "fine" or as "low".
  -- ADR-023: an unset Owner number is never a defaulted 0.20.
  select count(*) into v_n from v_material_alerts
   where packaging_item_id = any (v_items) and (is_low is not null or alert_ratio is not null);
  assert v_n = 0, format('TC-65: %s row(s) computed an alert with no material_alert_ratio set', v_n);

  insert into config_settings (key, value_numeric, effective_from, created_by)
       values ('material_alert_ratio', 0.20, current_date - 30, v_owner);

  --------------------------------------------------------------------------------- TC-63
  -- UAT-13 / BR20: full 1,000 at 20%. 199 alerts; 200 and 201 do not. Strictly less than.
  select * into v_a from v_material_alerts where location_id = v_bra and packaging_item_id = v_i199;
  assert v_a.is_low is true and v_a.alert_threshold_qty = 200.00 and v_a.remaining_qty = 199,
    format('TC-63: 199 of 1,000 reads is_low [%s], threshold [%s]', v_a.is_low, v_a.alert_threshold_qty);
  select * into v_a from v_material_alerts where location_id = v_bra and packaging_item_id = v_i200;
  assert v_a.is_low is false,
    format('TC-63: exactly 20%% reads is_low [%s] — "เท่ากับ 20%% ไม่เตือน" (BR20)', v_a.is_low);
  select * into v_a from v_material_alerts where location_id = v_bra and packaging_item_id = v_i201;
  assert v_a.is_low is false, format('TC-63: 201 of 1,000 reads is_low [%s]', v_a.is_low);

  --------------------------------------------------------------------------------- TC-64
  -- R9, the card's acceptance: no full level means null — not 0, not true, not false.
  select * into v_a from v_material_alerts where location_id = v_bra and packaging_item_id = v_inofull;
  assert found, 'TC-64: an unconfigured material is missing from the list — it must appear, as unknown';
  assert v_a.full_stock_qty is null and v_a.alert_threshold_qty is null and v_a.is_low is null,
    format('TC-64: an unconfigured material reads full [%s], is_low [%s] — both must be null (R9)',
           v_a.full_stock_qty, v_a.is_low);
  assert v_a.remaining_qty = 5, 'TC-64: the count of an unconfigured material was dropped';

  --------------------------------------------------------------------------------- TC-66
  -- Never counted: the remainder is unknown, not zero, and so is the alert.
  select * into v_a from v_material_alerts where location_id = v_bra and packaging_item_id = v_inever;
  assert found, 'TC-66: an uncounted material is missing from the list';
  assert v_a.remaining_qty is null and v_a.counted_on is null and v_a.is_low is null,
    format('TC-66: an uncounted material reads remaining [%s], is_low [%s]', v_a.remaining_qty, v_a.is_low);
  select count(*) into v_n from v_material_alerts
   where location_id = v_brb and packaging_item_id = any (v_items) and is_low is not null;
  assert v_n = 0, format('TC-66: branch B counted nothing and %s of its rows computed an alert', v_n);

  --------------------------------------------------------------------------------- TC-67
  -- Scope beats recency. At A the branch's own 500 wins over last week's global 1,000, so 120 is
  -- not low (threshold 100). At 1,000 it would be (threshold 200). B has no row of its own.
  select * into v_a from v_material_alerts where location_id = v_bra and packaging_item_id = v_iscope;
  assert v_a.full_stock_qty = 500 and v_a.is_low is false,
    format('TC-67: branch A resolved full [%s], is_low [%s] — the newer global row overrode the branch''s own',
           v_a.full_stock_qty, v_a.is_low);
  select * into v_a from v_material_alerts where location_id = v_brb and packaging_item_id = v_iscope;
  assert v_a.full_stock_qty = 1000, format('TC-67: branch B resolved full [%s], expected the global 1,000', v_a.full_stock_qty);

  --------------------------------------------------------------------------------- TC-68
  -- The level dated five days ahead is not in force today.
  select * into v_a from v_material_alerts where location_id = v_bra and packaging_item_id = v_ifuture;
  assert v_a.full_stock_qty = 100 and v_a.is_low is true,
    format('TC-68: resolved full [%s], is_low [%s] — a future-dated level was used today',
           v_a.full_stock_qty, v_a.is_low);

  --------------------------------------------------------------------------------- TC-69
  select * into v_a from v_material_alerts where location_id = v_bra and packaging_item_id = v_i201;
  assert v_a.remaining_qty = 201 and v_a.counted_on = current_date,
    format('TC-69: remaining [%s] counted on [%s] — the older count of 50 won', v_a.remaining_qty, v_a.counted_on);

  --------------------------------------------------------------------------------- TC-70
  -- BR20 / UAT-13: "รับเพิ่มไม่เปลี่ยนฐานสต็อกเต็ม". Receiving 500 boxes changes neither the full
  -- level (an Owner-set target, R11) nor the remainder (what the branch counted).
  perform fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'PACKAGING',
    p_location_id => v_bra, p_stock_state => 'READY', p_movement_type => 'INTAKE',
    p_qty_delta => 500, p_business_date => current_date, p_packaging_item_id => v_i199);
  select * into v_a from v_material_alerts where location_id = v_bra and packaging_item_id = v_i199;
  assert v_a.full_stock_qty = 1000 and v_a.remaining_qty = 199 and v_a.is_low is true,
    format('TC-70: after an intake, full [%s] remaining [%s] is_low [%s] — receiving moved the base',
           v_a.full_stock_qty, v_a.remaining_qty, v_a.is_low);

  --------------------------------------------------------------------------------- TC-71
  select count(*) into v_n from v_material_alerts where packaging_item_id = v_iold;
  assert v_n = 0, format('TC-71: an inactive material appears in %s row(s)', v_n);
  select count(*) into v_n from v_material_alerts where location_id in (v_cen, v_chf);
  assert v_n = 0, format('TC-71: %s row(s) for CENTRAL or CHEF_HOUSE — BR 08 is a branch check', v_n);
  select count(*) into v_n from v_material_alerts
   where location_id in (v_bra, v_brb) and packaging_item_id = any (v_items);
  assert v_n = 14, format('TC-71: %s rows for 2 branches x 7 active materials, expected 14', v_n);

  --------------------------------------------------------------------------------- TC-72
  -- L2: own branch only, and the ratio resolves for them — the reason it is a subselect and not
  -- fn_config_numeric, which the caller holds no EXECUTE on.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  select count(*) into v_n from v_material_alerts where location_id = v_brb;
  assert v_n = 0, format('TC-72: an L2 of branch A reads %s of branch B''s rows', v_n);
  select count(*) into v_n from v_material_alerts where location_id = v_bra and packaging_item_id = any (v_items);
  assert v_n = 7, format('TC-72: an L2 reads %s of their own branch''s 7 rows', v_n);
  select * into v_a from v_material_alerts where location_id = v_bra and packaging_item_id = v_i199;
  assert v_a.is_low is true and v_a.alert_ratio = 0.20,
    format('TC-72: an L2 reads ratio [%s], is_low [%s] — the ratio did not resolve for the branch', v_a.alert_ratio, v_a.is_low);

  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  select count(*) into v_n from v_material_alerts;
  assert v_n = 0, format('TC-72: an L3 reads %s material rows', v_n);

  --------------------------------------------------------------------------------- TC-73
  assert has_table_privilege('authenticated', 'public.v_material_alerts', 'SELECT'),
    'TC-73: authenticated cannot read v_material_alerts';
  assert not has_table_privilege('anon', 'public.v_material_alerts', 'SELECT'),
    'TC-73: anon can read v_material_alerts';
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'v_material_alerts' and column_name like '%\_thb';
  assert v_n = 0, format('TC-73: v_material_alerts carries %s money column(s) (R20)', v_n);

  raise exception 'MATERIALS_ALERTS_TEST_PASSED';   -- the only clean way back out
end $$;
