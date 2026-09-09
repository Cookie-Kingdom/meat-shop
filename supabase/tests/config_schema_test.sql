-- Card ^ref-10 acceptance, as an assertion rather than a one-time sweep.
--
-- ^ref-10 was moved to Done on evidence: all six tables exist, the four rate-bearing ones
-- are dated, and no mutable rate column exists anywhere. A verification protects nothing —
-- the next migration to add a `current_value` column or drop an `effective_from` would pass
-- review. This file is the same assertion, run on every apply.
--
-- The last block is the odd one: it asserts that packaging_full_stock's unique key is still
-- BROKEN. `(packaging_item_id, location_id, effective_from)` with a nullable location_id
-- stores two GLOBAL rows for one item on one date, because Postgres treats NULLs as
-- distinct — config_settings closes the same hole with a coalesce inside its index.
-- fn_set_packaging_full_stock guards it in application code instead. The day someone fixes
-- the index, this assert fails and points at that guard as dead code, rather than leaving it
-- there forever with nobody knowing whether it is still load-bearing.
--
-- Run:  psql "$DATABASE_URL" -f supabase/tests/config_schema_test.sql

do $$
declare
  v_bad text;
  v_n   bigint;
  t     text;
begin
  ------------------------------------------------------------------ the six tables exist
  select string_agg(x, ', '), count(*) into v_bad, v_n
    from unnest(array['smoke_fee_tiers','config_settings','products','product_prices',
                      'packaging_items','packaging_full_stock']) x
   where to_regclass('public.' || x) is null;
  assert v_n = 0, format('^ref-10: %s config table(s) missing: %s', v_n, v_bad);

  ------------------------------------------- the four rate-bearing ones carry three clocks
  -- effective_from is the resolution key (R12); created_by and created_at are who and when.
  -- products and packaging_items are catalogues and carry no rate, so nothing to date.
  foreach t in array array['smoke_fee_tiers','config_settings','product_prices',
                           'packaging_full_stock']
  loop
    select string_agg(c, ', '), count(*) into v_bad, v_n
      from unnest(array['effective_from','created_by','created_at']) c
     where not exists (select 1 from information_schema.columns
                        where table_schema = 'public' and table_name = t
                          and column_name = c);
    assert v_n = 0, format('ADR-006: %s is missing %s', t, v_bad);

    -- ...and a unique key that includes it, or two rows compete for one date.
    select count(*) into v_n
      from pg_index i
      join pg_class ic on ic.oid = i.indexrelid
     where i.indrelid = to_regclass('public.' || t)
       and i.indisunique
       and pg_get_indexdef(i.indexrelid) like '%effective_from%';
    assert v_n >= 1, format('ADR-006: %s has no unique key including effective_from', t);
  end loop;

  ------------------------------------------------- no mutable rate column on any BASE TABLE
  -- ADR-006's whole point. An effective_to closes off the previous row, which means an
  -- UPDATE on every change; a current_* column is a second place that can disagree about
  -- the current value. Either one silently rewrites a closed period (BR23).
  --
  -- BASE TABLES ONLY, narrowed by ^ref-12. It read information_schema.columns unfiltered,
  -- so it also swept views — and v_config_history's `is_current` is the exact opposite of
  -- what this assert protects against: a flag COMPUTED per read from effective_from, in the
  -- same order fn_config_value resolves in. It cannot go stale and it stores nothing. The
  -- failure mode named above needs somewhere to write a wrong value to, which a view has
  -- not got. Every stored column the original sweep covered is still covered.
  select string_agg(format('%s.%s', c.table_name, c.column_name), ', '), count(*)
    into v_bad, v_n
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name
   where c.table_schema = 'public'
     and t.table_type = 'BASE TABLE'
     and (c.column_name like 'effective_to%'
       or c.column_name like 'current!_%' escape '!'
       or c.column_name like '%!_current' escape '!'
       or c.column_name like 'is!_current%' escape '!');
  assert v_n = 0, format('ADR-006: %s mutable-rate column(s): %s', v_n, v_bad);

  ------------------------------------------------ the hole fn_set_packaging_full_stock guards
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'packaging_full_stock'
     and column_name = 'location_id' and is_nullable = 'YES';
  assert v_n = 1,
    'packaging_full_stock.location_id is no longer nullable — fn_set_packaging_full_stock''s '
    'global-row guard may now be dead code (T6)';

  select count(*) into v_n
    from pg_index i
   where i.indrelid = to_regclass('public.packaging_full_stock')
     and i.indisunique
     and pg_get_indexdef(i.indexrelid) ilike '%location_id%'
     and pg_get_indexdef(i.indexrelid) ilike '%coalesce%';
  assert v_n = 0,
    'packaging_full_stock''s unique key now coalesces location_id — the database refuses a '
    'second global row on its own, so fn_set_packaging_full_stock''s guard is dead code (T6)';

  raise exception 'CONFIG_SCHEMA_TEST_PASSED';   -- the only clean way back out
end $$;
