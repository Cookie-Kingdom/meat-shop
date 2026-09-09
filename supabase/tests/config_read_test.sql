-- Failure-case tests for card ^ref-11 — fn_config_value / fn_config_numeric.
--
-- Covers TC-01 … TC-10 from TDD-config-layer.md.
--
-- Each assert is a way resolution fails silently rather than loudly:
--   * a rate entered today moves a figure that was settled last month (BR23, ADR-006)
--   * an unset key resolves to null, a call site coalesces it to 0, and an unconfigured
--     number arrives on a report looking settled (BR04 — avg_pack_weight_kg is the case)
--   * a key/type mismatch arrives as a silent null instead of failing by name
--   * editing a global default silently overrides a per-branch value somebody set
--   * resolution drifts to now(), and the number is right today and wrong next month
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/config_read_test.sql

do $$
declare
  v_actor uuid := '77777777-7777-7777-7777-777777777771';
  v_br_a  uuid;
  v_br_b  uuid;
  v_row   config_settings;
  v_num   numeric;
  v_ok    boolean;
  v_err   text;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_actor);
  insert into profiles (id, display_name, role, is_active)
       values (v_actor, 'เจ้าของทดสอบ', 'L1_OWNER', true);
  insert into locations (code, name_th, kind) values ('BRA', 'สาขาเอ', 'BRANCH')
    returning id into v_br_a;
  insert into locations (code, name_th, kind) values ('BRB', 'สาขาบี', 'BRANCH')
    returning id into v_br_b;

  --------------------------------------------------------------------------------- TC-01
  -- The latest row at or before the date wins.
  insert into config_settings (key, value_numeric, effective_from, created_by)
       values ('brine_pct_of_meat', 10, date '2026-01-01', v_actor),
              ('brine_pct_of_meat', 12, date '2026-06-01', v_actor);

  v_num := fn_config_numeric('brine_pct_of_meat', date '2026-07-01');
  assert v_num = 12, format('TC-01: resolved %s, expected 12', v_num);

  --------------------------------------------------------------------------------- TC-02
  -- The June row does not reach back into May. This is the whole of BR23: a closed period
  -- reads the row it always read, because the lookup key is the event date.
  v_num := fn_config_numeric('brine_pct_of_meat', date '2026-05-15');
  assert v_num = 10, format('TC-02: a new rate moved a closed number — %s, expected 10', v_num);

  --------------------------------------------------------------------------------- TC-05
  -- The boundary is `<=` (R12): a row effective on the event date resolves on that date.
  v_num := fn_config_numeric('brine_pct_of_meat', date '2026-06-01');
  assert v_num = 12, format('TC-05: effective_from = event_date resolved %s, expected 12', v_num);

  --------------------------------------------------------------------------------- TC-10
  -- Resolution never reads now(). The rows above were committed in this transaction, i.e.
  -- "today", and a year-back date still resolves to the historical row.
  v_num := fn_config_numeric('brine_pct_of_meat', date '2026-02-02');
  assert v_num = 10, format('TC-10: resolution drifted to now() — %s, expected 10', v_num);

  --------------------------------------------------------------------------------- TC-03
  -- The key with no row. This must raise. A null here is how an unconfigured rate becomes
  -- a coalesce(…, 0) at a call site and then a settled-looking zero on a report (BR04).
  v_ok := false;
  begin
    perform fn_config_numeric('avg_pack_weight_kg', date '2026-07-01');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_NOT_SET%';
  end;
  assert v_ok, format('TC-03: an unset key did not raise CONFIG_NOT_SET (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-04
  -- Rows exist, but all of them start after the event date. Same answer: not set yet.
  v_ok := false; v_err := null;
  begin
    perform fn_config_numeric('brine_pct_of_meat', date '2025-12-31');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_NOT_SET%';
  end;
  assert v_ok, format('TC-04: a future-only key did not raise CONFIG_NOT_SET (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-06
  -- Scope beats recency. The branch row is OLDER than the global row and still wins:
  -- newest-wins means editing a global default silently overrides a deliberate per-branch
  -- value, and nothing on screen would say so.
  insert into config_settings (key, scope_location_id, value_numeric, effective_from, created_by)
       values ('box_sale_price_thb', v_br_a, 300, date '2026-01-01', v_actor),
              ('box_sale_price_thb', null,   350, date '2026-06-01', v_actor);

  v_num := fn_config_numeric('box_sale_price_thb', date '2026-07-01', v_br_a);
  assert v_num = 300, format('TC-06: recency beat scope — %s, expected the branch row 300', v_num);

  --------------------------------------------------------------------------------- TC-07
  -- ...and with no branch row, the global one is the answer, not CONFIG_NOT_SET.
  insert into config_settings (key, value_numeric, effective_from, created_by)
       values ('rice_serving_weight_kg', 0.20, date '2026-01-01', v_actor);
  v_num := fn_config_numeric('rice_serving_weight_kg', date '2026-07-01', v_br_a);
  assert v_num = 0.20, format('TC-07: global fallback resolved %s, expected 0.20', v_num);

  --------------------------------------------------------------------------------- TC-08
  -- Branch A's row is not branch B's. B falls through to the global row...
  v_num := fn_config_numeric('box_sale_price_thb', date '2026-07-01', v_br_b);
  assert v_num = 350, format('TC-08: branch B read branch A row — %s, expected 350', v_num);

  -- ...and where there is no global row either, B gets CONFIG_NOT_SET rather than A's value.
  insert into config_settings (key, scope_location_id, value_numeric, effective_from, created_by)
       values ('rice_sale_price_thb_per_kg', v_br_a, 45, date '2026-01-01', v_actor);
  v_ok := false; v_err := null;
  begin
    perform fn_config_numeric('rice_sale_price_thb_per_kg', date '2026-07-01', v_br_b);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_NOT_SET%';
  end;
  assert v_ok, format('TC-08: branch B resolved a branch-scoped row belonging to A (%s)',
                      coalesce(v_err, 'no exception at all'));

  -- A global lookup ignores branch rows entirely.
  v_ok := false; v_err := null;
  begin
    perform fn_config_numeric('rice_sale_price_thb_per_kg', date '2026-07-01');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_NOT_SET%';
  end;
  assert v_ok, format('TC-08: a global lookup picked up a branch row (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-09
  -- A numeric caller on a jsonb key fails by name. Silently returning null is how a rate
  -- of "nothing" reaches arithmetic.
  insert into config_settings (key, value_json, effective_from, created_by)
       values ('freight_thb_by_vehicle_type', '{"PICKUP": 1200}'::jsonb, date '2026-01-01', v_actor);

  v_ok := false; v_err := null;
  begin
    perform fn_config_numeric('freight_thb_by_vehicle_type', date '2026-07-01');
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_WRONG_TYPE%';
  end;
  assert v_ok, format('TC-09: a jsonb key read as numeric did not raise CONFIG_WRONG_TYPE (%s)',
                      coalesce(v_err, 'no exception at all'));

  -- The same key through the row helper is fine — that is why the row helper exists.
  v_row := fn_config_value('freight_thb_by_vehicle_type', date '2026-07-01');
  assert v_row.value_json ->> 'PICKUP' = '1200',
    format('TC-09: the jsonb key resolved to %s', v_row.value_json);

  -- And the event date is not optional: a call site must not be able to inherit now().
  v_ok := false; v_err := null;
  begin
    perform fn_config_numeric('brine_pct_of_meat', null);
  exception when others then
    v_err := sqlerrm;
    v_ok  := v_err like '%CONFIG_EVENT_DATE_REQUIRED%';
  end;
  assert v_ok, format('TC-10: a null event date was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  raise exception 'CONFIG_READ_TEST_PASSED';   -- the only clean way back out
end $$;
