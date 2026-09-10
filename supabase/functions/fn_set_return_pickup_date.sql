-- Card ^ref-34 — fn_set_return_pickup_date. OW 05: somebody entitled to do so names the day the
-- truck collects a closed lot, and only then may a return run exist (BR17, R26, C02).
--
-- THIS IS THE GATE, AND ^ref-22 ALREADY ENFORCES IT. fn_create_transport_run refuses a
-- CM_TO_FOODIVA run unless every lot on it is RETURN_SCHEDULED; this function is the only thing
-- that puts a lot there. Closing a lot creates no transport job (BR17, ADR-015) — the chain is
-- close → this → run → dispatch → central receipt (TDD-movement.md Seam 3).
--
-- WHO: L1 or a can_receive_central delegate, through fn_require_central_receiver. ADR-013 makes
-- a closed lot Owner-only from the start; BR17 is the one door it opens, and only for this.
--
-- lots, NOT A CHILD TABLE. fn_guard_lot_closed fires on the five production child tables and
-- not on lots (PLAN-movement.md Finding 8), so a closed lot refuses a new smoke log and accepts
-- a pickup date. No lots trigger may be added to "protect" the closed lot from this write
-- (TC-12 pins the boundary).
--
-- IDEMPOTENCY RIDES THE NATURAL KEY (R38): (lot, date). The date that already stands returns
-- the lot and writes nothing — checked BEFORE the dispatch refusal, so a retry that lands
-- after the truck left is still a retry. A different date is a reschedule, an ordinary
-- business event R32's trigger audits with both values; once a return line exists it is
-- RETURN_ALREADY_DISPATCHED, because the run was created against the old date (R29's
-- principle). The key is required and not stored.
--
-- The pickup date may equal the close date (same-day collection is ordinary) and may not
-- precede it. An opening lot has no closed_at, so that comparison is null and passes: ^ref-62
-- creates it at LOT_CLOSED, and one counted at the chef house on go-live day needs a truck too.
--
-- WRITES NOTHING TO stock_ledger. A pickup date is a commitment, like a PO; stock moves at
-- fn_dispatch_transport_line (TC-19).
--
-- Covered by supabase/tests/movement_test.sql (TC-11 ... TC-19).

create or replace function public.fn_set_return_pickup_date(
  p_idempotency_key    uuid,
  p_lot_id             uuid,
  p_return_pickup_date date
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_lot   lots;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- NO_ACTOR, FORBIDDEN.
  v_actor := fn_require_central_receiver();

  select * into v_lot from lots where id = p_lot_id for update;
  if not found then
    raise exception 'LOT_NOT_FOUND: no lot %', p_lot_id;
  end if;

  -- The enum's declaration order is the lifecycle, the mechanism fn_guard_lot_closed uses.
  if v_lot.state < 'LOT_CLOSED' then
    raise exception 'LOT_NOT_CLOSED: lot % is at %; the wait for a pickup starts at close (BR17)',
      v_lot.lot_code, v_lot.state;
  end if;

  if p_return_pickup_date is null then
    raise exception 'RETURN_PICKUP_DATE_REQUIRED: name the day the truck collects lot %', v_lot.lot_code;
  end if;

  if p_return_pickup_date < v_lot.closed_at::date then
    raise exception 'RETURN_PICKUP_DATE_INVALID: lot % closed on %, and a pickup cannot come before it',
      v_lot.lot_code, v_lot.closed_at::date;
  end if;

  if v_lot.return_pickup_date = p_return_pickup_date then
    return p_lot_id;
  end if;

  -- Past RETURN_SCHEDULED is only reachable by a return line, but the state test also stops
  -- this update from ever moving a lot backwards.
  if v_lot.state > 'RETURN_SCHEDULED' or exists (
       select 1 from transport_lines tl
         join transport_runs tr on tr.id = tl.run_id
        where tl.lot_id = p_lot_id and tr.route = 'CM_TO_FOODIVA') then
    raise exception 'RETURN_ALREADY_DISPATCHED: lot % is already on a return truck, booked for % (R29)',
      v_lot.lot_code, v_lot.return_pickup_date;
  end if;

  update lots
     set return_pickup_date   = p_return_pickup_date,
         return_pickup_set_by = v_actor,
         state                = 'RETURN_SCHEDULED'
   where id = p_lot_id;

  return p_lot_id;
end $$;

revoke execute on function public.fn_set_return_pickup_date(uuid, uuid, date) from public, anon, authenticated;
grant  execute on function public.fn_set_return_pickup_date(uuid, uuid, date) to authenticated;
