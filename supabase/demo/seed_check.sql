-- Card ^ref-65 — the demo's own test (TDD-demo-mode.md DS-01…DS-08), run by reset.sh after
-- the seed. Reads only. Aborts on its first failed assertion; on success it raises
-- DEMO_SEED_CHECK_PASSED, which also rolls back the role and claims it set.

begin;

do $$
declare
  v_owner   uuid := (select id from auth.users where email = 'demo-owner@demo.local');
  v_chef    uuid := (select id from auth.users where email = 'demo-chef@demo.local');
  v_l2      uuid[] := array[(select id from auth.users where email = 'demo-salaeng@demo.local'),
                            (select id from auth.users where email = 'demo-minburi@demo.local')];
  v_own     uuid[] := array[(select id from locations where code = 'SLD'),
                            (select id from locations where code = 'MNB')];
  v_lotA    uuid := (select id from lots order by event_date limit 1);
  v_lotB    uuid := (select id from lots order by event_date offset 1 limit 1);
  v_lotC    uuid := (select id from lots order by event_date offset 2 limit 1);
  v_priced  text[];
  v_view    text;
  v_n       bigint;
  v_kg      numeric;
  v_txt     text;
begin
  --------------------------------------------------------------- as postgres, behind RLS
  select count(*) into v_n
    from stock_ledger l join locations x on x.id = l.location_id where x.kind = 'BRANCH';
  assert v_n = 0, format('DS-07: %s ledger row(s) at a branch; branches start empty (D8)', v_n);

  select count(*) into v_n from opening_balance_close;
  assert v_n = 0, 'DS-08: opening balances are closed; the seed must never close them (D8)';
  select count(*) into v_n from user_locations where can_receive_central;
  assert v_n = 0, format('DS-08: %s central-receiver delegate(s); the Owner receives (D9)', v_n);

  -- Every view that carries a money, yield or loss column. Found by name rather than listed,
  -- so a view added later is covered without editing this file.
  select array_agg(distinct table_name) into v_priced
    from information_schema.columns c
   where c.table_schema = 'public'
     and c.table_name in (select viewname from pg_views where schemaname = 'public')
     and (column_name ~ '(price|cost|_thb|yield|loss)');

  perform set_config('role', 'authenticated', true);

  ------------------------------------------------------------------------------ owner
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  select string_agg(item_key, ', ') into v_txt
    from v_config_readiness where severity = 'BLOCK' and not is_set;
  assert v_txt is null, format('DS-01: BLOCK item(s) unset: %s (ADR-023)', v_txt);

  select sum(available_qty) into v_kg from v_central_available where lot_id = v_lotA;
  assert v_kg = 75.00, format('DS-05: lot A offers %s kg at central, expected 75.00', v_kg);

  select string_agg(state::text, ',' order by lot_date) into v_txt
    from v_operator_lots where lot_id in (v_lotB, v_lotC);
  assert v_txt = 'SMOKING,IN_TRANSIT', format('DS-06: lots B and C read %s', v_txt);

  ------------------------------------------------------------------------------- chef
  perform set_config('request.jwt.claims', json_build_object('sub', v_chef)::text, true);

  foreach v_view in array v_priced loop
    begin
      execute format('select count(*) from %I', v_view) into v_n;
    exception when insufficient_privilege then
      v_n := 0;
    end;
    assert v_n = 0,
      format('DS-02: the chef reads %s row(s) of %s, which carries price or yield (R20)', v_n, v_view);
  end loop;

  select string_agg(state::text, ',' order by lot_date) into v_txt
    from v_operator_lots where lot_id in (v_lotB, v_lotC);
  assert v_txt = 'SMOKING,IN_TRANSIT', format('DS-03: the chef sees lots B and C as %s', v_txt);

  ---------------------------------------------------------------------- branch admins
  for i in 1 .. 2 loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_l2[i])::text, true);
    select count(*) into v_n from v_my_branches where id <> v_own[i];
    assert v_n = 0, format('DS-04: branch admin %s sees %s other branch(es)', i, v_n);
    select count(*) into v_n from v_my_branches where id = v_own[i];
    assert v_n = 1, format('DS-04: branch admin %s does not see their own branch', i);
    select count(*) into v_n from v_stock_balance where location_id <> v_own[i];
    assert v_n = 0, format('DS-04: branch admin %s reads %s balance row(s) elsewhere', i, v_n);
  end loop;

  raise exception 'DEMO_SEED_CHECK_PASSED';
end $$;
