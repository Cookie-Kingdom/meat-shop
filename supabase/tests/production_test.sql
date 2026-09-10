-- Card ^ref-26 — fn_require_operator, fn_record_lot_receipt and v_lot_pending_work.
--
-- Covers TC-09 ... TC-18, TC-30 ... TC-32 and TC-34 ... TC-36 from TDD-lots.md, and red→green
-- slices 3, 4, 5 and 8. TC-19 ... TC-29 (the daily log and the bags) belong to ^ref-27 and
-- ^ref-28 and are not in this file yet; the file is named for the range so those cards append
-- to it rather than starting a fourth production test.
--
-- ONE do $$ BLOCK, and it has to stay one. migrations_apply_test.sh pipes each file into psql
-- WITHOUT --single-transaction, so every top-level statement is its own transaction: a second
-- block would COMMIT the first one's fixtures into the shared container and every test file
-- alphabetically after this one would inherit four lots and a chef house it never created.
-- The closing raise is what rolls this file back, and it can only roll back the block it is in.
--
-- THE SOURCE ROWS FOR TC-30 ... TC-32 ARE INSERTED DIRECTLY, not through
-- fn_upsert_smoke_daily_log, which does not exist until ^ref-27. Deliberate, not a shortcut:
-- the view under test reads smoke_daily_log_sources, so the fixture it needs is source rows,
-- and routing them through an RPC nobody has written yet would make this card's test fail for
-- the next card's reason. TC-21 asserts the same cross-lot day through the RPC once it exists.
--
-- Everything runs in a transaction that aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/production_test.sql

do $$
declare
  v_n       bigint;
  v_txt     text;
  v_who     uuid;
  v_ok      boolean;
  v_err     text;
  v_kg      numeric;
  v_ledger  bigint;
  v_day     date := date '2026-05-04';
  v_owner   uuid := gen_random_uuid();
  v_l2      uuid := gen_random_uuid();
  v_l3      uuid := gen_random_uuid();
  v_l3b     uuid := gen_random_uuid();
  v_l3c     uuid := gen_random_uuid();
  v_gone    uuid := gen_random_uuid();
  v_chef    uuid;
  v_chef2   uuid;
  v_branch  uuid;
  v_sup     uuid;
  v_po      uuid;
  v_lotA    uuid;
  v_lotB    uuid;
  v_lotV    uuid;
  v_lotU    uuid;
  v_rec     uuid;
  v_rec2    uuid;
  v_logA    uuid;
begin
  ------------------------------------------------------------------------------- fixtures
  insert into auth.users (id) values (v_owner), (v_l2), (v_l3), (v_l3b), (v_l3c), (v_gone);
  insert into profiles (id, display_name, role, is_active) values
    (v_owner, 'เจ้าของ',                'L1_OWNER',        true),
    (v_l2,    'แอดมินสาขา',             'L2_BRANCH_ADMIN', true),
    (v_l3,    'ผู้ปฏิบัติงานคนที่หนึ่ง',    'L3_CM_OPERATOR',  true),
    (v_l3b,   'ผู้ปฏิบัติงานโรงรมที่สอง',  'L3_CM_OPERATOR',  true),
    (v_l3c,   'ผู้ปฏิบัติงานคนที่สาม',     'L3_CM_OPERATOR',  true),
    (v_gone,  'ผู้ปฏิบัติงานที่ปิดใช้',     'L3_CM_OPERATOR',  false);

  insert into locations (code, name_th, kind) values ('CH26', 'โรงรมเชียงใหม่', 'CHEF_HOUSE')
    returning id into v_chef;
  insert into locations (code, name_th, kind) values ('CH27', 'โรงรมที่สอง', 'CHEF_HOUSE')
    returning id into v_chef2;
  insert into locations (code, name_th, kind) values ('BR26', 'สาขามีนบุรี', 'BRANCH')
    returning id into v_branch;

  -- v_gone is a member of the chef house too: TC-09 has to fail on the profile and not on
  -- membership, or it proves nothing about the order of the four questions. v_l3c is a second
  -- operator at the SAME chef house, which is what makes TC-34 a scope test rather than a
  -- location test all over again.
  insert into user_locations (profile_id, location_id) values
    (v_l3, v_chef), (v_l3c, v_chef), (v_gone, v_chef), (v_l3b, v_chef2), (v_l2, v_branch);

  insert into suppliers (name) values ('ฟู้ดดีว่า') returning id into v_sup;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);

  perform fn_set_config(gen_random_uuid(), 'receipt_variance_threshold_pct', date '2026-01-01',
                        p_value_numeric => 20.00);
  perform fn_set_config(gen_random_uuid(), 'receipt_variance_requires_reason', date '2026-01-01',
                        p_value_text => 'true');

  v_po := fn_create_po(gen_random_uuid(), v_sup, v_day, 1000.00, 250.00);
  v_lotA := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotB := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotV := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);
  v_lotU := fn_add_po_delivery(gen_random_uuid(), v_po, v_day, 100.00, v_chef);

  -- The dispatch leg (^ref-22) is not what this card tests, so the state and the assignment
  -- are set directly. v_lotU stays unassigned for now — it is TC-12's subject before it
  -- becomes TC-34's.
  update lots set state = 'IN_TRANSIT', assigned_operator_id = v_l3
   where id in (v_lotA, v_lotB, v_lotV);
  update lots set state = 'IN_TRANSIT' where id = v_lotU;

  --------------------------------------------------------------------------------- TC-09
  -- A deactivated operator holding a live token is NO_ACTOR, not FORBIDDEN. The order of the
  -- four questions is the behaviour: fn_current_role() folds in is_active and would report
  -- this caller as merely forbidden, which is true and hides the real state (R31).
  perform set_config('request.jwt.claims', json_build_object('sub', v_gone)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_require_operator(v_lotA);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NO_ACTOR:%';
  end;
  assert v_ok, format('TC-09: a deactivated operator got %s',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-10
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_require_operator(v_lotA);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN:%';
  end;
  assert v_ok, format('TC-10: an L2 got %s', coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-11
  -- Right role, wrong chef house. v_l3b is a perfectly good L3 at another site.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3b)::text, true);
  v_ok := false; v_err := null;
  begin
    perform fn_require_operator(v_lotA);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'FORBIDDEN_LOCATION:%';
  end;
  assert v_ok, format('TC-11: an L3 of another chef house got %s',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-12
  -- Right chef house, not assigned — and NOT the same test as TC-11. v_l3 holds membership of
  -- v_chef and still may not touch a lot that is not theirs (CM 01).
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  update lots set assigned_operator_id = v_l3c where id = v_lotU;
  v_ok := false; v_err := null;
  begin
    perform fn_require_operator(v_lotU);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_ASSIGNED_OPERATOR:%';
  end;
  assert v_ok, format('TC-12: somebody else''s lot at the caller''s own chef house got %s',
                      coalesce(v_err, 'no exception at all'));

  -- And the null case, which `<>` would let through: an unassigned lot is not "assigned to
  -- whoever asks". `null <> actor` is null, and a guard that falls through on null is a guard
  -- that is off for every lot nobody has claimed yet.
  update lots set assigned_operator_id = null where id = v_lotU;
  v_ok := false; v_err := null;
  begin
    perform fn_require_operator(v_lotU);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_ASSIGNED_OPERATOR:%';
  end;
  assert v_ok, format('TC-12: a lot assigned to nobody got %s',
                      coalesce(v_err, 'no exception at all'));

  ---------------------------------------------------------------------- the preamble, live
  -- Slice 4. The same refusal has to arrive through the RPC, or the four questions are
  -- answered in a function nobody calls.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotU, v_day, 95.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'NOT_ASSIGNED_OPERATOR:%';
  end;
  assert v_ok, format('slice 4: a receipt against an unassigned lot got %s',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from lot_receipts where lot_id = v_lotU;
  assert v_n = 0, format('slice 4: %s receipt row(s) written for an unassigned lot', v_n);

  --------------------------------------------------------------------------------- TC-13
  -- CM 02. 98.00 against a dispatch of 100.00 is 2% off and needs no reason.
  select count(*) into v_ledger from stock_ledger;

  v_rec := fn_record_lot_receipt(gen_random_uuid(), v_lotA, v_day, 98.00);

  select count(*) into v_n from lot_receipts where lot_id = v_lotA;
  assert v_n = 1, format('TC-13: %s receipt rows for one lot', v_n);

  select received_weight_kg into v_kg from lot_receipts where id = v_rec;
  assert v_kg = 98.00, format('TC-13: received_weight_kg stored as %s', v_kg);

  select post_drain_weight_kg into v_kg from lot_receipts where id = v_rec;
  assert v_kg is null,
    format('TC-13: post_drain_weight_kg is %s after CM 02, not null', v_kg);

  select state::text into v_txt from lots where id = v_lotA;
  assert v_txt = 'CM_RECEIVED', format('TC-13: lot_state is %s, not CM_RECEIVED', v_txt);

  -- The preamble's return is what signs the row. recorded_by is not a parameter, so a caller
  -- cannot sign as somebody else.
  select recorded_by into v_who from lot_receipts where id = v_rec;
  assert v_who = v_l3, 'TC-13: recorded_by is not the calling operator';

  --------------------------------------------------------------------------------- TC-14
  -- The meat arrived at fn_confirm_transport_receipt (Seam 4, Finding 10). A second posting
  -- here would double the chef house balance, and it is the most attractive wrong line in
  -- the whole function.
  select count(*) into v_n from stock_ledger;
  assert v_n = v_ledger,
    format('TC-14: fn_record_lot_receipt posted %s ledger row(s) — the meat is already there',
           v_n - v_ledger);

  --------------------------------------------------------------------------------- TC-15
  -- CM 03 completes the SAME row on a later afternoon. Not a second receipt and not a
  -- conflict: lot_id is unique and carries the retry (R38, Seam 3).
  v_rec2 := fn_record_lot_receipt(gen_random_uuid(), v_lotA, v_day, 98.00, 96.50);
  assert v_rec2 = v_rec, 'TC-15: CM 03 returned a different receipt id';

  select count(*) into v_n from lot_receipts where lot_id = v_lotA;
  assert v_n = 1, format('TC-15: %s receipt rows after CM 03 — the second visit inserted', v_n);

  select post_drain_weight_kg into v_kg from lot_receipts where id = v_rec;
  assert v_kg = 96.50, format('TC-15: post_drain_weight_kg is %s, not 96.50', v_kg);

  -- And the CM 02 figure survived the CM 03 visit. Only the fields the caller sent move.
  select received_weight_kg into v_kg from lot_receipts where id = v_rec;
  assert v_kg = 98.00, format('TC-15: received_weight_kg moved to %s on the second call', v_kg);

  --------------------------------------------------------------------------------- TC-16
  -- By NAME, not as a raw check_violation. The constraint is what survives a writer added in
  -- 2027 (production_schema_test.sql TC-06); this raise is what CM 03 renders in Thai.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotA, v_day, 98.00, 99.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'POST_DRAIN_EXCEEDS_RECEIVED:%';
  end;
  assert v_ok, format('TC-16: post-drain 99 against received 98 got %s',
                      coalesce(v_err, 'no exception at all'));

  select post_drain_weight_kg into v_kg from lot_receipts where id = v_rec;
  assert v_kg = 96.50, format('TC-16: the refused call still moved post_drain to %s', v_kg);

  --------------------------------------------------------------------------------- TC-17
  -- 70 against 100 is 30% off, past the 20% tolerance, with the reason toggle on and no
  -- reason given. ALERT mode, so what refuses the call is the missing reason and never the
  -- variance itself — the meat weighed what it weighed.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_receipt(gen_random_uuid(), v_lotV, v_day, 70.00);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'VARIANCE_REASON_REQUIRED:%';
  end;
  assert v_ok, format('TC-17: a 30%% variance with no reason got %s',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from lot_receipts where lot_id = v_lotV;
  assert v_n = 0, format('TC-17: %s receipt row(s) written by the refused call', v_n);

  select state::text into v_txt from lots where id = v_lotV;
  assert v_txt = 'IN_TRANSIT', format('TC-17: the refused call advanced lot_state to %s', v_txt);

  --------------------------------------------------------------------------------- TC-18
  -- Same weight, with a reason: RECORDED, not refused.
  v_rec2 := fn_record_lot_receipt(gen_random_uuid(), v_lotV, v_day, 70.00,
                                  null, 'น้ำแข็งละลายระหว่างขนส่ง');
  select variance_reason into v_txt from lot_receipts where id = v_rec2;
  assert v_txt = 'น้ำแข็งละลายระหว่างขนส่ง',
    format('TC-18: variance_reason stored as %s', coalesce(v_txt, 'null'));

  select verdict into v_txt from fn_check_variance(70.00, 100.00, 'ALERT', 20.00);
  assert v_txt = 'OVER_THRESHOLD',
    format('TC-18: the verdict on 70 against 100 is %s, not OVER_THRESHOLD', v_txt);

  -- The CM 03 visit on this lot sends a post-drain weight and NO reason, and must not be
  -- refused for a variance somebody already explained. The effective reason is the one on the
  -- row, not the parameter — testing p_variance_reason alone locks the operator out of their
  -- own second visit.
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotV, v_day, 70.00, 68.00);
  select variance_reason into v_txt from lot_receipts where id = v_rec2;
  assert v_txt = 'น้ำแข็งละลายระหว่างขนส่ง',
    format('TC-18: the CM 03 visit erased the reason (%s)', coalesce(v_txt, 'null'));

  --------------------------------------------------------------------------------- TC-30
  -- R18. post-drain 96.50, inputs 40 + 30 drawn out of lot A → 26.50 pending.
  insert into smoke_daily_logs (lot_id, event_date, recorded_by)
       values (v_lotA, v_day, v_l3) returning id into v_logA;
  insert into smoke_daily_log_sources (smoke_daily_log_id, lot_id, input_weight_kg)
       values (v_logA, v_lotA, 40.00);

  insert into smoke_daily_logs (lot_id, event_date, recorded_by)
       values (v_lotA, v_day + 1, v_l3) returning id into v_logA;
  insert into smoke_daily_log_sources (smoke_daily_log_id, lot_id, input_weight_kg)
       values (v_logA, v_lotA, 30.00);

  select pending_weight_kg into v_kg from v_lot_pending_work where lot_id = v_lotA;
  assert v_kg = 26.50,
    format('TC-30: pending work reads %s, not 26.50 (R18)', coalesce(v_kg::text, 'null'));

  select input_consumed_kg into v_kg from v_lot_pending_work where lot_id = v_lotA;
  assert v_kg = 70.00, format('TC-30: input_consumed_kg reads %s, not 70.00', v_kg);

  --------------------------------------------------------------------------------- TC-31
  -- The cross-lot day, and the join that gets it wrong is the obvious one (Seam 2, D05).
  -- A log FILED under lot A draws 10 kg SOURCED from lot B. B's pending work is down by 10 —
  -- not by 0 (which is what joining through smoke_daily_logs.lot_id gives) and not by 40.
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotB, v_day, 99.00, 97.00);

  insert into smoke_daily_logs (lot_id, event_date, recorded_by)
       values (v_lotA, v_day + 2, v_l3) returning id into v_logA;
  insert into smoke_daily_log_sources (smoke_daily_log_id, lot_id, input_weight_kg)
       values (v_logA, v_lotA, 30.00), (v_logA, v_lotB, 10.00);

  select pending_weight_kg into v_kg from v_lot_pending_work where lot_id = v_lotB;
  assert v_kg = 87.00,
    format('TC-31: lot B pending work reads %s, not 87.00 — the sum is over sources.lot_id, '
           'never over the logs filed under the lot', coalesce(v_kg::text, 'null'));

  -- And A took the other 30, not the whole 40: 96.50 − 40 − 30 − 30.
  select pending_weight_kg into v_kg from v_lot_pending_work where lot_id = v_lotA;
  assert v_kg = -3.50,
    format('TC-31: lot A pending work reads %s, not -3.50', coalesce(v_kg::text, 'null'));

  --------------------------------------------------------------------------------- TC-32
  -- Never output-derived (R18). smoked_weight_kg sits one join away and is the obvious wrong
  -- answer; recording an output well below the inputs must not move pending work at all.
  update smoke_daily_logs set smoked_weight_kg = 5.00 where id = v_logA;
  select pending_weight_kg into v_kg from v_lot_pending_work where lot_id = v_lotB;
  assert v_kg = 87.00,
    format('TC-32: pending work moved to %s when an output was recorded',
           coalesce(v_kg::text, 'null'));

  -- And the column is not there to be reached for later. BR15: no output, no yield, no money.
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'v_lot_pending_work'
     and (column_name like '%smoked%' or column_name like '%yield%' or column_name like '%loss%'
       or column_name like '%\_thb'  or column_name like '%price%' or column_name like '%cost%');
  assert v_n = 0,
    format('TC-32/BR15: v_lot_pending_work carries %s output, yield or money column(s)', v_n);

  --------------------------------------------------------------------------------- TC-34
  -- R34. v_lotU belongs to v_l3c, a second operator at the SAME chef house, so this is a
  -- scope test and not TC-11 in different clothes.
  update lots set assigned_operator_id = v_l3c where id = v_lotU;
  perform set_config('request.jwt.claims', json_build_object('sub', v_l3c)::text, true);
  perform fn_record_lot_receipt(gen_random_uuid(), v_lotU, v_day, 95.00, 93.00);

  perform set_config('request.jwt.claims', json_build_object('sub', v_l3)::text, true);
  select count(*) into v_n from v_lot_pending_work;
  assert v_n = 3, format('TC-34: the L3 sees %s lot(s), not their own 3', v_n);

  select count(*) into v_n from v_lot_pending_work where lot_id = v_lotU;
  assert v_n = 0, 'TC-34: the L3 can read a lot assigned to somebody else (R34, CM 01)';

  --------------------------------------------------------------------------------- TC-35
  -- F6 is not a branch feature. The L3 em dash in the doc's view table, asserted.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  select count(*) into v_n from v_lot_pending_work;
  assert v_n = 0, format('TC-35: an L2 reads %s row(s) of a chef-house view', v_n);

  -- And the Owner sees all four, or the role test has narrowed the view rather than scoped it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_lot_pending_work;
  assert v_n = 4, format('TC-35: the Owner reads %s of 4 lots', v_n);

  --------------------------------------------------------------------------------- TC-36
  -- ^ref-64: exactly one grant, and it is SELECT to authenticated. anon holds nothing.
  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'v_lot_pending_work'
     and grantee in ('anon', 'authenticated');
  assert v_n = 1, format('TC-36: v_lot_pending_work holds %s session-role grant(s), not 1', v_n);

  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'v_lot_pending_work'
     and grantee = 'authenticated' and privilege_type = 'SELECT';
  assert v_n = 1, 'TC-36: v_lot_pending_work is not readable by authenticated';

  raise exception 'PRODUCTION_TEST_PASSED';   -- the only clean way back out
end $$;
