-- Card ^ref-42: the schema claimed by migrations ...0017 and ...0018, asserted by name
-- rather than read once.
--
-- Contract assumed from an unmerged lane: none. Lane D's new physical_counts columns stay
-- nullable, so TC-11's insert names none of them. The thaw_records insert in TC-07b names
-- neither lane B's idempotency_key nor anything else it adds, because R8's BEFORE trigger
-- refuses the row before any NOT NULL check is reached.
--
-- Covers TC-01 ... TC-11 of TDD-sales.md, plus two unnumbered checks:
--   * TC-07b: each of the six guarded tables actually refuses a row against a CLOSED day.
--     Finding the trigger in pg_trigger (TC-07) and seeing it fire are different claims.
--   * the deny-all posture on sales_lines and waste_records is intact.
-- TC-12 ... TC-15 test fn_require_branch_or_owner, which is lane B's (PLAN-sales.md B17).
--
-- Each assert catches a way the schema fails silently:
--   * a unique on the batch key ALONE, which refuses line 2 of every five-line save
--   * a guard written as status <> 'OPEN', which makes the unlock path dead code
--   * a guard that coalesces a null parent, which refuses every ad-hoc physical count
--   * a guard that ignores R42's expiry, which admits writes on a stale APPROVED unlock
--   * 12.5 boxes stored and priced, i.e. half a box that was never packed (BR21)
--   * an unseeded products table, which gives every sale in the system PRODUCT_UNKNOWN
--
-- Errors are captured into v_err and asserted after the block, never inside a `when others`
-- handler (see branch_daily_test.sql's header for why).
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/sales_schema_test.sql

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_adm    uuid := gen_random_uuid();
  v_day    date := date '2026-05-04';
  v_bra    uuid;
  v_lot    uuid;
  v_grp    uuid;
  v_rep    uuid;
  v_box    uuid;
  v_rice   uuid;
  v_line   uuid;
  v_unlock uuid;
  v_n      bigint;
  v_txt    text;
  v_err    text;
  v_ok     boolean;
  v_tbl    text;
begin
  --------------------------------------------------------------------------------- TC-01
  -- ...0017. The statement count for that file is migrations_apply_test.sh's to assert
  -- (^ref-62 TC-02), because the database holds the enum, not the file.
  select count(*) into v_n
    from pg_enum e join pg_type t on t.oid = e.enumtypid
   where t.typname = 'item_type' and e.enumlabel = 'BEVERAGE';
  assert v_n = 1, 'TC-01: item_type has no BEVERAGE value — WATER_BOTTLE has nowhere to live (Finding 7)';

  --------------------------------------------------------------------------------- TC-02
  -- The sales batch key. The unique constraint is on the PAIR. One on the key alone refuses
  -- line 2 of a five-line save.
  select data_type into v_txt from information_schema.columns
   where table_schema = 'public' and table_name = 'sales_lines' and column_name = 'idempotency_key';
  assert v_txt = 'uuid', format('TC-02: sales_lines.idempotency_key is [%s], expected uuid', v_txt);

  select data_type into v_txt from information_schema.columns
   where table_schema = 'public' and table_name = 'sales_lines' and column_name = 'seq';
  assert v_txt = 'integer', format('TC-02: sales_lines.seq is [%s], expected integer', v_txt);

  select count(*) into v_n
    from pg_constraint c
   where c.conrelid = 'public.sales_lines'::regclass and c.contype = 'u'
     and (select array_agg(a.attname::text order by a.attname)
            from pg_attribute a
           where a.attrelid = c.conrelid and a.attnum = any (c.conkey))
         = array['idempotency_key', 'seq'];
  assert v_n = 1, 'TC-02: no unique constraint on sales_lines (idempotency_key, seq) — R39''s batch shape';

  select count(*) into v_n
    from pg_index i
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
   where i.indrelid = 'public.sales_lines'::regclass
     and i.indisunique and i.indnatts = 1 and a.attname = 'idempotency_key';
  assert v_n = 0, 'TC-02: sales_lines.idempotency_key is unique ON ITS OWN — line 2 of every batch would be refused';

  --------------------------------------------------------------------------------- TC-03
  select data_type into v_txt from information_schema.columns
   where table_schema = 'public' and table_name = 'waste_records' and column_name = 'idempotency_key';
  assert v_txt = 'uuid', format('TC-03: waste_records.idempotency_key is [%s], expected uuid', v_txt);

  select count(*) into v_n
    from pg_index i
    join pg_class ic on ic.oid = i.indexrelid
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
   where i.indrelid = 'public.waste_records'::regclass
     and ic.relname = 'waste_records_idempotency_key'
     and i.indisunique and i.indnatts = 1 and a.attname = 'idempotency_key';
  assert v_n = 1, 'TC-03: waste_records_idempotency_key is missing, not unique, or not on the key alone';

  --------------------------------------------------------------------------------- TC-04
  select data_type into v_txt from information_schema.columns
   where table_schema = 'public' and table_name = 'daily_reports' and column_name = 'close_idempotency_key';
  assert v_txt = 'uuid', format('TC-04: daily_reports.close_idempotency_key is [%s], expected uuid', v_txt);

  select count(*) into v_n
    from pg_index i
    join pg_class ic on ic.oid = i.indexrelid
   where i.indrelid = 'public.daily_reports'::regclass
     and ic.relname = 'daily_reports_close_idempotency_key'
     and i.indisunique and i.indnatts = 1;
  assert v_n = 1, 'TC-04: daily_reports_close_idempotency_key is missing or not unique — a close retry reads REPORT_ALREADY_CLOSED';

  -- ...0004's lookup index and ...0009's one-open index, untouched.
  select count(*) into v_n
    from pg_class ic join pg_index i on i.indexrelid = ic.oid
   where i.indrelid = 'public.daily_reports'::regclass
     and ic.relname in ('daily_reports_open', 'daily_reports_one_open');
  assert v_n = 2, format('TC-04: %s of daily_reports_open / daily_reports_one_open survive', v_n);

  --------------------------------------------------------------------------------- TC-05
  select is_nullable into v_txt from information_schema.columns
   where table_schema = 'public' and table_name = 'sales_lines' and column_name = 'created_by';
  assert v_txt = 'NO', format('TC-05: sales_lines.created_by is_nullable = [%s], expected NO (R32)', v_txt);

  select count(*) into v_n
    from pg_constraint c
   where c.conrelid = 'public.sales_lines'::regclass and c.contype = 'f'
     and c.confrelid = 'public.profiles'::regclass
     and c.conkey = array[(select attnum from pg_attribute
                             where attrelid = 'public.sales_lines'::regclass
                               and attname = 'created_by')];
  assert v_n = 1, 'TC-05: sales_lines.created_by does not reference profiles(id)';

  --------------------------------------------------------------------------------- TC-06
  select data_type || ':' || numeric_precision || ',' || numeric_scale || ':' || is_nullable
    into v_txt
    from information_schema.columns
   where table_schema = 'public' and table_name = 'sales_lines' and column_name = 'pack_weight_kg';
  assert v_txt = 'numeric:12,2:YES',
    format('TC-06: sales_lines.pack_weight_kg is [%s], expected a nullable numeric(12,2)', v_txt);

  v_txt := col_description('public.sales_lines'::regclass,
                           (select attnum from pg_attribute
                             where attrelid = 'public.sales_lines'::regclass
                               and attname = 'pack_weight_kg'));
  assert v_txt like '%R29%' and v_txt like '%never re-reads config%',
    format('TC-06: pack_weight_kg''s comment does not name R29 and the no-config rule: [%s]', v_txt);

  --------------------------------------------------------------------------------- TC-07
  -- Six, not five. physical_counts is the one a "tables with daily_report_id NOT NULL" loop
  -- would miss.
  select count(*), string_agg(c.relname, ',' order by c.relname) into v_n, v_txt
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where t.tgname = 'trg_guard_report_closed' and not t.tgisinternal;
  assert v_n = 6 and v_txt = 'branch_expenses,physical_counts,rice_records,sales_lines,thaw_records,waste_records',
    format('TC-07: trg_guard_report_closed is on %s table(s): [%s]', v_n, v_txt);

  --------------------------------------------------------------------------------- TC-08
  select count(*) into v_n
    from products
   where (code, item_type::text, sale_unit, is_stock_tracked) in (
           ('MEAT_BOX',          'SMOKED_MEAT',  'box',    true),
           ('MEAT_ADDON_SEALED', 'SMOKED_MEAT',  'bag',    true),
           ('CHILLI_TUBE',       'CHILLI_PASTE', 'tube',   true),
           ('RICE_KG',           'COOKED_RICE',  'kg',     false),
           ('WATER_BOTTLE',      'BEVERAGE',     'bottle', false))
     and is_active
     and btrim(name_th) <> '';
  assert v_n = 5, format('TC-08: %s of the five seeded SKUs are present with the right type, unit and tracking', v_n);

  ------------------------------------------------------------------ grants and deny-all
  assert not has_function_privilege('authenticated', 'public.fn_guard_report_closed()', 'EXECUTE')
     and not has_function_privilege('anon', 'public.fn_guard_report_closed()', 'EXECUTE'),
    'a session role may execute fn_guard_report_closed — a trigger function is nobody''s endpoint';
  assert not has_table_privilege('authenticated', 'public.sales_lines', 'SELECT')
     and not has_table_privilege('authenticated', 'public.sales_lines', 'INSERT')
     and not has_table_privilege('authenticated', 'public.waste_records', 'SELECT')
     and not has_table_privilege('authenticated', 'public.waste_records', 'INSERT'),
    'authenticated reaches sales_lines or waste_records directly — the fn_* are not the only path (ADR-002)';

  v_txt := obj_description('public.fn_require_lot_for_meat()'::regprocedure, 'pg_proc');
  assert v_txt like '%BR21%' and v_txt like '%R21%',
    format('fn_require_lot_for_meat''s comment does not say it guards R21 and BR21: [%s]', v_txt);

  ------------------------------------------------------------------------------ fixtures
  insert into auth.users (id) values (v_owner), (v_adm);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',       'L1_OWNER',        true),
    (v_adm,   'แอดมินสาขาเอ', 'L2_BRANCH_ADMIN', true);
  insert into locations (code, name_th, kind, rice_model)
       values ('BRA42', 'สาขาเอ', 'BRANCH', 'EXTERNAL_COOKED') returning id into v_bra;
  insert into user_locations (profile_id, location_id) values (v_adm, v_bra);

  -- ^ref-62's opening-lot shape, inserted directly: it needs no PO chain and is exempt from
  -- the lot guard, so a smoke-date group can hang off it.
  insert into lots (lot_code, is_opening, state, event_date)
       values ('OPEN-42', true, 'LOT_CLOSED', v_day - 3) returning id into v_lot;
  insert into smoke_date_groups (lot_id, smoke_date) values (v_lot, v_day - 3) returning id into v_grp;

  insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
       values (v_bra, v_day, now(), v_adm) returning id into v_rep;

  select id into v_box  from products where code = 'MEAT_BOX';
  select id into v_rice from products where code = 'RICE_KG';

  --------------------------------------------------------------------------------- TC-09
  -- BR21 both ways. The trigger is the backstop; fn_record_sales raises the same name first.
  v_err := null;
  begin
    insert into sales_lines (daily_report_id, product_id, lot_id, smoke_date_group_id, qty,
                             unit_price_thb, created_by)
         values (v_rep, v_box, v_lot, v_grp, 12.5, 350.00, v_adm);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'QTY_NOT_WHOLE_UNITS%',
    format('TC-09: 12.5 boxes were accepted, got [%s]', coalesce(v_err, 'no error at all'));

  insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, created_by)
       values (v_rep, v_rice, 8.50, 40.00, v_adm);
  insert into sales_lines (daily_report_id, product_id, lot_id, smoke_date_group_id, qty,
                           unit_price_thb, created_by)
       values (v_rep, v_box, v_lot, v_grp, 12, 350.00, v_adm)
    returning id into v_line;

  v_err := null;
  begin
    insert into waste_records (daily_report_id, item_type, qty, reason, created_by)
         values (v_rep, 'CHILLI_PASTE', 1.5, 'หลอดแตก', v_adm);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'QTY_NOT_WHOLE_UNITS%',
    format('TC-09: 1.5 tubes of chilli were wasted, got [%s]', coalesce(v_err, 'no error at all'));

  -- Meat is wasted in kg and stays fractional.
  insert into waste_records (daily_report_id, item_type, lot_id, smoke_date_group_id, qty, reason, created_by)
       values (v_rep, 'SMOKED_MEAT', v_lot, v_grp, 0.35, 'เนื้อละลายเหลือปลายวัน', v_adm);

  --------------------------------------------------------------------------------- TC-10
  -- R8. CLOSED refuses an insert, an update and a delete.
  update daily_reports set status = 'CLOSED', closed_by = v_adm, closed_at = now() where id = v_rep;

  v_err := null;
  begin
    insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, created_by)
         values (v_rep, v_rice, 1.00, 40.00, v_adm);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_CLOSED%',
    format('TC-10: a sale was written against a CLOSED day, got [%s]', coalesce(v_err, 'no error at all'));
  assert v_err like '%' || v_day::text || '%',
    format('TC-10: REPORT_CLOSED does not name the day (%s): [%s]', v_day, v_err);

  v_err := null;
  begin
    update sales_lines set qty = 11 where id = v_line;
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_CLOSED%',
    format('TC-10: a sale on a CLOSED day was edited, got [%s]', coalesce(v_err, 'no error at all'));

  v_err := null;
  begin
    delete from sales_lines where id = v_line;
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_CLOSED%',
    format('TC-10: a sale on a CLOSED day was deleted, got [%s]', coalesce(v_err, 'no error at all'));

  -- An unlock aimed at the wrong target type does not open the day. target_type is part of
  -- the rule, not a formality.
  insert into unlock_requests (target_type, target_id, requested_by, reason, status,
                               decided_by, decided_at, expires_at)
       values ('LOT', v_rep, v_adm, 'แก้ยอดขายที่กรอกผิด', 'APPROVED', v_owner, now(), now() + interval '1 hour');
  v_err := null;
  begin
    insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, created_by)
         values (v_rep, v_rice, 1.00, 40.00, v_adm);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_CLOSED%',
    format('TC-10: a LOT-typed unlock opened a daily report, got [%s]', coalesce(v_err, 'no error at all'));

  -- An approved, unexpired DAILY_REPORT unlock admits the write (R8's "until an approved
  -- unlock_request exists").
  insert into unlock_requests (target_type, target_id, requested_by, reason, status,
                               decided_by, decided_at, expires_at)
       values ('DAILY_REPORT', v_rep, v_adm, 'แก้ยอดขายที่กรอกผิด', 'APPROVED', v_owner, now(), now() + interval '1 hour')
    returning id into v_unlock;
  insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, created_by)
       values (v_rep, v_rice, 1.00, 40.00, v_adm);

  -- R42: once it expires, the same write is refused. The check lives on this read, not in a
  -- sweep that may not have run.
  update unlock_requests set expires_at = now() - interval '1 minute' where id = v_unlock;
  v_err := null;
  begin
    insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, created_by)
         values (v_rep, v_rice, 1.00, 40.00, v_adm);
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_CLOSED%',
    format('TC-10: an EXPIRED unlock still admitted a write (R42), got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-07b
  -- Each of the six tables refuses against the CLOSED day. The inserts name only ...0004's
  -- columns. R8 fires BEFORE the NOT NULL checks, so this holds whatever lanes B and D add.
  foreach v_tbl in array array['thaw_records', 'waste_records', 'physical_counts',
                               'rice_records', 'branch_expenses'] loop
    v_err := null;
    begin
      if v_tbl = 'thaw_records' then
        insert into thaw_records (daily_report_id, lot_id, smoke_date_group_id, thawed_weight_kg, created_by)
             values (v_rep, v_lot, v_grp, 1.00, v_adm);
      elsif v_tbl = 'waste_records' then
        insert into waste_records (daily_report_id, item_type, lot_id, smoke_date_group_id, qty, reason, created_by)
             values (v_rep, 'SMOKED_MEAT', v_lot, v_grp, 0.10, 'เหลือปลายวัน', v_adm);
      elsif v_tbl = 'physical_counts' then
        insert into physical_counts (daily_report_id, location_id, event_date, item_type,
                                     counted_qty, system_qty, created_by)
             values (v_rep, v_bra, v_day, 'CHILLI_PASTE', 87, 88, v_adm);
      elsif v_tbl = 'rice_records' then
        insert into rice_records (daily_report_id, location_id, event_date, model, created_by)
             values (v_rep, v_bra, v_day, 'EXTERNAL_COOKED', v_adm);
      else
        insert into branch_expenses (daily_report_id, category, amount_thb, created_by)
             values (v_rep, 'น้ำแข็ง', 60.00, v_adm);
      end if;
    exception when others then v_err := sqlerrm;
    end;
    assert v_err like 'REPORT_CLOSED%',
      format('TC-07b: %s accepted a row against a CLOSED day, got [%s]', v_tbl, coalesce(v_err, 'no error at all'));
  end loop;

  -- UNLOCKED is writable. The predicate is = 'CLOSED', never <> 'OPEN' (Seam 4).
  update daily_reports set status = 'UNLOCKED' where id = v_rep;
  v_ok := false;
  begin
    insert into sales_lines (daily_report_id, product_id, qty, unit_price_thb, created_by)
         values (v_rep, v_rice, 1.00, 40.00, v_adm);
    v_ok := true;
  exception when others then v_err := sqlerrm;
  end;
  assert v_ok, format('TC-10: an UNLOCKED day refused a correction, got [%s] — the guard reads <> ''OPEN''', v_err);

  -- An UPDATE that moves a row OUT of a closed day is a write to that day (PLAN-sales.md B4).
  insert into daily_reports (location_id, report_date, shift_started_at, status, opened_by, closed_by, closed_at)
       values (v_bra, v_day - 1, now(), 'CLOSED', v_adm, v_adm, now())
    returning id into v_unlock;          -- reused as the closed day's id
  update daily_reports set status = 'UNLOCKED' where id = v_unlock;
  update sales_lines set daily_report_id = v_unlock where id = v_line;
  update daily_reports set status = 'CLOSED' where id = v_unlock;
  v_err := null;
  begin
    update sales_lines set daily_report_id = v_rep where id = v_line;
  exception when others then v_err := sqlerrm;
  end;
  assert v_err like 'REPORT_CLOSED%',
    format('TC-10: a sale was moved out of a CLOSED day, got [%s]', coalesce(v_err, 'no error at all'));

  --------------------------------------------------------------------------------- TC-11
  -- The null parent falls through. An ad-hoc count is not collateral damage.
  v_ok := false;
  begin
    insert into physical_counts (daily_report_id, location_id, event_date, item_type,
                                 counted_qty, system_qty, created_by)
         values (null, v_bra, v_day, 'CHILLI_PASTE', 87, 88, v_adm);
    v_ok := true;
  exception when others then v_err := sqlerrm;
  end;
  assert v_ok, format('TC-11: an ad-hoc physical count (no report) was refused: [%s]', v_err);

  raise exception 'SALES_SCHEMA_TEST_PASSED';   -- the only clean way back out
end $$;
