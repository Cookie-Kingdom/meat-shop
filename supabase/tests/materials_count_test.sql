-- Failure-case tests for card ^ref-49 — fn_record_physical_count, fn_accept_count_variance and
-- v_count_variance.
--
-- Covers TC-33 ... TC-62 from TDD-materials.md. TC-32 (a batch replayed on one key by two
-- sessions at once) lives in materials_concurrency_test.sh.
--
-- Assumes lane C's ...0018: fn_guard_report_closed raises REPORT_CLOSED on a physical_counts
-- insert against a CLOSED report (PLAN-sales.md T1 §3). TC-60 fails until lane C merges;
-- nothing else here depends on it.
--
-- Each assert is a way the count fails silently rather than loudly:
--   * the count deducts as well, and M6's missing tube disappears from every report (R19)
--   * meat on a truck to the branch counts as meat on its shelf
--   * half a tube is counted and becomes a permanent variance (BR21)
--   * a retried batch lands twice and the variance doubles; a longer replay adds rows
--   * one bad element leaves the first two written
--   * the Owner "fixes" a count by moving another tuple's stock, or accepts one count twice
--   * an accepted count still reads OPEN, so it is accepted again next week
--
-- Errors are captured into v_err and asserted after the block, never inside the handler.
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/materials_count_test.sql

do $$
declare
  v_owner    uuid := '49494949-4949-4949-4949-494949494901';   -- L1
  v_adm_a    uuid := '49494949-4949-4949-4949-494949494902';   -- L2 at A
  v_adm_b    uuid := '49494949-4949-4949-4949-494949494903';   -- L2 at B
  v_cm       uuid := '49494949-4949-4949-4949-494949494904';   -- L3, also a member of A
  v_bra      uuid;
  v_brb      uuid;
  v_p1       uuid;
  v_p2       uuid;
  v_p3       uuid;
  v_chilli   uuid;
  v_lot      uuid;
  v_group    uuid;
  v_rep_a    uuid;
  v_rep_b    uuid;
  v_rep_old  uuid;
  v_l_chin   uuid;
  v_l_chsale uuid;
  v_l_p1     uuid;
  v_l_p2     uuid;
  v_l_meat   uuid;
  v_l_trans  uuid;
  v_l_p1b    uuid;
  v_key      uuid := gen_random_uuid();
  v_c_chilli uuid;
  v_c_p1     uuid;
  v_c_meat   uuid;
  v_c_p2     uuid;
  v_c_hi     uuid;
  v_c_zero   uuid;
  v_counts   jsonb;
  v_res      json;
  v_res2     json;
  v_err      text;
  v_n        bigint;
  v_ledger   bigint;
  v_qty      numeric;
  v_row      physical_counts;
  v_view     record;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_adm_a), (v_adm_b), (v_cm);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',       'L1_OWNER',        true),
    (v_adm_a, 'ผู้ดูแลสาขา ก', 'L2_BRANCH_ADMIN', true),
    (v_adm_b, 'ผู้ดูแลสาขา ข', 'L2_BRANCH_ADMIN', true),
    (v_cm,    'ผู้ปฏิบัติ CM',  'L3_CM_OPERATOR',  true);

  insert into locations (code, name_th, kind, rice_model)
       values ('C49A', 'สาขานับ ก', 'BRANCH', 'EXTERNAL_COOKED') returning id into v_bra;
  insert into locations (code, name_th, kind, rice_model)
       values ('C49B', 'สาขานับ ข', 'BRANCH', 'SELF_COOK') returning id into v_brb;
  insert into user_locations (profile_id, location_id) values
    (v_adm_a, v_bra), (v_adm_b, v_brb), (v_cm, v_bra);

  insert into packaging_items (code, name_th, unit) values ('C49-BOX', 'กล่องสกรีน', 'ใบ')
    returning id into v_p1;
  insert into packaging_items (code, name_th, unit) values ('C49-ZIP', 'ถุงซิปเนื้อ', 'ใบ')
    returning id into v_p2;
  insert into packaging_items (code, name_th, unit, is_active) values ('C49-OLD', 'วัสดุเลิกใช้', 'ใบ', false)
    returning id into v_p3;
  insert into products (code, name_th, item_type, sale_unit) values ('C49-CHILLI', 'น้ำพริกทดสอบ', 'CHILLI_PASTE', 'tube')
    returning id into v_chilli;

  -- An opening lot: it has no purchase order behind it, and fn_guard_lot_closed exempts it, so
  -- its smoke date group inserts directly (...0012, ...0013).
  insert into lots (lot_code, is_opening, state, event_date)
       values ('C49-OPN', true, 'LOT_CLOSED', current_date - 5) returning id into v_lot;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lot, current_date - 5)
    returning id into v_group;

  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_bra, current_date, now(), v_adm_a) returning id into v_rep_a;
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_brb, current_date, now(), v_adm_b) returning id into v_rep_b;

  -- Stock, posted the only way stock is posted. M6: receive 100, sell 12, the system says 88.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_l_chin := fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'CHILLI_PASTE',
    p_location_id => v_bra, p_stock_state => 'READY', p_movement_type => 'INTAKE',
    p_qty_delta => 100, p_business_date => current_date, p_product_id => v_chilli);
  v_l_chsale := fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'CHILLI_PASTE',
    p_location_id => v_bra, p_stock_state => 'READY', p_movement_type => 'SALE',
    p_qty_delta => -12, p_business_date => current_date, p_product_id => v_chilli);
  v_l_p1 := fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'PACKAGING',
    p_location_id => v_bra, p_stock_state => 'READY', p_movement_type => 'INTAKE',
    p_qty_delta => 50, p_business_date => current_date, p_packaging_item_id => v_p1);
  v_l_p2 := fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'PACKAGING',
    p_location_id => v_bra, p_stock_state => 'READY', p_movement_type => 'INTAKE',
    p_qty_delta => 30, p_business_date => current_date, p_packaging_item_id => v_p2);
  v_l_meat := fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_bra, p_stock_state => 'FROZEN', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 10, p_business_date => current_date, p_lot_id => v_lot, p_smoke_date_group_id => v_group);
  -- On the truck to A, and NOT on A's shelf.
  v_l_trans := fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'SMOKED_MEAT',
    p_location_id => v_bra, p_stock_state => 'IN_TRANSIT', p_movement_type => 'TRANSFER_IN',
    p_qty_delta => 5, p_business_date => current_date, p_lot_id => v_lot, p_smoke_date_group_id => v_group);
  -- The same item, at another branch.
  v_l_p1b := fn_post_ledger(p_idempotency_key => gen_random_uuid(), p_item_type => 'PACKAGING',
    p_location_id => v_brb, p_stock_state => 'READY', p_movement_type => 'INTAKE',
    p_qty_delta => 20, p_business_date => current_date, p_packaging_item_id => v_p1);

  --------------------------------------------------------------------------------- TC-33
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_counts := jsonb_build_array(jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 87));

  v_err := null;
  begin
    perform fn_record_physical_count(null, v_rep_a, v_counts);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'IDEMPOTENCY_KEY_REQUIRED%',
    format('TC-33: expected IDEMPOTENCY_KEY_REQUIRED, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-34
  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), gen_random_uuid(), v_counts);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_NOT_FOUND%',
    format('TC-34: expected REPORT_NOT_FOUND, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-35
  -- L1 views and configures supporting stock and does not count it (v0.2:58); L3 has no access.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_a, v_counts);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-35: an L1 Owner counted a branch shelf, got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_a, v_counts);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-35: an L3 with a membership row counted a branch, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-36
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_a, v_counts);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN_LOCATION%',
    format('TC-36: an L2 of branch B counted branch A, got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);

  --------------------------------------------------------------------------------- TC-37
  foreach v_counts in array array[null::jsonb, '{}'::jsonb, '[]'::jsonb] loop
    v_err := null;
    begin
      perform fn_record_physical_count(gen_random_uuid(), v_rep_a, v_counts);
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'COUNTS_REQUIRED%',
      format('TC-37: p_counts [%s] got [%s]', coalesce(v_counts::text, 'null'), coalesce(v_err, 'no error at all'));
  end loop;

  --------------------------------------------------------------------------------- TC-38
  -- Rice is recorded by fn_record_rice, never counted here; and an unknown type is not a type.
  foreach v_err in array array['COOKED_RICE', 'RAW_RICE', 'BOGUS'] loop
    v_counts := jsonb_build_array(jsonb_build_object('item_type', v_err, 'counted_qty', 1));
    v_err := null;
    begin
      perform fn_record_physical_count(gen_random_uuid(), v_rep_a, v_counts);
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'COUNT_ITEM_INVALID%',
      format('TC-38: %s got [%s]', v_counts, coalesce(v_err, 'no error at all'));
  end loop;

  --------------------------------------------------------------------------------- TC-39
  foreach v_counts in array array[
      jsonb_build_array(jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', -1)),
      jsonb_build_array(jsonb_build_object('item_type', 'CHILLI_PASTE')),
      jsonb_build_array(jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 'many'))] loop
    v_err := null;
    begin
      perform fn_record_physical_count(gen_random_uuid(), v_rep_a, v_counts);
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'COUNT_QTY_INVALID%',
      format('TC-39: %s got [%s]', v_counts, coalesce(v_err, 'no error at all'));
  end loop;

  --------------------------------------------------------------------------------- TC-40
  -- BR21, both unit-counted types. The CHECK is the backstop; this is the named refusal.
  foreach v_counts in array array[
      jsonb_build_array(jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 10.5)),
      jsonb_build_array(jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_p1, 'counted_qty', 2.5))] loop
    v_err := null;
    begin
      perform fn_record_physical_count(gen_random_uuid(), v_rep_a, v_counts);
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'QTY_NOT_WHOLE_UNITS%',
      format('TC-40: %s got [%s]', v_counts, coalesce(v_err, 'no error at all'));
  end loop;

  --------------------------------------------------------------------------------- TC-41
  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_a,
      jsonb_build_array(jsonb_build_object('item_type', 'PACKAGING', 'counted_qty', 3)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'PACKAGING_ITEM_REQUIRED%',
    format('TC-41: a packaging count with no item got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_a,
      jsonb_build_array(jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_p3, 'counted_qty', 3)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'PACKAGING_ITEM_NOT_FOUND%',
    format('TC-41: an inactive packaging item was counted, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-42
  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_a,
      jsonb_build_array(jsonb_build_object('item_type', 'SMOKED_MEAT', 'counted_qty', 3)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'SMOKE_GROUP_REQUIRED%',
    format('TC-42: a meat count with no smoke date got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_a,
      jsonb_build_array(jsonb_build_object('item_type', 'SMOKED_MEAT', 'smoke_date_group_id', gen_random_uuid(), 'counted_qty', 3)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'SMOKE_GROUP_NOT_FOUND%',
    format('TC-42: an unknown smoke group was counted, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-43
  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_a, jsonb_build_array(
      jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 87),
      jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 86)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'COUNT_ITEM_DUPLICATED%',
    format('TC-43: one item counted twice in a batch got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-44
  -- Two good elements then a bad one. Nothing lands: validation runs before any write.
  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_a, jsonb_build_array(
      jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 87),
      jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_p1, 'counted_qty', 40),
      jsonb_build_object('item_type', 'COOKED_RICE', 'counted_qty', 4)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'COUNT_ITEM_INVALID%',
    format('TC-44: expected COUNT_ITEM_INVALID on element 3, got [%s]', coalesce(v_err, 'no error at all'));
  select count(*) into v_n from physical_counts where location_id in (v_bra, v_brb);
  assert v_n = 0, format('TC-33..44: %s count row(s) written by calls that all raised', v_n);

  ------------------------------------------------------------------------ the happy path
  select count(*) into v_ledger from stock_ledger;

  --------------------------------------------------------------------------------- TC-45
  v_res := fn_record_physical_count(v_key, v_rep_a, jsonb_build_array(
    jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 87),
    jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_p1, 'counted_qty', 40,
                       'reason', 'กล่องเปียกทิ้งไป'),
    jsonb_build_object('item_type', 'SMOKED_MEAT', 'smoke_date_group_id', v_group, 'counted_qty', 9.50)));

  select id into v_c_chilli from physical_counts where idempotency_key = v_key and seq = 1;
  select id into v_c_p1     from physical_counts where idempotency_key = v_key and seq = 2;
  select id into v_c_meat   from physical_counts where idempotency_key = v_key and seq = 3;

  select * into v_row from physical_counts where id = v_c_chilli;
  assert v_row.item_type = 'CHILLI_PASTE' and v_row.system_qty = 88 and v_row.variance_qty = -1,
    format('TC-45: chilli counted 87 against [%s], variance [%s] — M6 says 88 and -1', v_row.system_qty, v_row.variance_qty);

  select * into v_row from physical_counts where id = v_c_p1;
  assert v_row.packaging_item_id = v_p1 and v_row.system_qty = 50 and v_row.variance_qty = -10,
    format('TC-45: packaging counted 40 against [%s], variance [%s], expected 50 and -10 — and not branch B''s 20',
           v_row.system_qty, v_row.variance_qty);

  select * into v_row from physical_counts where id = v_c_meat;
  assert v_row.smoke_date_group_id = v_group and v_row.system_qty = 10.00 and v_row.variance_qty = -0.50,
    format('TC-45: meat counted 9.50 against [%s] — 5 kg is on the truck, not on the shelf; expected 10.00',
           v_row.system_qty);

  --------------------------------------------------------------------------------- TC-46
  select count(*) into v_n from physical_counts
   where idempotency_key = v_key and daily_report_id = v_rep_a and location_id = v_bra
     and event_date = current_date and created_by = v_adm_a;
  assert v_n = 3, format('TC-46: %s of 3 rows carry the key, report, branch, business date and actor', v_n);
  select string_agg(seq::text, ',' order by seq) into v_err from physical_counts where idempotency_key = v_key;
  assert v_err = '1,2,3', format('TC-46: seq is [%s], expected 1,2,3 — the batch''s own order', v_err);
  select reason into v_err from physical_counts where id = v_c_p1;
  assert v_err = 'กล่องเปียกทิ้งไป', format('TC-46: the packaging row''s reason is [%s]', coalesce(v_err, 'null'));
  assert (v_res -> 'physical_count_ids' ->> 0)::uuid = v_c_chilli
     and json_array_length(v_res -> 'physical_count_ids') = 3,
    'TC-46: the response ids are not the batch in seq order';
  assert (v_res -> 'counts' -> 1 ->> 'variance_qty')::numeric = -10,
    'TC-46: the response does not carry each row''s variance';

  --------------------------------------------------------------------------------- TC-47
  -- R19, the card's acceptance: a count never writes the ledger.
  select count(*) into v_n from stock_ledger;
  assert v_n = v_ledger, format('TC-47: a count wrote %s ledger row(s) — a count reports, it never posts (R19)', v_n - v_ledger);

  --------------------------------------------------------------------------------- TC-48
  -- The key wins, over the same payload and over a different one (R4).
  v_res2 := fn_record_physical_count(v_key, v_rep_a, jsonb_build_array(
    jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 87),
    jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_p1, 'counted_qty', 40),
    jsonb_build_object('item_type', 'SMOKED_MEAT', 'smoke_date_group_id', v_group, 'counted_qty', 9.50)));
  assert (v_res2 -> 'physical_count_ids')::text = (v_res -> 'physical_count_ids')::text,
    'TC-48: a replay returned different ids';

  v_res2 := fn_record_physical_count(v_key, v_rep_a, jsonb_build_array(
    jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 1),
    jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_p2, 'counted_qty', 1),
    jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_p1, 'counted_qty', 1),
    jsonb_build_object('item_type', 'SMOKED_MEAT', 'smoke_date_group_id', v_group, 'counted_qty', 1)));
  assert (v_res2 -> 'physical_count_ids')::text = (v_res -> 'physical_count_ids')::text,
    'TC-48: a replay with a different, longer payload did not return the original batch';
  select count(*) into v_n from physical_counts where idempotency_key = v_key;
  assert v_n = 3, format('TC-48: the key holds %s rows after two replays, expected 3', v_n);

  --------------------------------------------------------------------------------- TC-49
  -- A recount under a new key appends; the first count stays (v0.2:253).
  v_res2 := fn_record_physical_count(gen_random_uuid(), v_rep_a, jsonb_build_array(
    jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_p2, 'counted_qty', 30)));
  v_c_p2 := (v_res2 -> 'physical_count_ids' ->> 0)::uuid;
  select count(*) into v_n from physical_counts where daily_report_id = v_rep_a;
  assert v_n = 4, format('TC-49: %s count rows on the report after a recount, expected 4', v_n);

  --------------------------------------------------------------------------------- TC-50
  select * into v_view from v_count_variance where physical_count_id = v_c_chilli;
  assert v_view.status = 'OPEN', format('TC-50: a -1 variance reads [%s], expected OPEN', v_view.status);
  select * into v_view from v_count_variance where physical_count_id = v_c_p2;
  assert v_view.status = 'MATCHED', format('TC-50: a zero variance reads [%s], expected MATCHED', v_view.status);
  select * into v_view from v_count_variance where physical_count_id = v_c_meat;
  assert v_view.lot_id = v_lot, 'TC-50: the meat count''s lot did not resolve through its smoke date group (ADR-017)';
  assert v_view.counted_by = v_adm_a, 'TC-50: counted_by is not the counter';

  --------------------------------------------------------------------------------- TC-51
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_b)::text, true);
  select count(*) into v_n from v_count_variance where location_id = v_bra;
  assert v_n = 0, format('TC-51: an L2 of branch B reads %s of branch A''s counts', v_n);
  perform set_config('request.jwt.claims', json_build_object('sub', v_cm)::text, true);
  select count(*) into v_n from v_count_variance;
  assert v_n = 0, format('TC-51: an L3 reads %s count rows', v_n);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_count_variance;
  select count(*) into v_ledger from physical_counts;
  assert v_n = v_ledger, format('TC-51: L1 reads %s of %s count rows', v_n, v_ledger);

  ----------------------------------------------------------------- accepting a variance
  --------------------------------------------------------------------------------- TC-52
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_err := null;
  begin
    perform fn_accept_count_variance(gen_random_uuid(), v_c_chilli, v_l_chsale, 'ขายจริง 13 หลอด');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'FORBIDDEN:%',
    format('TC-52: an L2 accepted a variance — a ledger correction is the Owner''s (R2), got [%s]', coalesce(v_err, 'no error at all'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-53
  v_err := null;
  begin
    perform fn_accept_count_variance(gen_random_uuid(), v_c_chilli, v_l_chsale, '   ');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'COUNT_REASON_REQUIRED%',
    format('TC-53: expected COUNT_REASON_REQUIRED, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-54
  v_err := null;
  begin
    perform fn_accept_count_variance(gen_random_uuid(), gen_random_uuid(), v_l_chsale, 'x');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'COUNT_NOT_FOUND%',
    format('TC-54: expected COUNT_NOT_FOUND, got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_accept_count_variance(gen_random_uuid(), v_c_p2, v_l_p2, 'x');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'COUNT_NO_VARIANCE%',
    format('TC-54: a matched count was accepted, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-55
  v_err := null;
  begin
    perform fn_accept_count_variance(gen_random_uuid(), v_c_p1, gen_random_uuid(), 'x');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'LEDGER_ROW_NOT_FOUND%',
    format('TC-55: expected LEDGER_ROW_NOT_FOUND, got [%s]', coalesce(v_err, 'no error at all'));

  -- Another packaging item; meat on the truck; the same item at another branch.
  v_err := null;
  begin
    perform fn_accept_count_variance(gen_random_uuid(), v_c_p1, v_l_p2, 'x');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'COUNT_CORRECTION_WRONG_TUPLE%',
    format('TC-55: a box count was corrected against a zip-bag row, got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_accept_count_variance(gen_random_uuid(), v_c_meat, v_l_trans, 'x');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'COUNT_CORRECTION_WRONG_TUPLE%',
    format('TC-55: a shelf count was corrected against IN_TRANSIT meat, got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    perform fn_accept_count_variance(gen_random_uuid(), v_c_p1, v_l_p1b, 'x');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'COUNT_CORRECTION_WRONG_TUPLE%',
    format('TC-55: branch A''s count was corrected against branch B''s row, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-56
  -- A recount of 101 tubes against a system of 88: +13. Correcting the SALE of -12 by +13 would
  -- turn a sale into an intake of 1.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_res2 := fn_record_physical_count(gen_random_uuid(), v_rep_a,
    jsonb_build_array(jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 101)));
  v_c_hi := (v_res2 -> 'physical_count_ids' ->> 0)::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  v_err := null;
  begin
    perform fn_accept_count_variance(gen_random_uuid(), v_c_hi, v_l_chsale, 'นับใหม่');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'COUNT_CORRECTION_TOO_LARGE%',
    format('TC-56: a sale was corrected into an intake, got [%s]', coalesce(v_err, 'no error at all'));

  select count(*) into v_n from stock_ledger;
  select count(*) into v_ledger from stock_ledger where reversal_of is not null;
  assert v_ledger = 0, format('TC-52..56: %s reversal row(s) posted by acceptances that all raised', v_ledger);

  --------------------------------------------------------------------------------- TC-57
  -- M6's case, closed: the sale of 12 was really 13.
  v_res := fn_accept_count_variance(gen_random_uuid(), v_c_chilli, v_l_chsale, 'ขายจริง 13 หลอด');

  select qty_delta into v_qty from stock_ledger
   where id = (v_res ->> 'reversal_id')::uuid and reversal_of = v_l_chsale and movement_type = 'REVERSAL';
  assert v_qty = 12, format('TC-57: the reversal moved [%s], expected +12 against the sale', coalesce(v_qty::text, 'no row'));

  select qty_delta into v_qty from stock_ledger
   where id = (v_res ->> 'replacement_id')::uuid and movement_type = 'SALE';
  assert v_qty = -13, format('TC-57: the replacement moved [%s], expected -13 (-12 + -1)', coalesce(v_qty::text, 'no row'));

  select sum(qty_delta) into v_qty from stock_ledger
   where location_id = v_bra and item_type = 'CHILLI_PASTE' and stock_state <> 'IN_TRANSIT';
  assert v_qty = 87, format('TC-57: chilli at A is %s after the acceptance, and the shelf says 87', v_qty);

  select * into v_view from v_count_variance where physical_count_id = v_c_chilli;
  assert v_view.status = 'ACCEPTED'
     and v_view.correction_reversal_id    = (v_res ->> 'reversal_id')::uuid
     and v_view.correction_replacement_id = (v_res ->> 'replacement_id')::uuid
     and v_view.corrected_by = v_owner
     and v_view.correction_reason = 'ขายจริง 13 หลอด',
    format('TC-57: the accepted count reads [%s] in v_count_variance, or its correction ids do not match', v_view.status);

  --------------------------------------------------------------------------------- TC-58
  -- A retry under a different caller key is still this count's one acceptance (R4).
  v_res2 := fn_accept_count_variance(gen_random_uuid(), v_c_chilli, v_l_chsale, 'ขายจริง 13 หลอด');
  assert (v_res2 ->> 'reversal_id') = (v_res ->> 'reversal_id')
     and (v_res2 ->> 'replacement_id') = (v_res ->> 'replacement_id'),
    'TC-58: a retried acceptance returned a different pair';
  select count(*) into v_n from stock_ledger where reversal_of = v_l_chsale;
  assert v_n = 1, format('TC-58: the sale has %s reversals after a retry', v_n);

  v_err := null;
  begin
    perform fn_accept_count_variance(gen_random_uuid(), v_c_chilli, v_l_chin, 'x');
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'COUNT_ALREADY_ACCEPTED%',
    format('TC-58: one count was accepted twice against two rows, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-59
  -- Zip bags counted at 0 against 30: correcting the +30 intake by -30 is a plain cancellation.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_res2 := fn_record_physical_count(gen_random_uuid(), v_rep_a,
    jsonb_build_array(jsonb_build_object('item_type', 'PACKAGING', 'packaging_item_id', v_p2, 'counted_qty', 0)));
  v_c_zero := (v_res2 -> 'physical_count_ids' ->> 0)::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  v_res := fn_accept_count_variance(gen_random_uuid(), v_c_zero, v_l_p2, 'ของไม่เคยมาถึง');
  assert (v_res ->> 'reversal_id') is not null and (v_res ->> 'replacement_id') is null,
    format('TC-59: expected a reversal and no replacement, got %s', v_res);
  select coalesce(sum(qty_delta), 0) into v_qty from stock_ledger
   where location_id = v_bra and packaging_item_id = v_p2;
  assert v_qty = 0, format('TC-59: zip bags at A read %s after cancelling the intake', v_qty);

  --------------------------------------------------------------------------------- TC-60
  -- Lane C's trigger, not this function, refuses a closed day (PLAN Finding 4).
  update daily_reports set status = 'CLOSED', closed_by = v_adm_a, closed_at = now() where id = v_rep_a;
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_a)::text, true);
  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_a,
      jsonb_build_array(jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 87)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like '%REPORT_CLOSED%',
    format('TC-60: a closed day took a count, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-61
  -- A day ten back and OPEN: today's report at A was closed in TC-60, so daily_reports_one_open
  -- has room, and lane C's guard admits OPEN. The window is the only thing left to refuse it.
  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_bra, current_date - 10, now() - interval '10 days', v_adm_a)
    returning id into v_rep_old;
  insert into opening_balance_close (closed_by, closed_idempotency_key) values (v_owner, gen_random_uuid());
  insert into config_settings (key, value_numeric, effective_from, created_by)
       values ('unlock_max_days_back', 3, date '2026-01-01', v_owner);

  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_old,
      jsonb_build_array(jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 87)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'BACKDATE_NOT_ALLOWED%',
    format('TC-61: a day ten back took a count with a 3-day window, got [%s]', coalesce(v_err, 'no error at all'));

  -- The same day, UNLOCKED. The approved unlock is the escalation for an old day, so the window
  -- no longer applies (v0.2:401 D07; the coordinator's rule, shared with lanes B and C).
  update daily_reports set status = 'UNLOCKED' where id = v_rep_old;
  v_err := null;
  begin
    perform fn_record_physical_count(gen_random_uuid(), v_rep_old,
      jsonb_build_array(jsonb_build_object('item_type', 'CHILLI_PASTE', 'counted_qty', 87)));
  exception when others then v_err := sqlerrm;
  end;
  assert v_err is null,
    format('TC-61: an UNLOCKED day ten back refused a count — the unlock is the escalation, got [%s]', v_err);
  select count(*) into v_n from physical_counts where daily_report_id = v_rep_old;
  assert v_n = 1, format('TC-61: the unlocked day holds %s count rows, expected 1', v_n);

  --------------------------------------------------------------------------------- TC-62
  assert has_function_privilege('authenticated', 'public.fn_record_physical_count(uuid, uuid, jsonb)', 'EXECUTE'),
    'TC-62: authenticated cannot execute fn_record_physical_count';
  assert not has_function_privilege('anon', 'public.fn_record_physical_count(uuid, uuid, jsonb)', 'EXECUTE'),
    'TC-62: anon can execute fn_record_physical_count';
  assert has_function_privilege('authenticated', 'public.fn_accept_count_variance(uuid, uuid, uuid, text)', 'EXECUTE'),
    'TC-62: authenticated cannot execute fn_accept_count_variance';
  assert not has_function_privilege('anon', 'public.fn_accept_count_variance(uuid, uuid, uuid, text)', 'EXECUTE'),
    'TC-62: anon can execute fn_accept_count_variance';
  assert has_table_privilege('authenticated', 'public.v_count_variance', 'SELECT'),
    'TC-62: authenticated cannot read v_count_variance';
  assert not has_table_privilege('anon', 'public.v_count_variance', 'SELECT'),
    'TC-62: anon can read v_count_variance';

  raise exception 'MATERIALS_COUNT_TEST_PASSED';   -- the only clean way back out
end $$;
