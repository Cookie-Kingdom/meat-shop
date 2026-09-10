-- Card ^ref-22 — fn_create_transport_run. The vehicle, its fare, and the method that will
-- split that fare (M2, BR16, D04.1).
--
-- A RUN IS THE VEHICLE, NOT THE MEAT. This function creates no lines. The array of lots is
-- taken, checked and discarded — it exists so R26 can be asked once, at the moment the run
-- is created, rather than one line at a time after three lines already exist. That was
-- Open Question 2 in TDD-transport.md and API_DATA_MODEL.md line 764 settles it: "a
-- CM_TO_FOODIVA run is refused unless EVERY LOT ON IT is RETURN_SCHEDULED". Every lot on
-- it is a property of the run, so the run is where it is asked.
--
-- alloc_method IS SNAPSHOTTED HERE AND IS NOT A PARAMETER (R29, BR16, BR23). Two reasons,
-- and the second is the one that matters:
--
--   1. A caller who can choose the method can choose a different one for the same day's two
--      runs, and nothing on any screen would say so.
--   2. A later config change must never move a closed number. fn_allocate_freight reads the
--      method off THIS ROW and never from config at call time — that is the whole of R29,
--      and it only works if the snapshot is taken at run creation.
--
-- CONFIG_NOT_SET propagates rather than defaulting. freight_alloc_method is a BLOCK row in
-- v_config_readiness (ADR-023), so an Owner who has not set it gets a named refusal, not a
-- run allocated by a method nobody chose (BR23).
--
-- R25's branch leg is checked by name here as well as by transport_runs_branch_leg_free.
-- The constraint is the enforcement; this raise is so an Owner who typed a fare against a
-- branch leg is told which rule refused it rather than reading a constraint name.
--
-- Covered by supabase/tests/transport_test.sql (TC-05 ... TC-12).

create or replace function public.fn_create_transport_run(
  p_idempotency_key uuid,
  p_route           transport_route,
  p_event_date      date,
  p_vehicle_type    text    default null,
  p_is_round_trip   boolean default false,
  p_run_cost_thb    numeric default 0,
  p_lot_ids         uuid[]  default null,
  p_note            text    default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor  uuid;
  v_run    transport_runs;
  v_method freight_alloc;
  v_text   text;
  v_bad    text;
  v_n      bigint;
  v_id     uuid;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  v_actor := fn_require_owner();

  if p_route is null then
    raise exception 'RUN_ROUTE_REQUIRED: a run without a route cannot be checked against R25 or R26';
  end if;

  if p_event_date is null then
    raise exception 'RUN_EVENT_DATE_REQUIRED: an undated run cannot resolve its alloc_method by event date (R12)';
  end if;

  if p_run_cost_thb is null or p_run_cost_thb < 0 then
    raise exception 'RUN_FARE_INVALID: run_cost_thb must be >= 0, got %', p_run_cost_thb;
  end if;

  ------------------------------------------------------------------------- the retry check
  -- Asked before anything is read or locked, the same shape as fn_add_po_delivery. A retry
  -- has to look exactly like the first call succeeded, or the client creates a second run
  -- to "fix" it and the fare is charged twice (R4).
  select * into v_run from transport_runs where idempotency_key = p_idempotency_key;
  if found then
    if v_run.route = p_route
       and v_run.event_date = p_event_date
       and v_run.run_cost_thb = p_run_cost_thb
       and v_run.is_round_trip = p_is_round_trip
       and v_run.vehicle_type is not distinct from p_vehicle_type then
      return v_run.id;
    end if;
    raise exception 'RUN_IDEMPOTENCY_CONFLICT: key % was used for a different run',
      p_idempotency_key;
  end if;

  -- R25. The check constraint refuses this too; this is the legible half.
  if p_route = 'CENTRAL_TO_BRANCH' and p_run_cost_thb <> 0 then
    raise exception 'BRANCH_LEG_NOT_FREE: a CENTRAL_TO_BRANCH run carries no fare, got % THB (R25, BR11)',
      p_run_cost_thb;
  end if;

  ----------------------------------------------------------------------------- R26 / BR17
  -- The return leg exists only once somebody entitled to do so has named a receive date,
  -- which is what lot_state = 'RETURN_SCHEDULED' records (fn_set_return_pickup_date,
  -- ^ref-34). Closing a lot creates no transport job.
  --
  -- Checked over the WHOLE array before anything is written. Per-lot inside a loop would
  -- refuse the third lot after two lines already existed — and TC-10 is exactly that case.
  if p_route = 'CM_TO_FOODIVA' then
    if p_lot_ids is null or array_length(p_lot_ids, 1) is null then
      raise exception 'RETURN_LOTS_REQUIRED: a CM_TO_FOODIVA run names the lots it is collecting (R26, BR17)';
    end if;

    select count(*) into v_n from lots where id = any (p_lot_ids);
    if v_n <> array_length(p_lot_ids, 1) then
      raise exception 'LOT_NOT_FOUND: % of % lot(s) named on this run do not exist',
        array_length(p_lot_ids, 1) - v_n, array_length(p_lot_ids, 1);
    end if;

    select string_agg(lot_code, ', ' order by lot_code) into v_bad
      from lots
     where id = any (p_lot_ids)
       and state <> 'RETURN_SCHEDULED';

    if v_bad is not null then
      raise exception 'RETURN_NOT_SCHEDULED: % has no return pickup date set (R26, BR17)', v_bad;
    end if;
  end if;

  ------------------------------------------------------------------------ the R29 snapshot
  v_text := fn_config_value('freight_alloc_method', p_event_date).value_text;
  if v_text is null then
    raise exception 'CONFIG_WRONG_TYPE: freight_alloc_method resolved to a non-text row at %',
      p_event_date;
  end if;
  begin
    v_method := v_text::freight_alloc;
  exception when invalid_text_representation then
    raise exception 'CONFIG_VALUE_INVALID: freight_alloc_method is %, expected BY_LOT_WEIGHT, EQUAL_SPLIT or MANUAL',
      v_text;
  end;

  insert into transport_runs (route, vehicle_type, is_round_trip, event_date, run_cost_thb,
                              alloc_method, created_by, note, idempotency_key)
  values (p_route, p_vehicle_type, p_is_round_trip, p_event_date, p_run_cost_thb,
          v_method, v_actor, p_note, p_idempotency_key)
  returning id into v_id;

  return v_id;

exception
  when unique_violation then
    -- Two sessions replaying one key: the loser reads the winner's row rather than failing
    -- on the index (R4). Same shape as fn_add_po_delivery.
    select id into v_id from transport_runs where idempotency_key = p_idempotency_key;
    if v_id is not null then
      return v_id;
    end if;
    raise;
end $$;

revoke execute on function public.fn_create_transport_run(uuid, transport_route, date, text, boolean, numeric, uuid[], text) from public, anon, authenticated;
grant  execute on function public.fn_create_transport_run(uuid, transport_route, date, text, boolean, numeric, uuid[], text) to authenticated;
