-- Card ^ref-27 — fn_upsert_smoke_daily_log. CM 04: what went into the smoker today, which
-- lots it came out of, and — on a second visit the same evening — what came back out
-- (D05, R6, R6a, R17, R39, Finding 3).
--
-- TWO IDEMPOTENCY MECHANISMS, IN THIS ORDER, AND THEY ARE NOT THE SAME RULE (Finding 3,
-- Seam 3). The card's acceptance line says "idempotent on (lot_id, event_date)"; R4 says a
-- replayed key returns the original result WITHOUT writing. For this table both are needed
-- and they cannot be collapsed, because a second write against the same (lot_id, event_date)
-- is NORMAL rather than a retry: the operator enters the input weight and the brine in the
-- morning and comes back at 18:00 for the output weight.
--
--   1. Look the key up. Hit → return the existing log id, write nothing.        (R4)
--   2. Miss → upsert on (lot_id, event_date), stamping the new key on the row.  (^ref-27)
--
-- So a genuine correction arrives on a fresh key and updates; a dropped connection arrives on
-- the same key and does not. smoke_daily_logs.idempotency_key therefore holds the key of the
-- MOST RECENT write, which is what makes ...0013's unique index safe across corrections rather
-- than in spite of them. R5's trick — the natural key IS the payload, so no key column is
-- needed, which is what fn_record_lot_receipt rides on — does not transfer here, because the
-- natural key is two columns out of nine.
--
-- THE SOURCES ARRAY IS REPLACED, NOT MERGED. delete-then-insert inside the same transaction,
-- so the R6a roll-up trigger settles on the new total and a correction that drops a source lot
-- actually drops it. Deleting a source row is not an ADR-003 violation: append-only is a rule
-- about stock_ledger, and R32's audit trigger records the delete.
--
-- EVERY SOURCE IS VALIDATED BEFORE ANY OF THEM IS WRITTEN, the shape fn_set_smoke_fee_tier
-- uses for its band set. It matters most on a CORRECTION: the delete has already run by the
-- time element three is reached, so a mid-array failure that only rolled back the inserts
-- would leave the log with no sources at all. One transaction, and the pre-pass makes the
-- refusal a named exception rather than a foreign-key violation (TC-22).
--
-- p_sources IS REQUIRED, AND EMPTY IS NOT A LOG (R6a, R18). R6a says the log cannot be saved
-- with zero sources; R18's whole point is that pending work is input-derived, so a log with no
-- sources makes it uncomputable and silently leaves the source lot never running out of meat.
--
-- NO p_input_weight_kg. It is the R6a roll-up and typing it directly is what the trigger
-- exists to prevent. NO p_packed_weight_kg AND NO p_bag_count either: the pack lines belong to
-- the smoke-date group, not to the log, so those two columns are never written by anything
-- (Finding 7, ...0013's comments on them, TC-08). v_lot_progress reads the group's roll-up.
--
-- THE STATE GUARD IS A FLOOR, NOT A RANGE, AND THAT IS THE DIFFERENCE FROM ^ref-26's RECEIPT.
-- A log against PO_CREATED or IN_TRANSIT is a log against meat still on somebody else's floor
-- and nothing else refuses it, so `< CM_RECEIVED` raises. The upper end is deliberately left
-- open to ...0013's fn_guard_lot_closed: R8 says a child row may be written against a closed
-- lot when an approved, unexpired unlock_request exists (R42), and a `not in (CM_RECEIVED,
-- SMOKING)` test here would refuse that write before the trigger ever ran — making the whole
-- unlock path dead code for this function (TC-50, TC-51, TC-52).
--
-- OPTIONAL WEIGHTS FALL BACK TO WHAT IS ON THE ROW, the same effective-value shape
-- fn_record_lot_receipt uses for post_drain and the variance reason, and for the same reason:
-- CM 04's two visits send different halves of one row, and the 18:00 call sending no brine
-- figure must not erase the morning's. A value can therefore be corrected but not cleared;
-- clearing one is an unlock-and-fix, not a null.
--
-- NO LEDGER ROW (Finding 10). The transformation from lot meat to smoke-date groups posts at
-- fn_close_lot (^ref-29) and nowhere earlier — until ADR-025 closes, nothing in this range
-- touches stock_ledger at all.
--
-- Covered by supabase/tests/production_test.sql (TC-19 ... TC-24).

create or replace function public.fn_upsert_smoke_daily_log(
  p_idempotency_key       uuid,
  p_lot_id                uuid,
  p_event_date            date,
  p_sources               jsonb,
  p_smoked_weight_kg      numeric default null,
  p_brine_used_kg         numeric default null,
  p_post_freeze_weight_kg numeric default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor   uuid;
  v_lot     lots;
  v_log     smoke_daily_logs;
  v_src     jsonb;
  v_i       integer := 0;
  v_src_lot uuid;
  v_src_kg  numeric;
  v_chef    uuid;
  v_seen    uuid[] := '{}';
  v_id      uuid;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  if p_event_date is null then
    raise exception 'LOG_EVENT_DATE_REQUIRED: the log is one row per lot per day and the day is the key (R6)';
  end if;

  if p_sources is null or jsonb_typeof(p_sources) <> 'array' then
    raise exception 'INPUT_SOURCES_REQUIRED: p_sources must be an array of (lot_id, input_weight_kg), got % (D05, R6a)',
      coalesce(jsonb_typeof(p_sources), 'null');
  end if;
  if jsonb_array_length(p_sources) = 0 then
    raise exception 'INPUT_SOURCES_REQUIRED: a log with no sources makes pending work uncomputable (R6a, R18)';
  end if;

  if p_smoked_weight_kg is not null and p_smoked_weight_kg < 0 then
    raise exception 'SMOKED_WEIGHT_INVALID: smoked_weight_kg must be >= 0, got %', p_smoked_weight_kg;
  end if;
  if p_brine_used_kg is not null and p_brine_used_kg < 0 then
    raise exception 'BRINE_WEIGHT_INVALID: brine_used_kg must be >= 0, got %', p_brine_used_kg;
  end if;
  if p_post_freeze_weight_kg is not null and p_post_freeze_weight_kg < 0 then
    raise exception 'POST_FREEZE_WEIGHT_INVALID: post_freeze_weight_kg must be >= 0, got %',
      p_post_freeze_weight_kg;
  end if;

  -- Four questions, and LOT_NOT_FOUND among them. See fn_require_operator's header.
  v_actor := fn_require_operator(p_lot_id);

  ------------------------------------------------------------------------- 1. the replay (R4)
  -- Before anything is locked and before the natural key is consulted. A hit here is a dropped
  -- connection, not a correction, and it writes nothing at all — including no state advance.
  select id into v_id from smoke_daily_logs where idempotency_key = p_idempotency_key;
  if found then
    return v_id;
  end if;

  select * into v_lot from lots where id = p_lot_id for update;

  if v_lot.state < 'CM_RECEIVED' then
    raise exception 'LOT_STATE_INVALID: lot % is at %, and the meat has to be at the chef house before it can go in the smoker',
      v_lot.lot_code, v_lot.state;
  end if;
  v_chef := v_lot.chef_house_location_id;

  ------------------------------------------------------------- 2. validate the whole array
  for v_src in select value from jsonb_array_elements(p_sources)
  loop
    v_i       := v_i + 1;
    v_src_lot := (v_src ->> 'lot_id')::uuid;
    v_src_kg  := (v_src ->> 'input_weight_kg')::numeric;

    if v_src_lot is null then
      raise exception 'SOURCE_LOT_REQUIRED: source % names no lot_id — every kilogram says which lot it came out of (D05, ADR-017)',
        v_i;
    end if;
    if v_src_kg is null or v_src_kg <= 0 then
      raise exception 'SOURCE_WEIGHT_INVALID: source % draws % kg — a source row is a positive weight',
        v_i, coalesce(v_src_kg::text, 'null');
    end if;
    if v_src_lot = any (v_seen) then
      raise exception 'SOURCE_LOT_DUPLICATED: lot % appears twice in p_sources — one row per source lot per log (R6a)',
        v_src_lot;
    end if;
    v_seen := v_seen || v_src_lot;

    -- Same chef house, or the log claims meat that is not in the building. The other half of
    -- T6's rule — not LOT_CLOSED or beyond — is ...0013's trigger firing on the source row,
    -- deliberately not repeated here: written twice, the two copies drift.
    if not exists (select 1 from lots
                    where id = v_src_lot and chef_house_location_id = v_chef) then
      raise exception 'SOURCE_LOT_NOT_HERE: lot % is not a lot at this chef house (D05)', v_src_lot;
    end if;
  end loop;

  ------------------------------------------------------- 3. the upsert on the natural key (R6)
  select * into v_log from smoke_daily_logs
   where lot_id = p_lot_id and event_date = p_event_date for update;

  insert into smoke_daily_logs (lot_id, event_date, smoked_weight_kg, brine_used_kg,
                                post_freeze_weight_kg, recorded_by, idempotency_key)
       values (p_lot_id, p_event_date,
               coalesce(p_smoked_weight_kg,      v_log.smoked_weight_kg),
               coalesce(p_brine_used_kg,         v_log.brine_used_kg),
               coalesce(p_post_freeze_weight_kg, v_log.post_freeze_weight_kg),
               v_actor, p_idempotency_key)
  on conflict (lot_id, event_date) do update
     set smoked_weight_kg      = excluded.smoked_weight_kg,
         brine_used_kg         = excluded.brine_used_kg,
         post_freeze_weight_kg = excluded.post_freeze_weight_kg,
         recorded_by           = excluded.recorded_by,
         idempotency_key       = excluded.idempotency_key
  returning id into v_id;

  ------------------------------------------------------------------ 4. replace the sources
  delete from smoke_daily_log_sources where smoke_daily_log_id = v_id;

  insert into smoke_daily_log_sources (smoke_daily_log_id, lot_id, input_weight_kg)
  select v_id, (value ->> 'lot_id')::uuid, (value ->> 'input_weight_kg')::numeric
    from jsonb_array_elements(p_sources);

  -- Idempotent on its own: a lot already SMOKING stays SMOKING, and a closed lot being
  -- corrected under an approved unlock is not dragged back down the lifecycle.
  update lots set state = 'SMOKING' where id = p_lot_id and state = 'CM_RECEIVED';

  return v_id;
end $$;

revoke execute on function public.fn_upsert_smoke_daily_log(uuid, uuid, date, jsonb, numeric, numeric, numeric) from public, anon, authenticated;
grant  execute on function public.fn_upsert_smoke_daily_log(uuid, uuid, date, jsonb, numeric, numeric, numeric) to authenticated;
