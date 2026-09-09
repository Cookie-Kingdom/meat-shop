-- Card ^ref-18 — the schema this card claims, asserted rather than read once.
--
-- suppliers, purchase_orders, po_deliveries and lots were all created in
-- ...0003_purchasing_production.sql, so the card is the fourth stale-in-Backlog one of the
-- same shape as ^ref-04, ^ref-10 and ^ref-13. Turning the reading into a test is what
-- ^ref-10's T0 did and for the same reason: a later migration that drops a unit suffix or
-- loosens D01's unique FK fails the suite instead of passing review.
--
-- Covers TC-01 ... TC-04 from TDD-purchasing.md.
--
-- Run:  psql "$DATABASE_URL" -f supabase/tests/purchasing_schema_test.sql

do $$
declare
  v_n   bigint;
  v_txt text;
begin
  --------------------------------------------------------------------------------- TC-01
  -- The four tables and the columns the ER names.
  select count(*) into v_n
    from information_schema.tables
   where table_schema = 'public'
     and table_name in ('suppliers', 'purchase_orders', 'po_deliveries', 'lots');
  assert v_n = 4, format('TC-01: %s of the 4 purchasing tables exist', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'purchase_orders'
     and column_name in ('po_number', 'supplier_id', 'event_date', 'ordered_weight_kg',
                         'unit_price_thb_per_kg', 'brine_pct_offered', 'brine_cost_thb',
                         'created_by', 'created_at');
  assert v_n = 9, format('TC-01: purchase_orders is missing columns (%s of 9)', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'po_deliveries'
     and column_name in ('po_id', 'seq', 'event_date', 'foodiva_sent_weight_kg');
  assert v_n = 4, format('TC-01: po_deliveries is missing columns (%s of 4)', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'lots'
     and column_name in ('lot_code', 'po_id', 'po_delivery_id', 'foodiva_sent_weight_kg',
                         'chef_house_location_id', 'state', 'event_date', 'created_at');
  assert v_n = 8, format('TC-01: lots is missing columns (%s of 8)', v_n);

  -- D01: one dispatch round is one lot. NOT NULL stops a lot floating free of a round;
  -- UNIQUE stops one round growing a second lot. Both halves, or the rule is half enforced.
  select is_nullable into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'lots' and column_name = 'po_delivery_id';
  assert v_txt = 'NO', 'TC-01: lots.po_delivery_id is nullable — a lot with no round (D01)';

  select count(*) into v_n
    from pg_index i
    join pg_class c on c.oid = i.indrelid
    join pg_attribute a on a.attrelid = c.oid and a.attnum = any (i.indkey)
   where c.relname = 'lots' and i.indisunique and i.indnatts = 1
     and a.attname = 'po_delivery_id';
  assert v_n = 1, 'TC-01: lots.po_delivery_id is not uniquely indexed — one round, two lots (D01)';

  --------------------------------------------------------------------------------- TC-02
  -- Every quantity column names its unit (CLAUDE.md; ADR-008). The test is that a unit
  -- token appears as a whole underscore-separated segment, not that the name ends in one:
  -- `unit_price_thb_per_kg` carries two and `brine_pct_offered` carries its unit in the
  -- middle. Renaming an applied column so a regex can anchor is a migration written to
  -- satisfy a test. A genuinely unitless numeric — `total`, `amount`, `weight` — has no
  -- token at all and fails here, which is the column this assert exists to catch.
  select string_agg(table_name || '.' || column_name, ', ') into v_txt
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('suppliers', 'purchase_orders', 'po_deliveries', 'lots')
     and data_type = 'numeric'
     and not (string_to_array(column_name, '_')
              && array['kg','thb','pct','g','tubes','packs','qty']);
  assert v_txt is null, format('TC-02: numeric columns with no unit in the name: %s', v_txt);

  --------------------------------------------------------------------------------- TC-03
  -- ADR-007 says every operational table carries business_date, event_at and created_at.
  -- One table in the applied schema does. Every source table — this card's four included —
  -- carries event_date + created_at, because a dispatch round belongs to no shift and is
  -- closed by nobody. The ADR's scope is corrected in the same change (Finding 2); this is
  -- the assert that stops the correction drifting back, and it fails the day a second table
  -- carries either column, which is the day somebody re-reads ADR-007 on purpose.
  select coalesce(string_agg(distinct table_name, ', '), '(none)') into v_txt
    from information_schema.columns
   where table_schema = 'public' and column_name in ('business_date', 'event_at');
  assert v_txt = 'stock_ledger',
    format('TC-03: business_date/event_at are on [%s], not on stock_ledger alone — re-read ADR-007', v_txt);

  --------------------------------------------------------------------------------- TC-04
  -- Migration ...0008. po_number and seq are both generated inside their function, so
  -- neither natural unique key can carry a retry the way the config tables' dated keys do
  -- (Finding 3). Without these two columns a dropped connection on OW 01 turns one 30 kg
  -- dispatch into two, and every lot, freight share and yield figure downstream inherits it.
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public'
     and (table_name, column_name) in
         (('purchase_orders', 'idempotency_key'), ('po_deliveries', 'idempotency_key'))
     and data_type = 'uuid';
  assert v_n = 2, format('TC-04: %s of 2 idempotency_key uuid columns exist', v_n);

  select count(*) into v_n
    from pg_index i
    join pg_class c on c.oid = i.indrelid
    join pg_attribute a on a.attrelid = c.oid and a.attnum = any (i.indkey)
   where c.relname in ('purchase_orders', 'po_deliveries')
     and i.indisunique and i.indnatts = 1 and a.attname = 'idempotency_key';
  assert v_n = 2, format('TC-04: %s of 2 idempotency_key unique indexes exist', v_n);

  raise exception 'PURCHASING_SCHEMA_TEST_PASSED';   -- the only clean way back out
end $$;
