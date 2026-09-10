-- Failure-case tests for card ^ref-62 — fn_record_opening_balance and fn_set_opening_cost.
--
-- Covers TC-10 ... TC-24, TC-38, TC-39 and TC-41 from TDD-opening-balance.md. The close is
-- one-way even inside a transaction, so every case that needs it lives in
-- opening_close_test.sql behind its own sub-block rollback. TC-01 ... TC-09 are
-- schema-shaped and live in opening_schema_test.sql.
--
-- Each assert is a way stock or money is permanently wrong from day one, and this path has
-- no expectation to check itself against — every other write has a PO to over-deliver
-- against, a dispatch weight to receive against, a balance to draw from. An opening row IS
-- the expectation, so the guards below are all there is:
--
--   * an opening lot with no smoke date sorts as the newest stock and the oldest meat never
--     leaves. Nothing is wrong on day one; three months later there is year-old meat at the
--     back of a freezer and the FIFO picker has been right about it the whole time (R46)
--   * the cut-off is unset and a default is assumed, so every date is accepted and the
--     window that ADR-021 exists to bound does not exist (ADR-023, BR23)
--   * an Owner in Bangkok counts a Chiang Mai freezer — a figure with nobody behind it
--   * a price reaches the L3 who counted the meat (BR15, R20)
--   * a dropped Chiang Mai connection posts the count twice and 40 kg becomes 80 (R4)
--   * a cost lands on the ledger row, and ADR-003 has a hole in it (Seam 1)
--
-- Everything runs in a transaction that aborts on purpose, so no fixture persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/opening_balance_test.sql

do $$
declare
  v_owner   uuid := '66666666-6666-6666-6666-6666666666d1';
  v_l2      uuid := '66666666-6666-6666-6666-6666666666d2';
  v_l3      uuid := '66666666-6666-6666-6666-6666666666d3';
  v_gone    uuid := '66666666-6666-6666-6666-6666666666d4';
  v_chef    uuid;
  v_central uuid;
  v_brA     uuid;
  v_brB     uuid;
  v_pack    uuid;
  v_prod    uuid;
  v_id      uuid;
  v_again   uuid;
  v_other   uuid;
  v_key     uuid;
  v_lot     uuid;
  v_rev     uuid;
  v_repl    uuid;
  v_txt     text;
  v_ok      boolean;
  v_err     text;
  v_n       bigint;
  v_qty     numeric;
  v_cost    numeric;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3), (v_gone);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',            'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',         'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานเชียงใหม่', 'L3_CM_OPERATOR',  true),
    (v_gone,  'ผู้ที่ถูกปิดใช้',        'L3_CM_OPERATOR',  false);

  insert into locations (code, name_th, kind) values ('CH6', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('CE6', 'คลังกลาง', 'CENTRAL')
    returning id into v_central;
  insert into locations (code, name_th, kind) values ('B6A', 'สาขามีนบุรี', 'BRANCH')
    returning id into v_brA;
  insert into locations (code, name_th, kind) values ('B6B', 'สาขาศาลาแดง', 'BRANCH')
    returning id into v_brB;

  insert into user_locations (profile_id, location_id) values
    (v_l2, v_brA), (v_l3, v_chef), (v_gone, v_chef);

  insert into packaging_items (code, name_th, unit) values ('BOX6', 'กล่อง', 'ใบ')
    returning id into v_pack;
  insert into products (code, name_th, item_type, sale_unit)
    values ('CHL6', 'น้ำพริก', 'CHILLI_PASTE', 'กระปุก') returning id into v_prod;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  -- The cut-off is an Owner value with no date column to live in, so it is text and
  -- fn_config_date casts it. Nothing is configured before 2026-01-01, which is what gives
  -- TC-17 a date island where the key genuinely does not resolve.
  perform fn_set_config(gen_random_uuid(), 'opening_cutoff_date', date '2026-01-01',
                        p_value_text => '2026-10-01');

  --------------------------------------------------------------------------------- TC-10
  -- Happy path: the chef house counter enters 40 kg against a lot they name by code, and the
  -- lot and its smoke-date group are created for them. A counter has a freezer and a label,
  -- not a uuid.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_id := fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 40.00,
                                    date '2026-09-30',
                                    p_smoke_date => date '2026-08-15',
                                    p_lot_code   => 'OPEN-CM-001');
  assert v_id is not null, 'TC-10: fn_record_opening_balance returned no ledger id';

  select movement_type::text, qty_delta, stock_state::text, lot_id
    into v_txt, v_qty, v_err, v_lot
    from stock_ledger where id = v_id;
  assert v_txt = 'OPENING', format('TC-10: the row is a %s, not an OPENING', v_txt);
  assert v_qty = 40.00, format('TC-10: qty_delta is %s, not 40.00', v_qty);

  -- FROZEN, derived and not chosen (TDD Open Question 1). R14 moves weight FROZEN -> READY
  -- at the branch and a sale deducts READY only, so opening meat that landed READY would
  -- leave THAW_OUT with nothing to draw from. R13/BR19 says the same thing from the other
  -- end: ready meat is zero at day close, and an opening position is a day boundary.
  assert v_err = 'FROZEN', format('TC-10: opening meat landed in %s, not FROZEN', v_err);

  assert v_lot is not null, 'TC-10: the opening row names no lot';
  select is_opening
           and po_id                  is null
           and po_delivery_id         is null
           and foodiva_sent_weight_kg is null
           and chef_house_location_id is null,
         state::text
    into v_ok, v_txt
    from lots where id = v_lot;
  assert v_ok,
    'TC-10: the created lot is not a clean opening lot — is_opening false, or it carries a '
    'purchase order, a dispatch weight or a chef house it never had';
  assert v_txt = 'LOT_CLOSED',
    format('TC-10: the opening lot is in %s — its production finished before go-live and it '
           'must never accept a smoke log', v_txt);

  select smoke_date into v_err from smoke_date_groups
   where id = (select smoke_date_group_id from stock_ledger where id = v_id);
  assert v_err = '2026-08-15', format('TC-10: the smoke-date group is %s, not 2026-08-15', v_err);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select balance_qty into v_qty from v_stock_balance where lot_id = v_lot;
  assert v_qty = 40.00, format('TC-10: v_stock_balance shows %s, not 40.00', v_qty);

  --------------------------------------------------------------------------------- TC-11
  -- THE OWNER COUNTS CENTRAL AND NOWHERE ELSE, and this is the one place in the system where
  -- L1 is not a superset. ADR-021 assigns a counter per location: a count is a physical act,
  -- and an Owner in Bangkok counting a branch freezer is a figure with nobody behind it.
  -- THIS TEST EXISTS TO STOP THE RULE BEING "FIXED" BY WHOEVER READS IT NEXT.
  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'PACKAGING', v_brA, 10.00,
                                      date '2026-09-30', p_packaging_item_id => v_pack);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-11: the Owner counted a branch (%s)', coalesce(v_err, 'no exception at all'));

  -- And CENTRAL still works for them, so the rule cannot be "deny the Owner everything".
  v_other := fn_record_opening_balance(gen_random_uuid(), 'PACKAGING', v_central, 25.00,
                                       date '2026-09-30', p_packaging_item_id => v_pack);
  assert v_other is not null, 'TC-11: the Owner could not count CENTRAL either';

  --------------------------------------------------------------------------------- TC-12
  -- L2 counts their own branch. fn_require_branch is the preamble; the location-kind test on
  -- top of it is because that helper asks about MEMBERSHIP, not about what kind of place it
  -- is, and an L2 assigned to CENTRAL would otherwise count it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'PACKAGING', v_brB, 10.00,
                                      date '2026-09-30', p_packaging_item_id => v_pack);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-12: an L2 counted another branch (%s)', coalesce(v_err, 'none'));

  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'PACKAGING', v_central, 10.00,
                                      date '2026-09-30', p_packaging_item_id => v_pack);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-12: an L2 counted CENTRAL (%s)', coalesce(v_err, 'none'));

  --------------------------------------------------------------------------------- TC-13
  -- L3 counts the chef house and nowhere else.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'PACKAGING', v_central, 10.00,
                                      date '2026-09-30', p_packaging_item_id => v_pack);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-13: an L3 counted CENTRAL (%s)', coalesce(v_err, 'none'));

  --------------------------------------------------------------------------------- TC-14
  -- Actor before role (R31). A deactivated counter holding a live token is NO_ACTOR, not
  -- FORBIDDEN — both refuse, only one says which state the caller is actually in.
  perform set_config('request.jwt.claims', json_build_object('sub', v_gone)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 5.00,
                                      date '2026-09-30',
                                      p_smoke_date => date '2026-08-15',
                                      p_lot_code   => 'OPEN-CM-GONE');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%NO_ACTOR%';
  end;
  assert v_ok, format('TC-14: a deactivated profile recorded an opening balance (%s)',
                      coalesce(v_err, 'none'));

  --------------------------------------------------------------------------------- TC-15
  -- After the cut-off is refused, and the refusal names BOTH dates. An Owner told only
  -- "after the cut-off" has to go and look up which cut-off.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 5.00,
                                      date '2026-10-02',
                                      p_smoke_date => date '2026-08-15',
                                      p_lot_code   => 'OPEN-CM-LATE');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%OPENING_AFTER_CUTOFF%';
  end;
  assert v_ok, format('TC-15: a row dated after the cut-off was accepted (%s)',
                      coalesce(v_err, 'none'));
  assert v_err like '%2026-10-02%' and v_err like '%2026-10-01%',
    format('TC-15: the refusal does not name both dates (%s)', v_err);

  --------------------------------------------------------------------------------- TC-16
  -- ON the cut-off is accepted. `<=`, stated rather than guessed — the boundary is the one
  -- thing about a cut-off nobody can infer from the word.
  v_id := fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 12.00,
                                    date '2026-10-01',
                                    p_smoke_date => date '2026-08-16',
                                    p_lot_code   => 'OPEN-CM-EDGE');
  assert v_id is not null, 'TC-16: a row dated exactly on the cut-off was refused';

  --------------------------------------------------------------------------------- TC-17
  -- Cut-off unset: CONFIG_NOT_SET, and NOTHING IS DEFAULTED. The raise is the feature
  -- (ADR-023, BR23). A defaulted cut-off accepts every date, which is the same as having no
  -- cut-off while looking like having one.
  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 5.00,
                                      date '2025-12-31',
                                      p_smoke_date => date '2025-11-01',
                                      p_lot_code   => 'OPEN-CM-NOCFG');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%CONFIG_NOT_SET%';
  end;
  assert v_ok, format('TC-17: a date with no cut-off configured was accepted (%s)',
                      coalesce(v_err, 'none'));

  --------------------------------------------------------------------------------- TC-18
  -- Meat with no lot and no lot code. R21/ADR-017: every meat movement names its source lot.
  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 5.00,
                                      date '2026-09-30', p_smoke_date => date '2026-08-15');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%OPENING_LOT_REQUIRED%';
  end;
  assert v_ok, format('TC-18: smoked meat was counted with no lot (%s)', coalesce(v_err, 'none'));

  --------------------------------------------------------------------------------- TC-19
  -- THE SILENT ONE. Meat with a lot and no smoke date. Nothing is wrong on day one: the row
  -- posts, the balance is right, every screen agrees. Then the FIFO picker sorts the lot as
  -- the newest thing in stock and the oldest meat never leaves, and three months later there
  -- is year-old smoked meat at the back of a freezer (R46).
  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', v_chef, 5.00,
                                      date '2026-09-30', p_lot_id => v_lot);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%OPENING_SMOKE_DATE_REQUIRED%';
  end;
  assert v_ok, format('TC-19: smoked meat was counted with no smoke date (%s)',
                      coalesce(v_err, 'none'));

  --------------------------------------------------------------------------------- TC-20
  -- Non-meat needs no lot and no smoke date — but it does need to say WHAT it is
  -- (TDD Open Question 2, settled). v_stock_balance groups by product_id AND
  -- packaging_item_id, so a row carrying neither is a balance nothing can find and, because
  -- the ledger refuses UPDATE, nobody can correct.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_id := fn_record_opening_balance(gen_random_uuid(), 'PACKAGING', v_central, 500.00,
                                    date '2026-09-30', p_packaging_item_id => v_pack);
  assert v_id is not null, 'TC-20: packaging with an item and no lot was refused';
  select stock_state::text into v_txt from stock_ledger where id = v_id;
  assert v_txt = 'READY',
    format('TC-20: non-meat landed in %s; there is no thaw step for packaging and FROZEN '
           'would invent one', v_txt);

  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'PACKAGING', v_central, 5.00,
                                      date '2026-09-30');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%OPENING_PACKAGING_ITEM_REQUIRED%';
  end;
  assert v_ok, format('TC-20: packaging was counted with no packaging item (%s)',
                      coalesce(v_err, 'none'));

  v_ok := false; v_err := null;
  begin
    perform fn_record_opening_balance(gen_random_uuid(), 'CHILLI_PASTE', v_central, 5.00,
                                      date '2026-09-30');
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%OPENING_PRODUCT_REQUIRED%';
  end;
  assert v_ok, format('TC-20: chilli paste was counted with no product (%s)',
                      coalesce(v_err, 'none'));

  v_id := fn_record_opening_balance(gen_random_uuid(), 'CHILLI_PASTE', v_central, 30.00,
                                    date '2026-09-30', p_product_id => v_prod);
  assert v_id is not null, 'TC-20: chilli paste with a product was refused';

  --------------------------------------------------------------------------------- TC-21
  -- A retry from a dropped Chiang Mai connection returns the committed id and writes nothing
  -- twice. Without this the count is entered again by a counter who saw no confirmation, and
  -- 500 packs become 1000 with no way to tell which figure was real (R4, ADR-005).
  v_key := gen_random_uuid();
  select count(*) into v_n from stock_ledger;
  v_id    := fn_record_opening_balance(v_key, 'PACKAGING', v_central, 77.00,
                                       date '2026-09-30', p_packaging_item_id => v_pack);
  v_again := fn_record_opening_balance(v_key, 'PACKAGING', v_central, 77.00,
                                       date '2026-09-30', p_packaging_item_id => v_pack);
  assert v_id = v_again, format('TC-21: a replay returned a different id (%s vs %s)', v_id, v_again);
  select count(*) into v_qty from stock_ledger;
  assert v_qty = v_n + 1, format('TC-21: a replay wrote %s extra ledger row(s)', v_qty - v_n - 1);

  --------------------------------------------------------------------------------- TC-22
  -- The cost is L1 only, and it is a DIFFERENT FUNCTION rather than a branch inside the one
  -- the counter calls. BR15: who may enter a price is answered by which function you may
  -- call, and that answer cannot be weakened by an edit inside a body.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_set_opening_cost(v_id, 200.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%FORBIDDEN%';
  end;
  assert v_ok, format('TC-22: an L3 set an opening cost (%s)', coalesce(v_err, 'none'));

  --------------------------------------------------------------------------------- TC-23
  -- And it refuses a row that is not an OPENING one. Scoping the completeness rule to one
  -- movement type is the third reason OPENING is its own enum value: against ADJUSTMENT the
  -- rule would demand a cost on every correction the system ever writes.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  v_other := fn_post_ledger(gen_random_uuid(), 'PACKAGING', v_central, 'READY', 'INTAKE',
                            9.00, date '2026-09-30', p_packaging_item_id => v_pack);
  v_ok := false; v_err := null;
  begin
    perform fn_set_opening_cost(v_other, 150.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%NOT_AN_OPENING_ROW%';
  end;
  assert v_ok, format('TC-23: a cost was attached to a non-opening row (%s)',
                      coalesce(v_err, 'none'));

  --------------------------------------------------------------------------------- TC-24
  -- The Owner corrects a figure before the close, and THE LEDGER NEVER MOVES (Seam 1,
  -- ADR-003). This is the assert that says why the cost is a second table rather than a
  -- nullable column: a column filled in later is an UPDATE, and an UPDATE on stock_ledger is
  -- a hole in the append-only rule that stays open as long as somebody remembers to close it.
  select count(*), max(created_at) into v_n, v_err from stock_ledger;
  perform fn_set_opening_cost(v_id, 200.00);
  perform fn_set_opening_cost(v_id, 220.00);
  select cost_thb_per_kg into v_cost from opening_costs where ledger_id = v_id;
  assert v_cost = 220.00, format('TC-24: opening_costs holds %s, not the corrected 220.00', v_cost);

  select count(*) into v_qty from opening_costs where ledger_id = v_id;
  assert v_qty = 1, format('TC-24: the correction wrote %s cost rows, not one', v_qty);

  select count(*) into v_qty from stock_ledger;
  assert v_qty = v_n, format('TC-24: the ledger gained %s row(s) from a cost correction',
                             v_qty - v_n);

  select count(*) into v_qty from pg_attribute
   where attrelid = 'public.stock_ledger'::regclass and attnum > 0 and not attisdropped
     and attname ~ '(cost|price)';
  assert v_qty = 0, 'TC-24: stock_ledger grew a cost column after all';

  --------------------------------------------------------------------------------- TC-38
  -- Nothing this card added made a hole in R1. An opening row is a ledger row and the
  -- statement-level trigger refuses it like any other.
  v_ok := false; v_err := null;
  begin
    update stock_ledger set reason = 'แก้ไข' where id = v_id;
  exception when others then
    v_err := sqlerrm; v_ok := v_err like '%LEDGER_APPEND_ONLY%';
  end;
  assert v_ok, format('TC-38: an opening ledger row was updated (%s)', coalesce(v_err, 'none'));

  --------------------------------------------------------------------------------- TC-39
  -- A miscounted opening line is corrected the way everything else is: a reversal plus a
  -- replacement, WHILE THE WINDOW IS OPEN (R2, ADR-003). After the close the replacement
  -- would be a new OPENING row and the trigger refuses it — a real and deliberate
  -- consequence of a one-way switch, asserted in opening_close_test.sql TC-40.
  select reversal_id, replacement_id into v_rev, v_repl
    from fn_reverse_ledger_entry(gen_random_uuid(), v_id, 66.00, 'นับผิด');
  assert v_rev is not null,  'TC-39: no reversal row was posted for an opening row';
  assert v_repl is not null, 'TC-39: no replacement row was posted for an opening row';

  select movement_type::text, qty_delta into v_txt, v_qty from stock_ledger where id = v_rev;
  assert v_txt = 'REVERSAL', format('TC-39: the reversal is a %s', v_txt);
  assert v_qty = -77.00, format('TC-39: the reversal is %s, not -77.00', v_qty);

  select movement_type::text, qty_delta into v_txt, v_qty from stock_ledger where id = v_repl;
  assert v_txt = 'OPENING',
    format('TC-39: the replacement is a %s — a replacement for an opening row is an opening '
           'row, or the close switch stops covering it', v_txt);
  assert v_qty = 66.00, format('TC-39: the replacement is %s, not 66.00', v_qty);

  -- The original is still readable. That is the whole of ADR-003: a correction adds rows, it
  -- does not erase the one that was wrong.
  select count(*) into v_qty from stock_ledger where id = v_id;
  assert v_qty = 1, 'TC-39: the reversed row is gone';

  --------------------------------------------------------------------------------- TC-41
  -- R32: every state change writes one audit row, from ^ref-06's generic trigger, in the
  -- same transaction. Not written by fn_record_opening_balance and not by fn_post_ledger —
  -- either would audit every opening count twice.
  select count(*) into v_n from audit_log
   where table_name = 'stock_ledger' and row_id = v_id and action = 'INSERT';
  assert v_n = 1, format('TC-41: the opening ledger row has %s audit row(s), not one', v_n);

  select actor_id into v_txt from audit_log
   where table_name = 'stock_ledger' and row_id = v_id and action = 'INSERT';
  assert v_txt = v_owner::text,
    format('TC-41: the audit row names %s, not the session that wrote it', v_txt);

  select count(*) into v_n from audit_log
   where table_name = 'opening_costs' and row_id = v_id;
  assert v_n >= 1, 'TC-41: setting an opening cost wrote no audit row';

  raise exception 'OPENING_BALANCE_TEST_PASSED';   -- the only clean way back out
end $$;
