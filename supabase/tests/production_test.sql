-- Cards ^ref-26, ^ref-27 and ^ref-28 — fn_require_operator, fn_record_lot_receipt,
-- v_lot_pending_work, fn_upsert_smoke_daily_log, v_lot_progress and fn_record_lot_bags.
--
-- Covers TC-09 ... TC-28b and TC-30 ... TC-36 from TDD-lots.md, and red→green slices 3 ... 9.
-- TC-29 is the bags' concurrency and needs two sessions, so it is
-- production_concurrency_test.sh; this file is named for the range so each card appends to
-- it rather than starting another production test.
--
-- ONE do $$ BLOCK, and it has to stay one. migrations_apply_test.sh pipes each file into psql
-- WITHOUT --single-transaction, so every top-level statement is its own transaction: a second
-- block would COMMIT the first one's fixtures into the shared container and every test file
-- alphabetically after this one would inherit four lots and a chef house it never created.
-- The closing raise is what rolls this file back, and it can only roll back the block it is in.
--
-- THE SOURCE ROWS FOR TC-30 ... TC-32 STAY INSERTED DIRECTLY, and are not rewritten onto
-- fn_upsert_smoke_daily_log now that it exists. The view under test reads
-- smoke_daily_log_sources, so the fixture it needs is source rows; routing them through the
-- RPC would make a view test fail for a function's reason and would hide the -3.50 in TC-31
-- behind a lot-state guard that has nothing to do with the join being asserted. TC-21 is the
-- same cross-lot day through the RPC, on lots V and U, and that is where the two meet.
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
  v_logV    uuid;
  v_logX    uuid;
  v_key     uuid;
  v_grp     uuid;
  v_w       numeric[];
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

  insert into suppliers (name) values ('Foodiva') returning id into v_sup;

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

  -- The assignment goes through its writer, as the Owner (^ref-66). The dispatch leg (^ref-22)
  -- is not what this card tests, so the state is still set directly. v_lotU stays unassigned
  -- for now — it is TC-12's subject before it becomes TC-34's.
  perform fn_assign_lot_operator(gen_random_uuid(), l, v_l3)
     from unnest(array[v_lotA, v_lotB, v_lotV]) l;
  update lots set state = 'IN_TRANSIT' where id in (v_lotA, v_lotB, v_lotV, v_lotU);

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

  --------------------------------------------------------------------------------- TC-19
  -- CM 04's morning visit, on lot V — 40 kg out of its own meat and 4 kg of brine. The
  -- roll-up is the whole assertion: input_weight_kg is never a parameter, so a 40 that
  -- arrives on the log arrived through trg_rollup_smoke_log_input (R6a).
  v_logV := fn_upsert_smoke_daily_log(
              gen_random_uuid(), v_lotV, v_day,
              jsonb_build_array(jsonb_build_object('lot_id', v_lotV, 'input_weight_kg', 40.00)),
              p_brine_used_kg => 4.00);

  select count(*) into v_n from smoke_daily_logs where lot_id = v_lotV;
  assert v_n = 1, format('TC-19: %s log rows for one lot-day', v_n);

  select input_weight_kg into v_kg from smoke_daily_logs where id = v_logV;
  assert v_kg = 40.00,
    format('TC-19: input_weight_kg is %s, not 40.00 — the R6a trigger did not fire', v_kg);

  select brine_used_kg into v_kg from smoke_daily_logs where id = v_logV;
  assert v_kg = 4.00, format('TC-19: brine_used_kg stored as %s', coalesce(v_kg::text, 'null'));

  select state::text into v_txt from lots where id = v_lotV;
  assert v_txt = 'SMOKING', format('TC-19: lot_state is %s, not SMOKING after the first log', v_txt);

  -- Finding 7: the log's two packed columns are a third copy of the group's roll-up and are
  -- never written by anything. TC-08's half that needs a real write to assert.
  select count(*) into v_n from smoke_daily_logs
   where id = v_logV and (packed_weight_kg is not null or bag_count is not null);
  assert v_n = 0, 'TC-19/TC-08: fn_upsert_smoke_daily_log wrote the log''s packed columns';

  -- And the progress view reads the day, not the pack lines that do not exist yet.
  select days_logged into v_n from v_lot_progress where lot_id = v_lotV;
  assert v_n = 1, format('TC-19: v_lot_progress reads %s day(s) logged, not 1', v_n);
  select packed_weight_kg into v_kg from v_lot_progress where lot_id = v_lotV;
  assert v_kg = 0, format('TC-19: v_lot_progress reads %s kg packed before any bag exists', v_kg);

  --------------------------------------------------------------------------------- TC-20
  -- R6a and R18: a log with no sources cannot be saved. Empty array and null are the same
  -- refusal, because a client that omits the field and one that sends [] are the same bug.
  v_ok := false; v_err := null;
  begin
    perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotV, v_day + 5, '[]'::jsonb);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'INPUT_SOURCES_REQUIRED:%';
  end;
  assert v_ok, format('TC-20: an empty p_sources got %s', coalesce(v_err, 'no exception at all'));

  v_ok := false; v_err := null;
  begin
    perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotV, v_day + 5, null);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'INPUT_SOURCES_REQUIRED:%';
  end;
  assert v_ok, format('TC-20: a null p_sources got %s', coalesce(v_err, 'no exception at all'));

  -- NS-06 (^fix-numeric-scale). smoke_daily_log_sources.input_weight_kg is numeric(12,2): a
  -- third decimal is refused by name, and the count below proves it wrote no log either.
  v_ok := false; v_err := null;
  begin
    perform fn_upsert_smoke_daily_log(gen_random_uuid(), v_lotV, v_day + 5,
      jsonb_build_array(jsonb_build_object('lot_id', v_lotV, 'input_weight_kg', 1.005)));
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'TOO_MANY_DECIMALS: source 1 input_weight_kg is 1.005 %';
  end;
  assert v_ok, format('NS-06: a 1.005 kg source got %s', coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from smoke_daily_logs where lot_id = v_lotV and event_date = v_day + 5;
  assert v_n = 0, format('TC-20: %s log row(s) written by the refused calls', v_n);

  --------------------------------------------------------------------------------- TC-21
  -- The cross-lot day through the RPC (D05, Seam 2). One log FILED under lot V, drawing 30 kg
  -- out of V and 10 kg out of lot U. Two source rows, one log, and the roll-up is 40.
  v_logX := fn_upsert_smoke_daily_log(
              gen_random_uuid(), v_lotV, v_day + 1,
              jsonb_build_array(
                jsonb_build_object('lot_id', v_lotV, 'input_weight_kg', 30.00),
                jsonb_build_object('lot_id', v_lotU, 'input_weight_kg', 10.00)));

  select count(*) into v_n from smoke_daily_log_sources where smoke_daily_log_id = v_logX;
  assert v_n = 2, format('TC-21: %s source rows for a two-lot day', v_n);

  select input_weight_kg into v_kg from smoke_daily_logs where id = v_logX;
  assert v_kg = 40.00, format('TC-21: the roll-up over two source lots reads %s, not 40.00', v_kg);

  -- And the two lots are charged separately, which is the D05 join the views ride on.
  select input_consumed_kg into v_kg from v_lot_progress where lot_id = v_lotV;
  assert v_kg = 70.00,
    format('TC-21: lot V has consumed %s kg, not 70.00 — 40 on day one and its own 30 on day two', v_kg);

  --------------------------------------------------------------------------------- TC-22
  -- R6a holds against a partial write, and the correction path is where it actually bites:
  -- the delete has already run by the time a later element of the array fails, so anything
  -- less than one transaction leaves the log with no sources at all.
  v_ok := false; v_err := null;
  begin
    perform fn_upsert_smoke_daily_log(
              gen_random_uuid(), v_lotV, v_day + 1,
              jsonb_build_array(
                jsonb_build_object('lot_id', v_lotV,             'input_weight_kg', 30.00),
                jsonb_build_object('lot_id', v_lotU,             'input_weight_kg', 10.00),
                jsonb_build_object('lot_id', gen_random_uuid(),  'input_weight_kg',  5.00)));
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'SOURCE_LOT_NOT_HERE:%';
  end;
  assert v_ok, format('TC-22: a source lot that is not at this chef house got %s',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from smoke_daily_log_sources where smoke_daily_log_id = v_logX;
  assert v_n = 2, format('TC-22: the refused correction left %s source rows, not the original 2', v_n);

  select input_weight_kg into v_kg from smoke_daily_logs where id = v_logX;
  assert v_kg = 40.00, format('TC-22: the refused correction left the roll-up at %s, not 40.00', v_kg);

  -- The same guarantee one element earlier: a duplicated source lot is named, not left to the
  -- (smoke_daily_log_id, lot_id) unique to surface as a constraint nobody can translate.
  v_ok := false; v_err := null;
  begin
    perform fn_upsert_smoke_daily_log(
              gen_random_uuid(), v_lotV, v_day + 1,
              jsonb_build_array(
                jsonb_build_object('lot_id', v_lotV, 'input_weight_kg', 30.00),
                jsonb_build_object('lot_id', v_lotV, 'input_weight_kg', 10.00)));
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'SOURCE_LOT_DUPLICATED:%';
  end;
  assert v_ok, format('TC-22: one lot twice in p_sources got %s',
                      coalesce(v_err, 'no exception at all'));

  --------------------------------------------------------------------------------- TC-23
  -- The 18:00 correction (Seam 3, Finding 3). A FRESH key against the same (lot_id,
  -- event_date): same row, sources REPLACED not merged, and the output weight the morning
  -- visit did not have.
  v_key := gen_random_uuid();
  v_logA := fn_upsert_smoke_daily_log(
              v_key, v_lotV, v_day,
              jsonb_build_array(jsonb_build_object('lot_id', v_lotV, 'input_weight_kg', 35.00)),
              p_smoked_weight_kg => 26.00);
  assert v_logA = v_logV, 'TC-23: the correction created a second log instead of updating the first';

  select count(*) into v_n from smoke_daily_logs where lot_id = v_lotV and event_date = v_day;
  assert v_n = 1, format('TC-23: %s log rows for one lot-day after the correction', v_n);

  select input_weight_kg into v_kg from smoke_daily_logs where id = v_logV;
  assert v_kg = 35.00,
    format('TC-23: input_weight_kg is %s, not 35.00 — the sources were merged, not replaced', v_kg);

  select count(*) into v_n from smoke_daily_log_sources where smoke_daily_log_id = v_logV;
  assert v_n = 1, format('TC-23: %s source rows after replacing a one-element array', v_n);

  select smoked_weight_kg into v_kg from smoke_daily_logs where id = v_logV;
  assert v_kg = 26.00, format('TC-23: smoked_weight_kg stored as %s', coalesce(v_kg::text, 'null'));

  -- The morning's brine survives an evening call that does not mention it — the effective
  -- value, the same shape fn_record_lot_receipt uses for post_drain and the reason.
  select brine_used_kg into v_kg from smoke_daily_logs where id = v_logV;
  assert v_kg = 4.00,
    format('TC-23: the evening visit erased the morning brine (%s)', coalesce(v_kg::text, 'null'));

  --------------------------------------------------------------------------------- TC-24
  -- The dropped connection (R4). The SAME key, a different payload: the original id comes
  -- back and NOTHING is written — which is exactly what makes the fresh key above a
  -- correction rather than a conflict.
  v_logA := fn_upsert_smoke_daily_log(
              v_key, v_lotV, v_day,
              jsonb_build_array(jsonb_build_object('lot_id', v_lotV, 'input_weight_kg', 99.00)),
              p_smoked_weight_kg => 1.00);
  assert v_logA = v_logV, 'TC-24: a replayed key returned a different log id';

  select input_weight_kg into v_kg from smoke_daily_logs where id = v_logV;
  assert v_kg = 35.00, format('TC-24: the replay wrote input_weight_kg %s over the original 35.00', v_kg);

  select smoked_weight_kg into v_kg from smoke_daily_logs where id = v_logV;
  assert v_kg = 26.00, format('TC-24: the replay wrote smoked_weight_kg %s over the original 26.00', v_kg);

  --------------------------------------------------------------------------------- TC-25
  -- CM 04's bottom half (BR18, R7). Sixty pack weights on lot V's first smoke date, one call.
  -- One group, sixty bags, and the group's totals are the roll-up's — fn_record_lot_bags never
  -- writes them (Finding 7).
  v_w := array(select 0.50 + (i % 7) * 0.01 from generate_series(1, 60) i);
  select sum(w) into v_kg from unnest(v_w) w;
  select count(*) into v_ledger from stock_ledger;
  v_key := gen_random_uuid();
  v_n := fn_record_lot_bags(v_key, v_lotV, v_day, v_w);
  assert v_n = 60, format('TC-25: fn_record_lot_bags reported %s bags, not 60', v_n);

  select count(*) into v_n from smoke_date_groups where lot_id = v_lotV and smoke_date = v_day;
  assert v_n = 1, format('TC-25: %s smoke-date groups for one (lot, smoke_date)', v_n);
  select id into v_grp from smoke_date_groups where lot_id = v_lotV and smoke_date = v_day;

  select count(*) into v_n from lot_bags where smoke_date_group_id = v_grp;
  assert v_n = 60, format('TC-25: %s bags in the group, not 60', v_n);

  select count(*) into v_n from smoke_date_groups
   where id = v_grp and bag_count = 60 and packed_weight_kg = v_kg;
  assert v_n = 1,
    format('TC-25: the group does not read 60 bags / %s kg — the roll-up did not fire', v_kg);

  -- CM 05's progress view reads that same roll-up, never the log's packed columns (Finding 7).
  select count(*) into v_n from v_lot_progress
   where lot_id = v_lotV and bag_count = 60 and packed_weight_kg = v_kg;
  assert v_n = 1, 'TC-25: v_lot_progress does not read the group roll-up after the first batch';

  select count(*) - v_ledger into v_n from stock_ledger;
  assert v_n = 0,
    format('TC-25: fn_record_lot_bags posted %s ledger row(s) — the bags post at close (Finding 10)', v_n);

  --------------------------------------------------------------------------------- TC-26
  -- The dropped connection on a 60-bag save (Seam 3, R39). Same key, same array: the same
  -- count comes back and nothing is written twice — the whole risk on this table, because a
  -- replay would mint seqs 61 ... 120 and the pair index would never fire.
  v_n := fn_record_lot_bags(v_key, v_lotV, v_day, v_w);
  assert v_n = 60, format('TC-26: the replay reported %s bags, not the original 60', v_n);

  select count(*) into v_n from lot_bags where smoke_date_group_id = v_grp;
  assert v_n = 60, format('TC-26: %s bags after the replay — the batch was written twice', v_n);

  select count(*) into v_n from smoke_date_groups where id = v_grp and packed_weight_kg = v_kg;
  assert v_n = 1, 'TC-26: the replay moved the group''s packed_weight_kg';

  --------------------------------------------------------------------------------- TC-27
  -- Same key, a longer array. (key, 61) collides with nothing in lot_bags_batch_key, so the
  -- index alone would have let bag 61 in; the explicit key check is the enforcement.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_bags(v_key, v_lotV, v_day, v_w || 0.55::numeric);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'LOT_BAGS_IDEMPOTENCY_CONFLICT:%';
  end;
  assert v_ok, format('TC-27: a replayed key carrying 61 weights got %s',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from lot_bags where smoke_date_group_id = v_grp;
  assert v_n = 60, format('TC-27: %s bags after the refused call, not 60', v_n);

  --------------------------------------------------------------------------------- TC-28
  -- A second genuine batch on the same smoke date APPENDS (Seam 3) — neither a correction nor
  -- a conflict. The unique on (smoke_date_group_id, seq) rules out a repeat, so 70 rows with
  -- min 1 and max 70 is "no gap and no restart".
  v_n := fn_record_lot_bags(gen_random_uuid(), v_lotV, v_day,
                            array(select 0.48::numeric from generate_series(1, 10)));
  assert v_n = 10, format('TC-28: the second batch reported %s bags, not 10', v_n);

  select count(*) || '/' || min(seq) || '/' || max(seq) into v_txt
    from lot_bags where smoke_date_group_id = v_grp;
  assert v_txt = '70/1/70', format('TC-28: bags/min seq/max seq read %s, not 70/1/70', v_txt);

  select count(*) into v_n from smoke_date_groups
   where id = v_grp and bag_count = 70 and packed_weight_kg = v_kg + 4.80;
  assert v_n = 1, 'TC-28: the group roll-up did not add the second batch';

  select count(*) into v_n from smoke_date_groups where lot_id = v_lotV;
  assert v_n = 1, format('TC-28: %s groups for lot V — the second batch opened a new one', v_n);

  -------------------------------------------------------------------------------- TC-28a
  -- A smoke date the lot was never logged on (TDD open question 5). CM 04 has one date field,
  -- so the bags' smoke date IS the log's date; a date with no log is meat from nowhere, and
  -- the refusal leaves no group behind.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_bags(gen_random_uuid(), v_lotV, v_day + 9, array[0.50]::numeric[]);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'SMOKE_LOG_MISSING:%';
  end;
  assert v_ok, format('TC-28a: bags on a day lot V was never logged got %s',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from smoke_date_groups where lot_id = v_lotV and smoke_date = v_day + 9;
  assert v_n = 0, 'TC-28a: the refused call left a smoke-date group behind';

  -------------------------------------------------------------------------------- TC-28b
  -- A weight that rounds to 0.00 is refused by name and by position, not by the check
  -- constraint's name. v_day + 1 HAS a log, so it is the weight and not the date refusing it.
  v_ok := false; v_err := null;
  begin
    perform fn_record_lot_bags(gen_random_uuid(), v_lotV, v_day + 1, array[0.50, 0.004]::numeric[]);
  exception when others then
    v_err := sqlerrm; v_ok := v_err like 'PACK_WEIGHT_INVALID: bag 2 %';
  end;
  assert v_ok, format('TC-28b: a pack weight that rounds to 0.00 got %s',
                      coalesce(v_err, 'no exception at all'));

  select count(*) into v_n from lot_bags b join smoke_date_groups g on g.id = b.smoke_date_group_id
   where g.lot_id = v_lotV and g.smoke_date = v_day + 1;
  assert v_n = 0, format('TC-28b: the refused batch wrote %s bag(s)', v_n);

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

  -- Both views, or the second one is scoped by whichever card wrote it last.
  select count(*) into v_n from v_lot_progress;
  assert v_n = 3, format('TC-34: the L3 sees %s lot(s) in v_lot_progress, not their own 3', v_n);

  select count(*) into v_n from v_lot_progress where lot_id = v_lotU;
  assert v_n = 0, 'TC-34: the L3 reads somebody else''s lot in v_lot_progress (R34, CM 01)';

  --------------------------------------------------------------------------------- TC-35
  -- F6 is not a branch feature. The L3 em dash in the doc's view table, asserted.
  perform set_config('request.jwt.claims', json_build_object('sub', v_l2)::text, true);
  select count(*) into v_n from v_lot_pending_work;
  assert v_n = 0, format('TC-35: an L2 reads %s row(s) of a chef-house view', v_n);
  select count(*) into v_n from v_lot_progress;
  assert v_n = 0, format('TC-35: an L2 reads %s row(s) of v_lot_progress', v_n);

  -- And the Owner sees all four, or the role test has narrowed the view rather than scoped it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner)::text, true);
  select count(*) into v_n from v_lot_pending_work;
  assert v_n = 4, format('TC-35: the Owner reads %s of 4 lots', v_n);
  select count(*) into v_n from v_lot_progress;
  assert v_n = 4, format('TC-35: the Owner reads %s of 4 lots in v_lot_progress', v_n);

  --------------------------------------------------------------------------------- TC-33
  -- R17 as an absence. Every ingredient of a loss figure is in v_lot_progress and the division
  -- is not — no percentage of any kind, for any role, and no money column either (BR15). This
  -- is what stops "partial output against a full dispatch" from reaching a screen as a Loss.
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'v_lot_progress'
     and (column_name like '%loss%' or column_name like '%yield%' or column_name like '%pct%'
       or column_name like '%\_thb' or column_name like '%price%' or column_name like '%cost%');
  assert v_n = 0,
    format('TC-33/R17: v_lot_progress carries %s loss, yield or money column(s) — the division '
           'belongs to v_lot_yield after close', v_n);

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

  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'v_lot_progress'
     and grantee in ('anon', 'authenticated');
  assert v_n = 1, format('TC-36: v_lot_progress holds %s session-role grant(s), not 1', v_n);

  select count(*) into v_n
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'v_lot_progress'
     and grantee = 'authenticated' and privilege_type = 'SELECT';
  assert v_n = 1, 'TC-36: v_lot_progress is not readable by authenticated';

  raise exception 'PRODUCTION_TEST_PASSED';   -- the only clean way back out
end $$;
