-- Card ^ref-22 — fn_dispatch_transport_line. The sending side declares a weight, and that
-- is the moment meat first exists in stock_ledger (R21, ADR-017, D01).
--
-- WHERE THE IN_TRANSIT TUPLE SITS, AND WHY IT IS THE DESTINATION. fn_post_ledger groups a
-- balance by (item_type, product_id, packaging_item_id, lot_id, smoke_date_group_id,
-- location_id, stock_state). IN_TRANSIT is a stock_state, not a location, so an in-transit
-- tuple is still AT a location and the only question is which one. It is the destination,
-- because "what is coming to me" is a question asked by the receiving side, and R34 scopes
-- every view by fn_current_locations(). Park it at the origin and the chef house cannot see
-- its own inbound load without a grant to read somebody else's location, which is where
-- ADR-004 starts coming apart.
--
-- Get this wrong and every balance stays plausible: the chef house shows meat it does not
-- have, or the origin shows meat it has already sent, and both reconcile internally.
-- TC-14 and TC-15 are the only things that catch it.
--
-- THE OUTBOUND LEG HAS NO ORIGIN ROW, AND THIS IS NOT AN OMISSION. location_kind is
-- CENTRAL, CHEF_HOUSE or BRANCH — there is no SUPPLIER kind and Foodiva has no locations
-- row, so on a FOODIVA_TO_CM run from_location_id is null and there is no balance anywhere
-- to draw down. fn_add_po_delivery says it in its own header: it writes nothing to the
-- ledger, and "stock enters at fn_dispatch_transport_line". So this leg posts ONE row, the
-- +IN_TRANSIT at the destination, and the meat enters the books on the truck. TDD-transport
-- TC-14 assumed a Foodiva location and a READY balance to take 40 kg off; there is neither,
-- and the corrected test asserts the absence rather than the draw.
--
-- The legs that DO have an origin — CM_TO_FOODIVA out of the chef house, CENTRAL_TO_BRANCH
-- out of central — post two rows, and the origin is drawn down from FROZEN. FROZEN is the
-- at-rest state for smoked meat: R14 is explicit that thawing moves weight FROZEN -> READY
-- at the branch and that a sale deducts READY only. TDD-transport's TC-14/TC-19 say READY,
-- which would put arriving stock straight into the state R14 reserves for meat a branch has
-- already thawed, and no THAW_OUT would ever have anything to draw from.
--
-- THE RETRY IS IDEMPOTENT AT BOTH LEVELS (Seam 2). The line row and the ledger rows are
-- keyed separately, and if this function minted a fresh key for the ledger call, a replay
-- would skip the line insert on its unique index and then post the ledger rows AGAIN,
-- because the ledger has never seen that second key. 40 kg becomes 80 kg in IN_TRANSIT
-- against a lot that can then never balance. So the caller's key IS the transit row's key,
-- and the origin row — which exists on only two of the three routes — derives its own
-- deterministically from it. Never gen_random_uuid(). TC-17 is the only test that can catch
-- this and it has to run the whole function twice, not just the insert.
--
-- lot_state advances to IN_TRANSIT on the outbound leg only. On CM_TO_FOODIVA the
-- transition belongs to fn_confirm_central_intake (^ref-35): setting it here would make the
-- lot read as received before the truck had arrived.
--
-- L1 per API_DATA_MODEL.md's RPC table. CENTRAL_TO_BRANCH lines are created by
-- fn_allocate_to_branch (^ref-36), which calls this rather than posting its own ledger rows
-- — one writer for the IN_TRANSIT tuple, or there are two implementations of Seam 1.
--
-- Covered by supabase/tests/transport_test.sql (TC-13 ... TC-18).

create or replace function public.fn_dispatch_transport_line(
  p_idempotency_key     uuid,
  p_run_id              uuid,
  p_lot_id              uuid,
  p_smoke_date_group_id uuid,
  p_from_location_id    uuid,
  p_to_location_id      uuid,
  p_dispatched_weight_kg numeric
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor   uuid;
  v_line    transport_lines;
  v_run     transport_runs;
  v_kind    location_kind;
  v_line_id uuid;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  v_actor := fn_require_owner();

  -- R21 / ADR-017, said here rather than left to the NOT NULL constraint. fn_post_ledger
  -- raises the same code, but the line insert would hit transport_lines.lot_id NOT NULL
  -- first and report a constraint name to somebody entitled to be told the rule (TC-16).
  if p_lot_id is null then
    raise exception 'LOT_REQUIRED: a SMOKED_MEAT movement must name its lot (R21/D01)';
  end if;

  if p_dispatched_weight_kg is null or p_dispatched_weight_kg <= 0 then
    raise exception 'DISPATCH_WEIGHT_INVALID: dispatched_weight_kg must be > 0, got %',
      p_dispatched_weight_kg;
  end if;

  ------------------------------------------------------------------------- the retry check
  -- Before anything is locked, so a replay does not queue behind a live dispatch.
  select * into v_line from transport_lines where idempotency_key = p_idempotency_key;
  if found then
    if v_line.run_id = p_run_id
       and v_line.lot_id = p_lot_id
       and v_line.dispatched_weight_kg = p_dispatched_weight_kg
       and v_line.to_location_id is not distinct from p_to_location_id
       and v_line.from_location_id is not distinct from p_from_location_id
       and v_line.smoke_date_group_id is not distinct from p_smoke_date_group_id then
      return v_line.id;
    end if;
    raise exception 'LINE_IDEMPOTENCY_CONFLICT: key % was used for a different line',
      p_idempotency_key;
  end if;

  select * into v_run from transport_runs where id = p_run_id;
  if not found then
    raise exception 'RUN_NOT_FOUND: no transport run %', p_run_id;
  end if;

  if not exists (select 1 from lots where id = p_lot_id) then
    raise exception 'LOT_NOT_FOUND: no lot %', p_lot_id;
  end if;

  ------------------------------------------------------------- where the meat is going, and from
  if p_to_location_id is null then
    raise exception 'DESTINATION_REQUIRED: the IN_TRANSIT tuple is held at the destination, which must be a real location';
  end if;

  select kind into v_kind from locations where id = p_to_location_id;
  if not found then
    raise exception 'LOCATION_NOT_FOUND: no location %', p_to_location_id;
  end if;

  -- Foodiva is a supplier, not a location: location_kind has no SUPPLIER value. An origin
  -- id on the outbound leg would have to name one of our own locations, and meat cannot
  -- leave a place it has never been (see the header).
  if v_run.route = 'FOODIVA_TO_CM' and p_from_location_id is not null then
    raise exception 'ORIGIN_LOCATION_INVALID: a FOODIVA_TO_CM line has no origin location — the supplier is not one of ours';
  end if;

  if v_run.route <> 'FOODIVA_TO_CM' and p_from_location_id is null then
    raise exception 'ORIGIN_REQUIRED: a % line leaves one of our own locations and must name it',
      v_run.route;
  end if;

  insert into transport_lines (run_id, lot_id, smoke_date_group_id, from_location_id,
                               to_location_id, dispatched_weight_kg, idempotency_key)
  values (p_run_id, p_lot_id, p_smoke_date_group_id, p_from_location_id,
          p_to_location_id, p_dispatched_weight_kg, p_idempotency_key)
  returning id into v_line_id;

  ------------------------------------------------------------------------------ the ledger
  -- The origin draw, where there is an origin. Derived key, never gen_random_uuid(): a
  -- replay must find this exact row already committed (Seam 2).
  if p_from_location_id is not null then
    perform fn_post_ledger(
      p_idempotency_key     => md5(p_idempotency_key::text || ':out')::uuid,
      p_item_type           => 'SMOKED_MEAT',
      p_location_id         => p_from_location_id,
      p_stock_state         => 'FROZEN',
      p_movement_type       => 'TRANSFER_OUT',
      p_qty_delta           => -p_dispatched_weight_kg,
      p_business_date       => v_run.event_date,
      p_lot_id              => p_lot_id,
      p_smoke_date_group_id => p_smoke_date_group_id,
      p_source_table        => 'transport_lines',
      p_source_id           => v_line_id);
  end if;

  -- The transit row, on every route, carrying the caller's own key.
  perform fn_post_ledger(
    p_idempotency_key     => p_idempotency_key,
    p_item_type           => 'SMOKED_MEAT',
    p_location_id         => p_to_location_id,
    p_stock_state         => 'IN_TRANSIT',
    p_movement_type       => 'TRANSFER_OUT',
    p_qty_delta           => p_dispatched_weight_kg,
    p_business_date       => v_run.event_date,
    p_lot_id              => p_lot_id,
    p_smoke_date_group_id => p_smoke_date_group_id,
    p_source_table        => 'transport_lines',
    p_source_id           => v_line_id);

  -- BR17 / the lot lifecycle. Outbound only; ^ref-35 owns the return leg's transition.
  if v_run.route = 'FOODIVA_TO_CM' then
    update lots set state = 'IN_TRANSIT' where id = p_lot_id and state = 'PO_CREATED';
  end if;

  return v_line_id;

exception
  when unique_violation then
    select * into v_line from transport_lines where idempotency_key = p_idempotency_key;
    if found then
      return v_line.id;
    end if;
    raise;
end $$;

revoke execute on function public.fn_dispatch_transport_line(uuid, uuid, uuid, uuid, uuid, uuid, numeric) from public, anon, authenticated;
grant  execute on function public.fn_dispatch_transport_line(uuid, uuid, uuid, uuid, uuid, uuid, numeric) to authenticated;
