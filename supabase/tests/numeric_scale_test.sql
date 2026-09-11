-- Card ^fix-numeric-scale — a write RPC refuses a third decimal by name instead of rounding it.
--
-- Covers NS-01 ... NS-04 and NS-10 of v.0.1/ready-fix-numeric-scale/PLAN-numeric-scale.md. NS-05
-- ... NS-08 live beside the fixtures they need, in materials_count_test.sql, production_test.sql,
-- config_writers_test.sql and expenses_test.sql. NS-09 is rls_deny_all_test.sql sweep 1f.
--
-- No fixture. The guard runs straight after IDEMPOTENCY_KEY_REQUIRED and before any role
-- preamble or table read (PLAN D1), so every call below is made with no session and with null
-- for every other argument. Each call sits in its own sub-block.
--
-- Each assert is a way a third decimal gets through silently:
--   * a writer that never calls the guard, so its numeric(12,2) column rounds 1.005 to 1.01
--   * a writer that guards the wrong parameter, so the message names another input
--   * a guard that checks scale instead of value, so a form's 1.500 is refused
--   * a new writer added later with a numeric input and no guard (NS-10)
--
-- Everything runs in a transaction that aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/numeric_scale_test.sql

do $$
declare
  r      record;
  v_num  numeric;
  v_err  text;
  v_seen text[] := '{}';
  v_bad  text;
  v_n    bigint;
begin
  --------------------------------------------------------------------------------- NS-01
  -- Values, not scale: 1.500 is 1.50. A null passes, because each caller keeps its own null rule.
  perform fn_require_two_decimals('p_test_kg', v)
     from unnest(array[null, 0, 1.5, 1.500, -2.25]::numeric[]) as v;

  --------------------------------------------------------------------------------- NS-02
  foreach v_num in array array[1.005, -0.001, 1.0050]::numeric[] loop
    v_err := null;
    begin
      perform fn_require_two_decimals('p_test_kg', v_num);
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'TOO_MANY_DECIMALS: p_test_kg is %',
      format('NS-02: %s got [%s]', v_num, coalesce(v_err, 'no error at all'));
  end loop;

  ------------------------------------------------------------------------- NS-03, NS-04
  -- Every scalar money, weight or quantity input of every writer in the PLAN's inventory, 1-18.
  -- %s is the value under test.
  for r in select * from (values
      ('fn_record_rice',               'p_cooked_received_kg',    'select fn_record_rice(gen_random_uuid(), null, p_cooked_received_kg => %s)'),
      ('fn_record_rice',               'p_raw_purchased_kg',      'select fn_record_rice(gen_random_uuid(), null, p_raw_purchased_kg => %s)'),
      ('fn_record_rice',               'p_cooked_today_kg',       'select fn_record_rice(gen_random_uuid(), null, p_cooked_today_kg => %s)'),
      ('fn_record_rice',               'p_raw_remaining_kg',      'select fn_record_rice(gen_random_uuid(), null, p_raw_remaining_kg => %s)'),
      ('fn_record_rice',               'p_cooked_remaining_kg',   'select fn_record_rice(gen_random_uuid(), null, p_cooked_remaining_kg => %s)'),
      ('fn_record_branch_expense',     'p_amount_thb',            'select fn_record_branch_expense(gen_random_uuid(), null, null, %s, null)'),
      ('fn_add_po_delivery',           'p_foodiva_sent_weight_kg','select fn_add_po_delivery(gen_random_uuid(), null, null, %s, null)'),
      ('fn_allocate_to_branch',        'p_dispatched_weight_kg',  'select fn_allocate_to_branch(gen_random_uuid(), null, null, null, %s, null)'),
      ('fn_confirm_central_intake',    'p_received_weight_kg',    'select fn_confirm_central_intake(gen_random_uuid(), null, null, %s)'),
      ('fn_confirm_transport_receipt', 'p_received_weight_kg',    'select fn_confirm_transport_receipt(gen_random_uuid(), null, null, %s)'),
      ('fn_create_po',                 'p_ordered_weight_kg',     'select fn_create_po(gen_random_uuid(), null, null, %s)'),
      ('fn_create_po',                 'p_unit_price_thb_per_kg', 'select fn_create_po(gen_random_uuid(), null, null, null, p_unit_price_thb_per_kg => %s)'),
      ('fn_create_po',                 'p_brine_pct_offered',     'select fn_create_po(gen_random_uuid(), null, null, null, p_brine_pct_offered => %s)'),
      ('fn_create_po',                 'p_brine_cost_thb',        'select fn_create_po(gen_random_uuid(), null, null, null, p_brine_cost_thb => %s)'),
      ('fn_create_transport_run',      'p_run_cost_thb',          'select fn_create_transport_run(gen_random_uuid(), null, null, p_run_cost_thb => %s)'),
      ('fn_dispatch_transport_line',   'p_dispatched_weight_kg',  'select fn_dispatch_transport_line(gen_random_uuid(), null, null, null, null, null, %s)'),
      ('fn_record_lot_receipt',        'p_received_weight_kg',    'select fn_record_lot_receipt(gen_random_uuid(), null, null, %s)'),
      ('fn_record_lot_receipt',        'p_post_drain_weight_kg',  'select fn_record_lot_receipt(gen_random_uuid(), null, null, null, %s)'),
      ('fn_record_opening_balance',    'p_qty',                   'select fn_record_opening_balance(gen_random_uuid(), null, null, %s, null)'),
      ('fn_record_owner_expense',      'p_amount_thb',            'select fn_record_owner_expense(gen_random_uuid(), null, null, %s, null)'),
      ('fn_reverse_ledger_entry',      'p_replacement_qty_delta', 'select fn_reverse_ledger_entry(gen_random_uuid(), null, %s)'),
      ('fn_set_opening_cost',          'p_cost_thb_per_kg',       'select fn_set_opening_cost(null, %s)'),
      ('fn_set_packaging_full_stock',  'p_full_stock_qty',        'select fn_set_packaging_full_stock(gen_random_uuid(), null, null, %s)'),
      ('fn_set_product_price',         'p_price_thb',             'select fn_set_product_price(gen_random_uuid(), null, null, %s)'),
      ('fn_set_product_price',         'p_cost_thb',              'select fn_set_product_price(gen_random_uuid(), null, null, null, %s)'),
      ('fn_set_smoke_fee_override',    'p_amount_thb',            'select fn_set_smoke_fee_override(gen_random_uuid(), null, %s, null)'),
      ('fn_upsert_smoke_daily_log',    'p_smoked_weight_kg',      'select fn_upsert_smoke_daily_log(gen_random_uuid(), null, null, null, p_smoked_weight_kg => %s)'),
      ('fn_upsert_smoke_daily_log',    'p_brine_used_kg',         'select fn_upsert_smoke_daily_log(gen_random_uuid(), null, null, null, p_brine_used_kg => %s)'),
      ('fn_upsert_smoke_daily_log',    'p_post_freeze_weight_kg', 'select fn_upsert_smoke_daily_log(gen_random_uuid(), null, null, null, p_post_freeze_weight_kg => %s)')
    ) as t(fn, param, call)
  loop
    v_seen := v_seen || r.fn;

    -- NS-03: refused, and the message names this input.
    v_err := null;
    begin
      execute format(r.call, '1.005');
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like format('TOO_MANY_DECIMALS: %s is 1.005 %%', r.param),
      format('NS-03: %s(%s => 1.005) got [%s]', r.fn, r.param, coalesce(v_err, 'no error at all'));

    -- NS-04: a legal value gets past the guard. With no session, the preamble refuses next.
    v_err := null;
    begin
      execute format(r.call, '1.500');
    exception when others then v_err := sqlerrm;
    end;
    assert coalesce(v_err, '') not like 'TOO_MANY_DECIMALS%',
      format('NS-04: %s(%s => 1.500) got [%s]', r.fn, r.param, v_err);
  end loop;

  --------------------------------------------------------------------------------- NS-10
  -- A list, not a pattern, and a closed one. Every fn_* taking a numeric input is guarded
  -- above, already refuses under its own name, or is excluded by the PLAN. A writer added later
  -- with no guard lands in none of the three and fails here, naming itself.
  select string_agg(p.proname, ', ' order by p.proname), count(*)
    into v_bad, v_n
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prokind = 'f'
     and p.proname like 'fn\_%'
     and (   'numeric'::regtype::oid   = any (p.proargtypes::oid[])
          or 'numeric[]'::regtype::oid = any (p.proargtypes::oid[]))
     and p.proname <> all (v_seen || array[
           -- already refuse a third decimal under their own names
           'fn_record_thaw', 'fn_record_waste', 'fn_record_lot_bags',
           -- excluded, PLAN § Excluded
           'fn_post_ledger', 'fn_check_variance', 'fn_set_config',
           -- the guard itself
           'fn_require_two_decimals']);
  assert v_n = 0,
    format('NS-10: %s fn_* take a numeric input and are in no list here: %s — call fn_require_two_decimals, or add it to a list with the reason',
           v_n, v_bad);

  raise exception 'NUMERIC_SCALE_TEST_PASSED';   -- the only clean way back out
end $$;
