-- Card ^ref-48 — fn_record_rice. The branch's sticky rice for the day, M7A or M7B depending on
-- the branch's rice_model (PLAN-materials.md T2, Findings 3, 4, 5, 12, 13; TDD Seam 2).
--
-- ONE ROW, WRITTEN TWICE, AND THAT IS NORMAL. rice_records is unique on daily_report_id. BR 03
-- (morning) sends what came in or was cooked; BR 07 (evening) sends what is left (v0.2:90,
-- :94). The second call is not a retry, so the key cannot be the natural key. Two mechanisms,
-- in this order, as in fn_upsert_smoke_daily_log:
--
--   1. Look the key up. Hit → return that row, write nothing.                 (R4)
--   2. Miss → upsert on daily_report_id, stamping the new key on the row.     (R39)
--
-- THE MERGE HAPPENS INSIDE ON CONFLICT DO UPDATE, AGAINST THE STORED ROW. Each visit sends only
-- its own fields, so an absent field keeps what is on the row: a value can be corrected but not
-- cleared, and clearing one is an unlock-and-fix, not a null. `coalesce(excluded.x,
-- rice_records.x)` reads the row as it stands when the update runs. `coalesce(param, pre-read)`
-- would read it before the insert blocked, and a morning and an evening write racing on one
-- report would then erase each other (TC-31, the mutation check in
-- materials_concurrency_test.sh).
--
-- THE MODEL IS THE ROW'S ONCE THERE IS A ROW (R29). rice_records.model is the per-day snapshot
-- (branch_daily_schema_test.sql TC-06). An Owner who switches a branch from EXTERNAL_COOKED to
-- SELF_COOK at noon must not have the evening write validated against the new model, or the
-- rice_records_model_fields CHECK fails with a constraint name nobody can render in Thai. So
-- the model is looked up on the row first and on locations only when there is no row yet
-- (TC-25).
--
-- carried_in_cooked_kg IS COMPUTED, NEVER A PARAMETER. BR 03: "ระบบ … แสดงยอดยกมาจากเมื่อวาน".
-- The query is fn_open_daily_report's, unchanged: the MOST RECENT cooked_remaining_kg strictly
-- before the report date, not yesterday's, and never coalesced. Null means "nobody has recorded
-- rice here yet" and 0 means "no rice left" (TC-23). It is recomputed on every write, so it is
-- stored as the value the day actually carried.
--
-- L2 ONLY, fn_require_branch. v0.2:58 gives the Owner view-and-configure on supporting stock,
-- not edit (PLAN Finding 3). If the Owner overrules that, the preamble is the one line to change.
--
-- NO CLOSED CHECK HERE. Lane C's fn_guard_report_closed (...0018) raises REPORT_CLOSED on every
-- rice_records write, and admits a CLOSED report under an approved, unexpired unlock. A `status =
-- 'CLOSED'` test in this body would refuse writes that the trigger admits. R28's back-dating
-- window IS checked, against the report's date and never current_date (ADR-014). It runs after
-- the replay, so a retry of a committed write is never refused because the window closed
-- between the two calls (Finding 12). It applies to an OPEN report only: a CLOSED day under an
-- approved, unexpired unlock is lane C's trigger to admit (Finding 4 amended; lane H
-- PLAN-unlock.md Finding 1).
--
-- NO PRICE AND NO LEDGER ROW. cooked_price_thb_per_kg and raw_price_thb_per_kg are L1-only and
-- no rice cost key exists, so an L2 writer does not write them. Rice posts nothing to
-- stock_ledger: its balance is this table (lane C PLAN-sales.md Finding 10, TC-26).
--
-- Covered by supabase/tests/materials_rice_test.sql (TC-10 ... TC-30) and
-- supabase/tests/materials_concurrency_test.sh (TC-31).

create or replace function public.fn_record_rice(
  p_idempotency_key     uuid,
  p_daily_report_id     uuid,
  p_cooked_received_kg  numeric default null,
  p_raw_purchased_kg    numeric default null,
  p_cooked_today_kg     numeric default null,
  p_raw_remaining_kg    numeric default null,
  p_cooked_remaining_kg numeric default null
) returns json
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor   uuid;
  v_report  daily_reports;
  v_model   rice_model;
  v_carried numeric(12,2);
  v_bad     text;
  v_id      uuid;
  v_row     rice_records;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  select * into v_report from daily_reports where id = p_daily_report_id;
  if not found then
    raise exception 'REPORT_NOT_FOUND: no daily report % — open the day first (BR 01)', p_daily_report_id;
  end if;

  -- Actor, role, membership — in that order, and before any key or row is looked up.
  v_actor := fn_require_branch(v_report.location_id);

  ------------------------------------------------------------------------ 1. the replay (R4)
  -- The row holds only the newest key, so an older one is looked up in prior_keys (…0026). A
  -- morning call replayed after the evening's write is still a replay (TC-22).
  select id into v_id from rice_records
   where idempotency_key = p_idempotency_key
      or prior_keys @> array[p_idempotency_key];

  if v_id is null then
    ------------------------------------------------------------------ 2. the window (R28)
    -- OPEN days only. An approved unlock leaves the day CLOSED and writes an APPROVED, unexpired
    -- DAILY_REPORT unlock_requests row (lane H, PLAN-unlock.md Finding 1). Lane C's trigger alone
    -- decides a CLOSED day: it admits the write under a live unlock, whatever the day's age, and
    -- refuses it with REPORT_CLOSED once expires_at has passed (R42). So the window is the
    -- ordinary path's rule and never the escalation's (v0.2:401 D07). Nested, so
    -- fn_backdating_allowed is not even asked about a non-OPEN day.
    if v_report.status = 'OPEN' then
      if not fn_backdating_allowed(v_report.report_date) then
        raise exception 'BACKDATE_NOT_ALLOWED: % is outside the back-dating window — a change that old goes through the unlock path (R28)',
          v_report.report_date;
      end if;
    end if;

    ----------------------------------------------------------------------- 3. the model
    select model into v_model from rice_records where daily_report_id = v_report.id;
    if v_model is null then
      select rice_model into v_model from locations where id = v_report.location_id;
    end if;
    if v_model is null then
      raise exception 'RICE_MODEL_NOT_SET: location % has no rice_model — the Owner sets EXTERNAL_COOKED or SELF_COOK first (M7)',
        v_report.location_id;
    end if;

    ------------------------------------------------------------------- 4. the arguments
    select string_agg(k, ', ') into v_bad
      from (values ('cooked_received_kg',  p_cooked_received_kg),
                   ('raw_purchased_kg',    p_raw_purchased_kg),
                   ('cooked_today_kg',     p_cooked_today_kg),
                   ('raw_remaining_kg',    p_raw_remaining_kg),
                   ('cooked_remaining_kg', p_cooked_remaining_kg)) v(k, x)
     where x < 0;
    if v_bad is not null then
      raise exception 'RICE_WEIGHT_INVALID: % must be >= 0 kg', v_bad;
    end if;

    -- M7A receives cooked rice and never cooks; M7B cooks its own and receives none. A field
    -- from the other model is a number that belongs to no process (rice_records_model_fields
    -- is the backstop; this is the message).
    if v_model = 'EXTERNAL_COOKED' then
      select string_agg(k, ', ') into v_bad
        from (values ('raw_purchased_kg', p_raw_purchased_kg),
                     ('cooked_today_kg',  p_cooked_today_kg),
                     ('raw_remaining_kg', p_raw_remaining_kg)) v(k, x)
       where x is not null;
    else
      select string_agg(k, ', ') into v_bad
        from (values ('cooked_received_kg', p_cooked_received_kg)) v(k, x)
       where x is not null;
    end if;
    if v_bad is not null then
      raise exception 'RICE_FIELD_NOT_FOR_MODEL: % is not part of the % model at this branch (M7A/M7B)',
        v_bad, v_model;
    end if;

    if num_nonnulls(p_cooked_received_kg, p_raw_purchased_kg, p_cooked_today_kg,
                    p_raw_remaining_kg, p_cooked_remaining_kg) = 0 then
      raise exception 'RICE_VALUES_REQUIRED: a rice record with no weight in it records nothing (M7)';
    end if;

    ------------------------------------------------------------- 5. the carry-forward
    select cooked_remaining_kg into v_carried
      from rice_records
     where location_id = v_report.location_id
       and event_date  < v_report.report_date
     order by event_date desc
     limit 1;

    ------------------------------------------------------ 6. the upsert on the natural key
    insert into rice_records (daily_report_id, location_id, event_date, model,
                              carried_in_cooked_kg, cooked_received_kg, raw_purchased_kg,
                              cooked_today_kg, raw_remaining_kg, cooked_remaining_kg,
                              created_by, idempotency_key)
         values (v_report.id, v_report.location_id, v_report.report_date, v_model,
                 v_carried, p_cooked_received_kg, p_raw_purchased_kg,
                 p_cooked_today_kg, p_raw_remaining_kg, p_cooked_remaining_kg,
                 v_actor, p_idempotency_key)
    on conflict (daily_report_id) do update
       -- model and created_by are NOT in this list: the model is the row's snapshot (R29) and
       -- created_by is the first writer. audit_log records every later one (R32).
       set carried_in_cooked_kg = excluded.carried_in_cooked_kg,
           cooked_received_kg   = coalesce(excluded.cooked_received_kg,  rice_records.cooked_received_kg),
           raw_purchased_kg     = coalesce(excluded.raw_purchased_kg,    rice_records.raw_purchased_kg),
           cooked_today_kg      = coalesce(excluded.cooked_today_kg,     rice_records.cooked_today_kg),
           raw_remaining_kg     = coalesce(excluded.raw_remaining_kg,    rice_records.raw_remaining_kg),
           cooked_remaining_kg  = coalesce(excluded.cooked_remaining_kg, rice_records.cooked_remaining_kg),
           idempotency_key      = excluded.idempotency_key,
           prior_keys           = rice_records.prior_keys || rice_records.idempotency_key
    returning id into v_id;
  end if;

  select * into v_row from rice_records where id = v_id;

  -- No price column in the response: the caller is L2 (R20).
  return json_build_object(
    'rice_record_id',       v_row.id,
    'daily_report_id',      v_row.daily_report_id,
    'model',                v_row.model,
    'carried_in_cooked_kg', v_row.carried_in_cooked_kg,
    'cooked_received_kg',   v_row.cooked_received_kg,
    'raw_purchased_kg',     v_row.raw_purchased_kg,
    'cooked_today_kg',      v_row.cooked_today_kg,
    'raw_remaining_kg',     v_row.raw_remaining_kg,
    'cooked_remaining_kg',  v_row.cooked_remaining_kg);
end $$;

revoke execute on function public.fn_record_rice(uuid, uuid, numeric, numeric, numeric, numeric, numeric) from public, anon, authenticated;
grant  execute on function public.fn_record_rice(uuid, uuid, numeric, numeric, numeric, numeric, numeric) to authenticated;
