-- Card ^ref-25 — the schema this card claims, asserted rather than read once.
--
-- All five production tables were created in ...0003_purchasing_production.sql, so the card's
-- acceptance line was already true of the baseline. As with ^ref-10's T0, ^ref-18's T1 and
-- ^ref-21's T2, the verification becomes a file rather than a one-time reading, so a later
-- migration that drops a unit suffix, an FK or a unique index fails the suite instead of
-- passing review. ^ref-25 moves to Done on THIS FILE passing, not on the DDL being read.
--
-- Covers TC-01 ... TC-07 and red->green slice 2 from TDD-lots.md. TC-08 (the log's packed
-- columns stay null after a real write) is Integration and lands with T6/T8 in production_test.sql;
-- TC-33 and TC-36 assert views that ^ref-26 and ^ref-27 have not built yet.
--
-- Run:  psql "$DATABASE_URL" -f supabase/tests/production_schema_test.sql

do $$
declare
  v_n      bigint;
  v_txt    text;
  v_ok     boolean;
  v_err    text;
  v_kg     numeric;
  v_day    date := date '2026-04-01';
  v_actor  uuid := gen_random_uuid();
  v_loc    uuid;
  v_sup    uuid;
  v_po     uuid;
  v_del    uuid;
  v_del2   uuid;
  v_lot    uuid;
  v_lot2   uuid;
  v_open   uuid;
  v_log    uuid;
  v_log2   uuid;
  v_group  uuid;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_actor);
  insert into profiles (id, display_name, role, is_active)
       values (v_actor, 'ผู้บันทึกการผลิต', 'L1_OWNER', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor)::text, true);

  insert into locations (code, name_th, kind) values ('CH25', 'โรงรมทดสอบ', 'CHEF_HOUSE')
    returning id into v_loc;
  insert into suppliers (name) values ('ผู้ขายทดสอบ') returning id into v_sup;
  insert into purchase_orders (po_number, supplier_id, event_date, ordered_weight_kg, created_by)
       values ('PO-PROD-1', v_sup, v_day, 100.00, v_actor) returning id into v_po;
  insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg)
       values (v_po, 1, v_day, 100.00) returning id into v_del;
  insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                    chef_house_location_id, event_date, state)
       values ('LOT-PROD-1', v_po, v_del, 100.00, v_loc, v_day, 'SMOKING')
    returning id into v_lot;

  --------------------------------------------------------------------------------- TC-01
  -- The five tables and the columns the ER names. `in (...)` and a count rather than an
  -- exact column list, so adding a column is not a failure and dropping one is.
  select count(*) into v_n
    from information_schema.tables
   where table_schema = 'public'
     and table_name in ('lot_receipts', 'smoke_daily_logs', 'smoke_daily_log_sources',
                        'smoke_date_groups', 'lot_bags');
  assert v_n = 5, format('TC-01: %s of the 5 production tables exist', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'lot_receipts'
     and column_name in ('lot_id', 'event_date', 'received_weight_kg', 'post_drain_weight_kg',
                         'variance_reason', 'recorded_by', 'created_at');
  assert v_n = 7, format('TC-01: lot_receipts is missing columns (%s of 7)', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'smoke_daily_logs'
     and column_name in ('lot_id', 'event_date', 'input_weight_kg', 'smoked_weight_kg',
                         'brine_used_kg', 'post_freeze_weight_kg', 'packed_weight_kg',
                         'bag_count', 'recorded_by', 'created_at');
  assert v_n = 10, format('TC-01: smoke_daily_logs is missing columns (%s of 10)', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'smoke_daily_log_sources'
     and column_name in ('smoke_daily_log_id', 'lot_id', 'input_weight_kg', 'created_at');
  assert v_n = 4, format('TC-01: smoke_daily_log_sources is missing columns (%s of 4)', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'smoke_date_groups'
     and column_name in ('lot_id', 'smoke_date', 'packed_weight_kg', 'bag_count', 'created_at');
  assert v_n = 5, format('TC-01: smoke_date_groups is missing columns (%s of 5)', v_n);

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'lot_bags'
     and column_name in ('smoke_date_group_id', 'seq', 'packed_weight_kg', 'created_at');
  assert v_n = 4, format('TC-01: lot_bags is missing columns (%s of 4)', v_n);

  -- D05 is this column, and it is the whole reason a daily log can name several source lots.
  -- Nullable, it would let a cross-lot smoking day lose track of where the meat came from,
  -- which is what ADR-017 forbids and what v_lot_pending_work (^ref-26) joins on.
  select is_nullable into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'smoke_daily_log_sources'
     and column_name = 'lot_id';
  assert v_txt = 'NO',
    'TC-01: smoke_daily_log_sources.lot_id is nullable — a source with no lot (D05/ADR-017)';

  -- Finding 2's natural key. lot_receipts carries no idempotency_key BECAUSE this is unique;
  -- lose the unique and the retry silently becomes a second receipt for one lot.
  select count(*) into v_n
    from pg_index i
    join pg_class c on c.oid = i.indrelid
    join pg_attribute a on a.attrelid = c.oid and a.attnum = any (i.indkey)
   where c.relname = 'lot_receipts'
     and i.indisunique and i.indnatts = 1 and a.attname = 'lot_id';
  assert v_n = 1, 'TC-01: lot_receipts.lot_id is no longer unique — R38 has nothing to ride on';

  --------------------------------------------------------------------------------- TC-02
  -- R6 and R7's unique keys, proved by a duplicate rather than by reading pg_index: the two
  -- upserts in ^ref-27 and ^ref-28 both depend on the conflict target actually firing.
  insert into smoke_daily_logs (lot_id, event_date, recorded_by)
       values (v_lot, v_day, v_actor) returning id into v_log;

  v_ok := false; v_err := null;
  begin
    insert into smoke_daily_logs (lot_id, event_date, recorded_by)
         values (v_lot, v_day, v_actor);
  exception when others then
    v_err := sqlerrm; v_ok := sqlstate = '23505';
  end;
  assert v_ok, format('TC-02: a second smoke_daily_log for one (lot_id, event_date) was accepted — R6 (%s)',
                      coalesce(v_err, 'no exception at all'));

  insert into smoke_date_groups (lot_id, smoke_date) values (v_lot, v_day)
    returning id into v_group;

  v_ok := false; v_err := null;
  begin
    insert into smoke_date_groups (lot_id, smoke_date) values (v_lot, v_day);
  exception when others then
    v_err := sqlerrm; v_ok := sqlstate = '23505';
  end;
  assert v_ok, format('TC-02: a second smoke_date_group for one (lot_id, smoke_date) was accepted — R7 (%s)',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-03
  -- Every quantity column names its unit. A numeric with no _kg or _thb is a bug by the
  -- project's own rule, and this sweep is what makes that rule survive a later migration.
  select string_agg(table_name || '.' || column_name, ', '), count(*) into v_txt, v_n
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('lot_receipts', 'smoke_daily_logs', 'smoke_daily_log_sources',
                        'smoke_date_groups', 'lot_bags')
     and data_type = 'numeric'
     and column_name not like '%\_kg'
     and column_name not like '%\_thb';
  assert v_n = 0, format('TC-03: unitless numeric column(s): %s', v_txt);

  -- BR21's sibling rule: a bag is a thing, not a weight. bag_count integer is what stops
  -- 3.5 bags being storable at all.
  select data_type into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'smoke_date_groups' and column_name = 'bag_count';
  assert v_txt = 'integer', format('TC-03: smoke_date_groups.bag_count is %s, not integer', v_txt);

  --------------------------------------------------------------------------------- TC-04
  -- BR18 IS AN ABSENCE, SO IT IS ASSERTED AS ONE. Bags carry no code and none is required:
  -- individual pack weights batch-insert into a smoke-date group and the group is the identity.
  -- A code column added later would make somebody start filling it in on a phone with wet hands.
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'lot_bags'
     and column_name in ('code', 'bag_code', 'barcode', 'label', 'tag');
  assert v_n = 0, 'TC-04: lot_bags grew a bag-code column — BR18 says bags are not coded';

  --------------------------------------------------------------------------------- TC-05
  -- Migration ...0013's objects. Each one is a hole in R39, R6a or R8 if it goes missing.
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public'
     and (table_name, column_name) in
         (('smoke_daily_logs', 'idempotency_key'), ('lot_bags', 'idempotency_key'))
     and data_type = 'uuid';
  assert v_n = 2, format('TC-05: %s of 2 idempotency_key uuid columns exist', v_n);

  -- One column for the log (a replay must not become the 18:00 correction) ...
  select count(*) into v_n
    from pg_index i
    join pg_class c on c.oid = i.indrelid
    join pg_attribute a on a.attrelid = c.oid and a.attnum = any (i.indkey)
   where c.relname = 'smoke_daily_logs'
     and i.indisunique and i.indnatts = 1 and a.attname = 'idempotency_key';
  assert v_n = 1, 'TC-05: smoke_daily_logs.idempotency_key has no unique index (R39/Finding 3)';

  -- ... and a PAIR for the bags, because the key is per batch and a batch is 60 rows.
  select count(*) into v_n
    from pg_constraint
   where conrelid = 'public.lot_bags'::regclass
     and contype = 'u' and conname = 'lot_bags_batch_key'
     and array_length(conkey, 1) = 2;
  assert v_n = 1,
    'TC-05: lot_bags_batch_key is missing or is not the (idempotency_key, seq) pair (Finding 2)';

  select count(*) into v_n
    from pg_constraint
   where conrelid = 'public.lot_receipts'::regclass
     and contype = 'c' and conname = 'lot_receipts_post_drain_le_received';
  assert v_n = 1, 'TC-05: lot_receipts_post_drain_le_received is gone (Finding 6)';

  select count(*) into v_n
    from pg_trigger
   where not tgisinternal
     and tgname in ('trg_rollup_smoke_log_input', 'trg_rollup_smoke_group_packed');
  assert v_n = 2, format('TC-05: %s of the 2 roll-up triggers exist — a typed total with no '
                         'trigger diverges from its rows the first time a write half-fails', v_n);

  select count(*) into v_n
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
   where not t.tgisinternal
     and t.tgfoid = 'fn_guard_lot_closed()'::regprocedure
     and c.relname in ('lot_receipts', 'smoke_daily_logs', 'smoke_daily_log_sources',
                       'smoke_date_groups', 'lot_bags');
  assert v_n = 5,
    format('TC-05: fn_guard_lot_closed is on %s of the 5 child tables — R8 has a hole', v_n);

  -- Finding 7's two comments are load-bearing: they are the only thing standing between the
  -- next reader and a third copy of the output weight.
  select col_description('public.smoke_daily_logs'::regclass, ordinal_position) into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'smoke_daily_logs'
     and column_name = 'packed_weight_kg';
  assert v_txt like '%smoke_date_groups%',
    'TC-05: smoke_daily_logs.packed_weight_kg lost the comment naming the group as the total';

  --------------------------------------------------------------------------------- TC-06
  -- Draining removes brine and water; it cannot add meat. 99 against a received 98 is a typo
  -- that would otherwise become the cross-check figure the receipt exists to provide.
  v_ok := false; v_err := null;
  begin
    insert into lot_receipts (lot_id, event_date, received_weight_kg, post_drain_weight_kg,
                              recorded_by)
         values (v_lot, v_day, 98.00, 99.00, v_actor);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%lot_receipts_post_drain_le_received%';
  end;
  assert v_ok, format('TC-06: post-drain 99.00 was stored against a received 98.00 (%s)',
                      coalesce(v_err, 'no exception at all'));

  -- The same row inside the bound is ordinary, and a null post-drain is CM 02 before CM 03.
  insert into lot_receipts (lot_id, event_date, received_weight_kg, recorded_by)
       values (v_lot, v_day, 98.00, v_actor);

  --------------------------------------------------------------------------------- TC-07
  -- The group's totals follow its bags in BOTH directions. A roll-up that only handles INSERT
  -- is the divergence Finding 7 describes, arriving one delete later.
  insert into lot_bags (smoke_date_group_id, seq, packed_weight_kg, idempotency_key)
       values (v_group, 1, 0.50, gen_random_uuid()),
              (v_group, 2, 0.52, gen_random_uuid()),
              (v_group, 3, 0.48, gen_random_uuid());

  select packed_weight_kg, bag_count into v_kg, v_n from smoke_date_groups where id = v_group;
  assert v_kg = 1.50 and v_n = 3,
    format('TC-07: after 3 bags the group reads %s kg / %s bags, not 1.50 / 3', v_kg, v_n);

  delete from lot_bags where smoke_date_group_id = v_group and seq = 3;

  select packed_weight_kg, bag_count into v_kg, v_n from smoke_date_groups where id = v_group;
  assert v_kg = 1.02 and v_n = 2,
    format('TC-07: after deleting one bag the group reads %s kg / %s bags, not 1.02 / 2', v_kg, v_n);

  ------------------------------------------------------------------------------- slice 2
  -- R8's lot half. Before ...0013 this write succeeded and "closing locks the lot" was a word
  -- in an enum.
  update lots set state = 'LOT_CLOSED' where id = v_lot;

  v_ok := false; v_err := null;
  begin
    insert into smoke_date_groups (lot_id, smoke_date) values (v_lot, v_day + 1);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_CLOSED:%';
  end;
  assert v_ok, format('slice 2: a child row was written against a LOT_CLOSED lot (%s)',
                      coalesce(v_err, 'no exception at all'));

  -- An APPROVED unlock inside its window admits the write (R8), ...
  insert into unlock_requests (target_type, target_id, requested_by, reason, status, expires_at)
       values ('LOT', v_lot, v_actor, 'แก้ไขน้ำหนักที่บันทึกผิด', 'APPROVED', now() + interval '2 hours');
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lot, v_day + 1);

  -- ... and the same row once its window has passed does not. R42 is evaluated HERE, at write
  -- time: a sweep that has not run yet would leave this row admitting writes it should refuse.
  update unlock_requests set expires_at = now() - interval '1 minute' where target_id = v_lot;

  v_ok := false; v_err := null;
  begin
    insert into smoke_date_groups (lot_id, smoke_date) values (v_lot, v_day + 2);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_CLOSED:%';
  end;
  assert v_ok, format('slice 2: an EXPIRED unlock still admitted the write — R42 is not being '
                      'read at write time (%s)', coalesce(v_err, 'no exception at all'));

  -- AND THE OPENING LOT IS EXEMPT. ^ref-62's fn_record_opening_balance creates its lot at
  -- LOT_CLOSED on purpose and then writes smoke_date_groups rows for it — 40 kg in one freezer,
  -- 15 kg in another. A guard reading lot_state alone breaks a merged, green function. Opening
  -- lots are gated by opening_balance_close instead, which is one-way and stricter.
  insert into lots (lot_code, is_opening, state, event_date)
       values ('LOT-OPEN-25', true, 'LOT_CLOSED', v_day) returning id into v_open;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_open, v_day);
  select count(*) into v_n from smoke_date_groups where lot_id = v_open;
  assert v_n = 1, 'slice 2: the lot-closed guard refused an OPENING lot — see ...0013 section 4';

  -- The source side of the join is guarded too, and this is the half a guard written from the
  -- parent alone would miss: consuming from a closed lot after its yield was computed is the
  -- same corruption arriving from the other direction (D05). The PARENT here is OPEN, so only
  -- the source lot can be what refuses the row.
  insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg)
       values (v_po, 2, v_day, 50.00) returning id into v_del2;
  insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                    chef_house_location_id, event_date, state)
       values ('LOT-PROD-2', v_po, v_del2, 50.00, v_loc, v_day, 'SMOKING')
    returning id into v_lot2;
  insert into smoke_daily_logs (lot_id, event_date, recorded_by)
       values (v_lot2, v_day, v_actor) returning id into v_log2;

  v_ok := false; v_err := null;
  begin
    insert into smoke_daily_log_sources (smoke_daily_log_id, lot_id, input_weight_kg)
         values (v_log2, v_lot, 10.00);      -- open parent, closed source
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_CLOSED:%';
  end;
  assert v_ok, format('slice 2: a source row named a LOT_CLOSED lot as its input (%s)',
                      coalesce(v_err, 'no exception at all'));

  -- And the same row from an open source lot is ordinary, so the guard is not simply refusing
  -- everything — the failure mode a one-sided assertion cannot tell apart.
  insert into smoke_daily_log_sources (smoke_daily_log_id, lot_id, input_weight_kg)
       values (v_log2, v_lot2, 10.00);
  select input_weight_kg into v_kg from smoke_daily_logs where id = v_log2;
  assert v_kg = 10.00,
    format('slice 2: R6a roll-up reads %s after one 10.00 kg source, not 10.00', v_kg);

  raise exception 'PRODUCTION_SCHEMA_TEST_PASSED';   -- the only clean way back out
end $$;
