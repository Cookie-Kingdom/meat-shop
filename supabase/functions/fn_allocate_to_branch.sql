-- Card ^ref-36 — fn_allocate_to_branch. OW 07: the Owner sends part of central stock to one
-- branch, by weight and by bag count (R25, BR11, BR07, v0.2:108).
--
-- NOT A LEDGER WRITER. It picks the run and hands the movement to fn_dispatch_transport_line,
-- which posts -kg off (central, FROZEN) and +kg at (branch, IN_TRANSIT) under the caller's key —
-- one writer for the IN_TRANSIT tuple (^ref-22 Seam 1). What this function owns is the
-- allocation's own rules, in front of that call, and the two columns only it writes, after.
--
-- ONLY FROM CENTRAL STOCK (BR11). The group must be a row of v_central_available — the same view
-- OW 07 proposes from, so the picker and this check cannot disagree (Seam 5). NOT_IN_CENTRAL_STOCK
-- and INSUFFICIENT_CENTRAL_STOCK are the legible half; R3 inside fn_post_ledger is the
-- enforcement, and it is what catches two sessions over-drawing one group at once.
--
-- FIFO IS BY SMOKE DATE, AND THE LOT INSIDE THE DATE IS A CHOICE. v0.2:184 "จ่ายกลุ่มวันที่เก่า
-- ก่อนตาม FIFO และบันทึกเหตุผลเมื่อข้าม", :188 "เรียงวันรมควันก่อนและแสดง Lot ให้เลือกภายในวันนั้น",
-- :329 BR 07 "FIFO ตามวันที่รมควัน". PLAN-movement T9 step 5 compared (smoke_date, lot_id), which
-- would demand a reason for the second of two lots smoked on one day — ranked by uuid, which has
-- nothing to do with age — and disagree with fn_record_thaw's check (ready-ref-40-41-thaw/
-- PLAN-thaw.md Finding 3). An override is a pick whose smoke date is later than the oldest date
-- central holds. A reason sent with a pick that is NOT an override is dropped, so "how often was
-- FIFO skipped" is `fifo_override_reason is not null` and nothing else.
--
-- THE REASON HAS ITS OWN COLUMN (Seam 4). variance_reason is the receiver's and
-- fn_confirm_transport_receipt overwrites it on every receipt; a FIFO reason parked there would
-- be deleted by the branch signing for the delivery. TC-31.
--
-- THE BAG COUNT HAS NO DEFAULT (v0.2:108, OW 07 "น้ำหนัก และจำนวนถุง"). It is what BR 02 counts
-- against at the branch (v0.2:89). It is the number LOADED, never count(*) of lot_bags, which is
-- the number packed (TC-47).
--
-- ONE CENTRAL_TO_BRANCH RUN PER (BRANCH, EVENT DATE). Found by that pair, created at a fare of 0
-- when absent (R25 — fn_create_transport_run and transport_runs_branch_leg_free both refuse any
-- other), under a transaction advisory lock on the pair, so two allocations to one branch at the
-- same moment share a run instead of making two (TC-35). The run key is derived from the
-- caller's, never gen_random_uuid(). fn_create_transport_run still resolves
-- freight_alloc_method, so CONFIG_NOT_SET propagates here too: alloc_method is not null on every
-- run, the free ones included. fn_allocate_freight is deliberately NOT called — on this route it
-- writes nothing, and calling it would imply a cost model BR11 says does not exist (Seam 6).
--
-- THE RETRY IS CHECKED BEFORE ANY STOCK IS READ. A replay of an allocation that emptied its
-- group would otherwise be refused NOT_IN_CENTRAL_STOCK by its own first call's success (TC-36).
--
-- lots.state IS NOT TOUCHED (ADR-026, closed by v0.2 M4 "Lot เดียวกระจายหลายสาขาได้โดยแยก
-- สถานที่และสถานะสต็อก"). The lot stays CENTRAL_STOCK; v_stock_balance carries the split (TC-33a).
--
-- L1 only. can_receive_central grants the central intake and nothing else (BR12).
--
-- Covered by supabase/tests/movement_test.sql (TC-29 ... TC-38, TC-46, TC-47) and
-- movement_concurrency_test.sh (TC-35).

create or replace function public.fn_allocate_to_branch(
  p_idempotency_key      uuid,
  p_branch_location_id   uuid,
  p_event_date           date,
  p_smoke_date_group_id  uuid,
  p_dispatched_weight_kg numeric,
  p_bag_count            integer,
  p_fifo_override_reason text default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_line    transport_lines;
  v_kind    location_kind;
  v_pick    record;
  v_oldest  date;
  v_reason  text;
  v_run     uuid;
  v_line_id uuid;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- ^fix-numeric-scale: a third decimal is refused by name, not rounded by the column.
  perform fn_require_two_decimals('p_dispatched_weight_kg', p_dispatched_weight_kg);

  perform fn_require_owner();

  ------------------------------------------------------------------------- the retry check
  select * into v_line from transport_lines where idempotency_key = p_idempotency_key;
  if found then
    if v_line.to_location_id = p_branch_location_id
       and v_line.smoke_date_group_id = p_smoke_date_group_id
       and v_line.dispatched_weight_kg = p_dispatched_weight_kg
       and v_line.bag_count = p_bag_count
       and (select event_date from transport_runs where id = v_line.run_id) = p_event_date then
      return v_line.id;
    end if;
    raise exception 'LINE_IDEMPOTENCY_CONFLICT: key % was used for a different line',
      p_idempotency_key;
  end if;

  if p_bag_count is null or p_bag_count < 1 then
    raise exception 'BAG_COUNT_REQUIRED: an allocation records the bags loaded as well as the weight (v0.2:108), got %',
      coalesce(p_bag_count::text, 'none');
  end if;

  if p_dispatched_weight_kg is null or p_dispatched_weight_kg <= 0 then
    raise exception 'DISPATCH_WEIGHT_INVALID: dispatched_weight_kg must be > 0, got %',
      p_dispatched_weight_kg;
  end if;

  if p_smoke_date_group_id is null then
    raise exception 'SMOKE_GROUP_REQUIRED: an allocation names the smoke-date group it draws from (R21/ADR-017)';
  end if;

  select kind into v_kind from locations where id = p_branch_location_id;
  if not found then
    raise exception 'LOCATION_NOT_FOUND: no location %', p_branch_location_id;
  end if;
  if v_kind <> 'BRANCH' then
    raise exception 'NOT_A_BRANCH: % is a % location; allocation sends central stock to a branch (BR11)',
      p_branch_location_id, v_kind;
  end if;

  ------------------------------------------------------------------ BR11: central stock only
  select * into v_pick from v_central_available where smoke_date_group_id = p_smoke_date_group_id;
  if not found then
    raise exception 'NOT_IN_CENTRAL_STOCK: smoke-date group % has no frozen stock at central; nothing reaches a branch without passing through central first (BR11)',
      p_smoke_date_group_id;
  end if;
  if v_pick.available_qty < p_dispatched_weight_kg then
    raise exception 'INSUFFICIENT_CENTRAL_STOCK: lot % smoked % has % kg at central, % kg requested',
      v_pick.lot_code, v_pick.smoke_date, v_pick.available_qty, p_dispatched_weight_kg;
  end if;

  -------------------------------------------------------------------- BR07: FIFO by smoke date
  select min(smoke_date) into v_oldest from v_central_available;
  if v_pick.smoke_date > v_oldest then
    v_reason := nullif(btrim(p_fifo_override_reason), '');
    if v_reason is null then
      raise exception 'FIFO_OVERRIDE_REASON_REQUIRED: central still holds smoke date %; allocating % first needs a reason (BR07)',
        v_oldest, v_pick.smoke_date;
    end if;
  end if;

  ------------------------------------------------------------------------------- the run
  perform pg_advisory_xact_lock(hashtextextended(
    'branch_run|' || p_branch_location_id::text || '|' || coalesce(p_event_date::text, ''), 0));

  select r.id into v_run
    from transport_runs r
   where r.route = 'CENTRAL_TO_BRANCH'
     and r.event_date = p_event_date
     and exists (select 1 from transport_lines t
                  where t.run_id = r.id and t.to_location_id = p_branch_location_id)
   order by r.created_at
   limit 1;

  if v_run is null then
    v_run := fn_create_transport_run(md5(p_idempotency_key::text || ':run')::uuid,
                                     'CENTRAL_TO_BRANCH', p_event_date, p_run_cost_thb => 0);
  end if;

  v_line_id := fn_dispatch_transport_line(p_idempotency_key, v_run, v_pick.lot_id,
                                          p_smoke_date_group_id, v_pick.location_id,
                                          p_branch_location_id, p_dispatched_weight_kg);

  update transport_lines
     set bag_count = p_bag_count, fifo_override_reason = v_reason
   where id = v_line_id;

  return v_line_id;
end $$;

revoke execute on function public.fn_allocate_to_branch(uuid, uuid, date, uuid, numeric, integer, text) from public, anon, authenticated;
grant  execute on function public.fn_allocate_to_branch(uuid, uuid, date, uuid, numeric, integer, text) to authenticated;
