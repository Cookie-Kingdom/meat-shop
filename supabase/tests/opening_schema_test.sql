-- Schema-shaped failure cases for card ^ref-62 — migrations ...0011 and ...0012.
--
-- Covers TC-01, TC-03 ... TC-09 from TDD-opening-balance.md. TC-02 is the one property in
-- that table SQL cannot see — whether ...0011 is ALONE in its file — and it moved to
-- migrations_apply_test.sh, which has the file. Everything from TC-10 on needs sessions and
-- lives in opening_balance_test.sql and opening_close_test.sql.
--
-- Each assert is a way the opening path silently stops being enforceable:
--   * OPENING is not a movement type, so the close switch has nothing to predicate on
--   * an opening lot carries a phantom PO, which is the synthetic-round design ADR-021
--     rejected, reached through the back door
--   * D01 loosens while nobody is looking, because this card had to touch its NOT NULL
--   * a cost column loses its unit and money stops being readable as money
--   * a cost parameter appears on the counter's function and BR15 stops being true
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/opening_schema_test.sql

do $$
declare
  v_owner uuid := '66666666-6666-6666-6666-6666666666c1';
  v_sup   uuid;
  v_po    uuid;
  v_del   uuid;
  v_lot   uuid;
  v_txt   text;
  v_ok    boolean;
  v_err   text;
  v_n     bigint;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner);
  insert into profiles (id, display_name, role, is_active)
    values (v_owner, 'เจ้าของ', 'L1_OWNER', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  --------------------------------------------------------------------------------- TC-01
  -- The value exists. Everything else on this card predicates on it: the ledger trigger, the
  -- completeness left join, and fn_set_opening_cost's NOT_AN_OPENING_ROW.
  begin
    perform 'OPENING'::movement_type;
  exception when others then
    assert false, format('TC-01: OPENING is not a movement_type value (%s)', sqlerrm);
  end;

  -- And it was ADDED, not a replacement for one of the ten. An enum value renamed rather
  -- than added would pass the cast above and break every row already written. Asserted as
  -- "all ten originals are still there" rather than as a count: the count was 11 until
  -- ^ref-29's PRODUCTION (ADR-025) made it 12, and a pinned count was asserting the next
  -- card's enum rather than this card's question.
  select count(*) into v_n from pg_enum e
    join pg_type t on t.oid = e.enumtypid
   where t.typname = 'movement_type'
     and e.enumlabel in ('INTAKE', 'TRANSFER_OUT', 'TRANSFER_IN', 'THAW_OUT', 'THAW_IN',
                         'SALE', 'WASTE', 'GIVEAWAY', 'ADJUSTMENT', 'REVERSAL');
  assert v_n = 10, format('TC-01: %s of the ten original movement_type values survive', v_n);

  --------------------------------------------------------------------------------- TC-03
  -- opening_balance_close: the single-row idiom, and the key that makes a retry different
  -- from a second close.
  select string_agg(a.attname || ':' || format_type(a.atttypid, null), ', ' order by a.attnum)
    into v_txt
    from pg_attribute a
   where a.attrelid = 'public.opening_balance_close'::regclass
     and a.attnum > 0 and not a.attisdropped;
  assert v_txt like '%id:boolean%',
    format('TC-03: opening_balance_close.id is not the boolean single-row idiom (%s)', v_txt);
  assert v_txt like '%closed_idempotency_key:uuid%',
    format('TC-03: opening_balance_close has no closed_idempotency_key (%s)', v_txt);

  select count(*) into v_n from pg_constraint
   where conrelid = 'public.opening_balance_close'::regclass and contype = 'p';
  assert v_n = 1, 'TC-03: opening_balance_close has no primary key';

  -- opening_costs: keyed ON the ledger row, with a real FK to it. A cost table keyed on
  -- anything else is a second cost path competing with v_lot_cost (PLAN Finding 2).
  select count(*) into v_n from pg_constraint
   where conrelid = 'public.opening_costs'::regclass
     and contype = 'f'
     and confrelid = 'public.stock_ledger'::regclass;
  assert v_n = 1, 'TC-03: opening_costs.ledger_id does not reference stock_ledger';

  select count(*) into v_n from pg_constraint
   where conrelid = 'public.opening_costs'::regclass and contype = 'p';
  assert v_n = 1, 'TC-03: opening_costs has no primary key on ledger_id';

  --------------------------------------------------------------------------------- TC-04
  -- The idiom actually holds. `check (id)` permits one value and the primary key makes it
  -- unique, so a second close is a KEY VIOLATION — a thing the database refuses — rather
  -- than a business rule somebody has to remember to write in every future close path.
  insert into opening_balance_close (closed_by, closed_idempotency_key)
    values (v_owner, gen_random_uuid());
  v_ok := false; v_err := null;
  begin
    insert into opening_balance_close (closed_by, closed_idempotency_key)
      values (v_owner, gen_random_uuid());
  exception when unique_violation then
    v_ok := true;
  when others then
    v_err := sqlerrm;
  end;
  assert v_ok, format('TC-04: a second opening_balance_close row was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));
  delete from opening_balance_close;   -- the rest of this file needs the window open

  --------------------------------------------------------------------------------- TC-05
  -- Money and weight name their unit. A unitless numeric on a new table is a bug by
  -- CLAUDE.md's rule, and this is the sweep that says so before the column has callers.
  select string_agg(c.relname || '.' || a.attname, ', '), count(*)
    into v_txt, v_n
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('opening_costs', 'opening_balance_close')
     and a.attnum > 0 and not a.attisdropped
     and format_type(a.atttypid, null) like 'numeric%'
     and a.attname !~ '_(kg|thb|tubes|packs|qty)$'
     and a.attname !~ '_thb_per_kg$';
  assert v_n = 0, format('TC-05: %s unitless numeric column(s): %s', v_n, v_txt);

  select count(*) into v_n from pg_attribute
   where attrelid = 'public.opening_costs'::regclass
     and attname = 'cost_thb_per_kg' and attnum > 0;
  assert v_n = 1, 'TC-05: opening_costs has no cost_thb_per_kg';

  --------------------------------------------------------------------------------- TC-06
  -- An opening lot is legal with no purchasing history at all, and a lot with neither a
  -- round nor the opening flag is not. FOUR columns had to become nullable for the first
  -- half (PLAN Finding 7 named one); lots_round_or_opening is what stops the second.
  insert into lots (lot_code, is_opening, state, event_date)
    values ('OPEN-TC06', true, 'LOT_CLOSED', date '2026-08-01')
    returning id into v_lot;
  assert v_lot is not null, 'TC-06: an opening lot could not be created';

  v_ok := false; v_err := null;
  begin
    insert into lots (lot_code, is_opening, state, event_date)
      values ('ORPHAN-TC06', false, 'PO_CREATED', date '2026-08-01');
  exception when check_violation then
    v_ok := true;
  when others then
    v_err := sqlerrm;
  end;
  assert v_ok, format('TC-06: a lot with no round and no opening flag was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  -- And the other way round: an opening lot must not carry a phantom PO. The disjunction the
  -- plan drafted would have allowed this, which is the synthetic-round design ADR-021
  -- rejected, reachable again.
  insert into suppliers (name, is_active) values ('Foodiva', true) returning id into v_sup;
  insert into purchase_orders (po_number, supplier_id, event_date, ordered_weight_kg, created_by)
    values ('PO-TC06-001', v_sup, date '2026-08-01', 100.00, v_owner) returning id into v_po;
  insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg)
    values (v_po, 1, date '2026-08-01', 40.00) returning id into v_del;

  v_ok := false; v_err := null;
  begin
    insert into lots (lot_code, is_opening, state, event_date, po_id, po_delivery_id,
                      foodiva_sent_weight_kg, chef_house_location_id)
      values ('HYBRID-TC06', true, 'LOT_CLOSED', date '2026-08-01', v_po, v_del, 40.00, null);
  exception when check_violation then
    v_ok := true;
  when others then
    v_err := sqlerrm;
  end;
  assert v_ok, format('TC-06: an opening lot carrying a purchase order was accepted (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-07
  -- D01 SURVIVES. This card dropped po_delivery_id's NOT NULL and it must not have dropped
  -- its UNIQUE with it: D01 says one dispatch round is one lot, and that half is untouched.
  insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                    chef_house_location_id, event_date)
    select 'DUP-TC07-A', v_po, v_del, 40.00, l.id, date '2026-08-01'
      from locations l where l.kind = 'CHEF_HOUSE' limit 1;
  if not found then
    insert into locations (code, name_th, kind) values ('CHT', 'โรงรมทดสอบ', 'CHEF_HOUSE');
    insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                      chef_house_location_id, event_date)
      select 'DUP-TC07-A', v_po, v_del, 40.00, l.id, date '2026-08-01'
        from locations l where l.kind = 'CHEF_HOUSE' limit 1;
  end if;

  v_ok := false; v_err := null;
  begin
    insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                      chef_house_location_id, event_date)
      select 'DUP-TC07-B', v_po, v_del, 40.00, l.id, date '2026-08-01'
        from locations l where l.kind = 'CHEF_HOUSE' limit 1;
  exception when unique_violation then
    v_ok := true;
  when others then
    v_err := sqlerrm;
  end;
  assert v_ok, format('TC-07: two lots were accepted on one po_delivery_id, D01 is gone (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-08
  -- RLS is on for both. Migration ...0005 looped over pg_tables at its own migration time,
  -- so a table created afterwards inherits none of it — this is the failure that loop
  -- guarantees for every later card. Sweep 1a of rls_deny_all_test.sql is the same assert
  -- schema-wide; this one names the two tables so the message says which card broke.
  select string_agg(c.relname, ', '), count(*) into v_txt, v_n
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('opening_balance_close', 'opening_costs')
     and not c.relrowsecurity;
  assert v_n = 0, format('TC-08: RLS is off on %s', v_txt);

  --------------------------------------------------------------------------------- TC-09
  -- NO PRICE REACHES THE COUNTER, and this is the assert that keeps it true.
  --
  -- BR15 and R20: the chef house counter is an L3_CM_OPERATOR and never sees a price. The
  -- enforcement is not a branch inside the body — it is that THERE IS NO PARAMETER TO PASS.
  -- A cost parameter added later "for convenience, L1 only" would compile, pass every other
  -- test on this card, and put a price field on the one screen it must never be on.
  select pg_get_function_arguments(p.oid) into v_txt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_record_opening_balance';
  assert v_txt is not null, 'TC-09: fn_record_opening_balance does not exist';
  assert v_txt !~* '(cost|price|thb)',
    format('TC-09: fn_record_opening_balance takes a price argument (%s)', v_txt);

  raise exception 'OPENING_SCHEMA_TEST_PASSED';   -- the only clean way back out
end $$;
