-- Card ^ref-19 — fn_add_po_delivery. One dispatch round, one lot, one transaction (D01).
--
-- THE FAILURE THIS FUNCTION EXISTS TO PREVENT. 100 kg ordered, 40 then 30 sent, is two
-- lots, 70 sent and 30 outstanding. Anyone who types 100 into a lot has produced a loss
-- percentage against a weight that never moved, and nothing downstream can tell. So
-- cumulative sent and outstanding are derived from these rows by v_po_outstanding, never
-- stored and never re-typed (D01, UAT-01, F4 clause 3).
--
-- THE ROUND AND ITS LOT ARE ONE WRITE. lots.po_delivery_id is NOT NULL UNIQUE, so a round
-- without a lot is a row the schema permits and D01 forbids. There is no fn_create_lot in
-- API_DATA_MODEL.md's RPC table and there must not be one — it would be the only way to
-- produce that orphan. This function returns the LOT id, not the round id, because the lot
-- is what every later card joins to: transport lines, receipts, smoke logs, yield, cost.
--
-- foodiva_sent_weight_kg is copied onto the lot at creation and frozen there. That copy is
-- the denominator in BR03 and in every yield figure the system will ever show (R16, and
-- ADR-011: the divisor is the Foodiva dispatch weight, never the Chiang Mai received one).
-- TC-14 asserts the two match, so it is a fact rather than a convention.
--
-- THE OVERSHOOT CHECK LOCKS THE PO ROW. Read-sum-insert is a race — two rounds of 60 kg
-- against a 100 kg PO each fit alone and must not both commit. fn_post_ledger takes an
-- advisory lock because the thing it guards, a balance, has no row to lock; a PO is a row,
-- so `for update` on it is the same guarantee with less to get wrong (TC-20). seq is
-- derived under that same lock.
--
-- Measured, not assumed: with the lock deleted, purchasing_concurrency_test.sh shows the
-- second session dying on `po_deliveries_po_id_seq_key` rather than committing 120 kg —
-- seq is derived from the same rows the overshoot check sums, so two concurrent callers
-- always compute the same seq and that unique index serialises them by accident. It is a
-- real second guard and worth knowing about. What the lock buys on top of it is the
-- refusal being LEGIBLE: PO_OVERDELIVERY naming the weights, instead of a constraint name
-- reaching an Owner who was entitled to be told their round was 20 kg too big.
--
-- The boundary is `>`, not `>=`: cumulative exactly equal to ordered_weight_kg is a fully
-- delivered PO, not an over-delivery (TC-18). Same class of decision as R16's yield
-- boundary, written down for the same reason.
--
-- seq is derived, never a parameter. A caller that can choose seq can reorder the rounds,
-- and the round order is what v_po_outstanding and every FIFO view downstream read (TC-16).
--
-- NOTHING HERE TOUCHES stock_ledger. A booked round is a plan; the meat has not moved.
-- Stock enters at fn_dispatch_transport_line (^ref-22, F5) as TRANSFER_OUT into IN_TRANSIT.
-- TC-25 asserts the ledger count is unchanged, because this is the tempting mistake: the
-- lot exists here and its weight is known here.
--
-- Neither po_deliveries nor lots carries created_by, and neither needs one: ^ref-06's
-- generic audit trigger writes an audit_log row for both inserts in this same transaction
-- with actor_id resolved from auth.uid() (R32). A created_by column would be a second copy
-- of that fact, able to disagree with it.
--
-- Covered by supabase/tests/purchasing_test.sql (TC-13 ... TC-26) and, for TC-20,
-- supabase/tests/purchasing_concurrency_test.sh.

create or replace function public.fn_add_po_delivery(
  p_idempotency_key        uuid,
  p_po_id                  uuid,
  p_event_date             date,
  p_foodiva_sent_weight_kg numeric,
  p_chef_house_location_id uuid,
  p_note                   text default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor     uuid;
  v_kind      location_kind;
  v_del       po_deliveries;
  v_po_number text;
  v_ordered   numeric(12,2);
  v_sent      numeric(12,2);
  v_seq       integer;
  v_del_id    uuid;
  v_lot_id    uuid;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  v_actor := fn_require_owner();

  if p_event_date is null then
    raise exception 'DELIVERY_EVENT_DATE_REQUIRED: an undated round cannot be resolved by event date (R12)';
  end if;

  if p_foodiva_sent_weight_kg is null or p_foodiva_sent_weight_kg <= 0 then
    raise exception 'DELIVERY_WEIGHT_INVALID: foodiva_sent_weight_kg must be > 0, got %',
      p_foodiva_sent_weight_kg;
  end if;

  -- The lot lands at the chef house and nowhere else. A BRANCH or CENTRAL id here would
  -- create a lot that BR11 says cannot exist — nothing reaches a branch without passing
  -- through central stock first, and it certainly does not arrive there off a truck from
  -- Foodiva. The FK alone would accept it (TC-22).
  select kind into v_kind from locations where id = p_chef_house_location_id;
  if not found then
    raise exception 'LOCATION_NOT_FOUND: no location %', p_chef_house_location_id;
  end if;
  if v_kind <> 'CHEF_HOUSE' then
    raise exception 'LOCATION_KIND_INVALID: a lot is dispatched to a CHEF_HOUSE, got % (BR11)', v_kind;
  end if;

  ------------------------------------------------------------------------- the retry check
  -- Asked before the PO is locked, so a replay does not queue behind a live booking.
  select * into v_del from po_deliveries where idempotency_key = p_idempotency_key;
  if found then
    if v_del.po_id = p_po_id
       and v_del.event_date = p_event_date
       and v_del.foodiva_sent_weight_kg = p_foodiva_sent_weight_kg then
      -- The same lot id both times. A retry has to look exactly like the first call
      -- succeeded, or the client books a second round to "fix" it (R4, TC-23).
      select id into v_lot_id from lots where po_delivery_id = v_del.id;
      return v_lot_id;
    end if;
    raise exception 'DELIVERY_IDEMPOTENCY_CONFLICT: key % was used for a different round',
      p_idempotency_key;
  end if;

  ------------------------------------------------------- lock, sum, then and only then insert
  select po_number, ordered_weight_kg into v_po_number, v_ordered
    from purchase_orders where id = p_po_id
     for update;
  if not found then
    raise exception 'PO_NOT_FOUND: no purchase order %', p_po_id;
  end if;

  select coalesce(sum(foodiva_sent_weight_kg), 0), coalesce(max(seq), 0) + 1
    into v_sent, v_seq
    from po_deliveries where po_id = p_po_id;

  if v_sent + p_foodiva_sent_weight_kg > v_ordered then
    raise exception 'PO_OVERDELIVERY: % kg already sent plus % kg would exceed the % kg ordered on %',
      v_sent, p_foodiva_sent_weight_kg, v_ordered, v_po_number;
  end if;

  insert into po_deliveries (po_id, seq, event_date, foodiva_sent_weight_kg, note, idempotency_key)
  values (p_po_id, v_seq, p_event_date, p_foodiva_sent_weight_kg, p_note, p_idempotency_key)
  returning id into v_del_id;

  -- lot_code is <po_number>-<seq>, so D01 is legible on the code itself and there is no
  -- second counter to keep in step with seq. Owner-facing; an Open Question in
  -- TDD-purchasing.md alongside the po_number format.
  insert into lots (lot_code, po_id, po_delivery_id, foodiva_sent_weight_kg,
                    chef_house_location_id, event_date)
  values (v_po_number || '-' || v_seq, p_po_id, v_del_id, p_foodiva_sent_weight_kg,
          p_chef_house_location_id, p_event_date)
  returning id into v_lot_id;

  -- state takes its default PO_CREATED. Naming it here would put the lifecycle's first
  -- transition in two places, and F5 owns the second one.
  return v_lot_id;

exception
  when unique_violation then
    select * into v_del from po_deliveries where idempotency_key = p_idempotency_key;
    if found then
      select id into v_lot_id from lots where po_delivery_id = v_del.id;
      return v_lot_id;
    end if;
    raise;
end $$;

revoke execute on function public.fn_add_po_delivery(uuid, uuid, date, numeric, uuid, text) from public, anon, authenticated;
grant  execute on function public.fn_add_po_delivery(uuid, uuid, date, numeric, uuid, text) to authenticated;
