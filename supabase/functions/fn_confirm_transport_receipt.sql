-- Card ^ref-22 — fn_confirm_transport_receipt. The receiving side signs for what actually
-- arrived (D06, UAT-11, BR12, R22).
--
-- A PARTIAL RECEIPT IS NOT AN ERROR. 40 kg went out, 30 kg came in: the line is accepted,
-- outstanding_weight_kg follows the generated column to 10, and 10 kg stays sitting in
-- IN_TRANSIT at the destination. That is the honest state — the meat is neither here nor
-- written off, and writing off the shortfall is a decision variance_settlement records and
-- F8 makes. partial_receipt_allowed (config, global or per branch) decides whether the
-- shortfall may be recorded at all; when it is false, a short receipt raises.
--
-- THE TRANSFER_IN IS THE RECEIVED WEIGHT, NOT THE DISPATCHED ONE. Posting the dispatched
-- weight would zero IN_TRANSIT and conjure 10 kg into the destination's stock, which is the
-- single most attractive shortcut in this function. The one exception is an over-delivery,
-- where the truck cannot be cleared of more than went onto it — see the ledger section.
--
-- MODE IS ALERT, NOT BLOCK. A receipt is a fact that already happened, and refusing to
-- record it does not make the meat reappear. UAT-11 asks for a reason, not a refusal — so
-- the variance is checked, a reason is demanded past threshold when the Owner has the toggle
-- on, and the row is then written.
--
-- THE VERDICT COMES FROM fn_check_variance AND NEVER FROM transport_lines.variance_pct
-- (ADR-019, R22, Seam 4). The generated column rounds to 4 decimals and compares raw; the
-- function rounds to 2 and then compares. At a 20% threshold they disagree on a line that is
-- 20.004% off. One line cannot have two verdicts, so the function wins here and in the
-- views, and TC-21 pins the disagreement so nobody "simplifies" a view onto the column.
--
-- The threshold is fn_config_numeric('receipt_variance_threshold_pct', p_event_date), which
-- closes Open Question 4 of TDD-transport.md — that key does exist, is Confirmed at 20.00,
-- and API_DATA_MODEL.md's fn_check_variance row names ^ref-22 as one of the two call sites
-- expected to pass it in. The function's own 20.00 default is never relied on: it takes no
-- event date, and a dated rate resolved without one is what R12 forbids.
--
-- p_event_date IS A PARAMETER, WHICH THE PLAN'S SIGNATURE DID NOT HAVE. The run's event_date
-- is the DISPATCH date; a receipt happens days later. Three things need the receipt's own
-- date and would otherwise silently use the dispatch's: the ledger row's business_date, and
-- both config lookups, which resolve by event date under R12/BR23. now() is not an option —
-- R12 forbids exactly that, and ADR-014's business day is not derivable here because a
-- transport receipt has no shift.
--
-- ROLE COMES FROM THE DESTINATION, NOT FROM AN ARGUMENT. A caller who names their own role
-- picks it. CHEF_HOUSE is L3 and must be assigned to that location; BRANCH goes through
-- fn_require_branch, so an L2 of one branch cannot sign for another's; CENTRAL is L1 or a
-- can_receive_central delegate through fn_require_central_receiver (^ref-35, R27, BR12). It
-- was L1-only at ^ref-22; the delegate signs for central and gains no read scope with it.
--
-- TWO MEASURED DIMENSIONS, ONE REASON (^ref-35, v0.2:89). BR 02 receives "น้ำหนักจริง
-- จำนวนถุง และเหตุผลเมื่อไม่ตรง": a bag-count mismatch demands the same reason a weight past
-- threshold does. Ten bags out, nine in at 19.5 kg is 2.5% off by weight and sails through a
-- weight-only check — and a whole bag is never cut (v0.2:108), so a bag short is a bag
-- somewhere else. Null on either side is NOT COUNTED, never zero bags: no FOODIVA_TO_CM or
-- CM_TO_FOODIVA line carries a count, and a coalesce(..., 0) would demand a reason for every
-- return leg a receiver counted (TC-44). Still ALERT: the count is stored, the stock stays kg.
--
-- THE RETURN LEG'S LOT TRANSITION LIVES HERE (^ref-35, Finding 3, Seam 2): a CM_TO_FOODIVA
-- line received into CENTRAL moves its lot RETURN_SCHEDULED -> CENTRAL_STOCK.
-- fn_dispatch_transport_line leaves it to the receipt, and it is not in
-- fn_confirm_central_intake because both functions are granted to authenticated — an L1
-- calling this one directly would otherwise receive the meat and leave the lot behind.
--
-- THE SECOND KEY. A line is written twice by two different callers, so it carries two keys
-- (migration ...0010). The receipt's own key lands in receipt_idempotency_key under
-- `select ... for update`, which is what makes two concurrent receipts resolve to one winner
-- and one named refusal rather than two TRANSFER_IN rows (TC-41).
--
-- Covered by supabase/tests/transport_test.sql (TC-19 ... TC-28) and, for TC-41,
-- supabase/tests/transport_concurrency_test.sh; the ^ref-35 half by movement_test.sql (TC-23,
-- TC-43 ... TC-45).

-- ^ref-35 appended p_received_bag_count. `create or replace` with a longer argument list makes
-- a SECOND function beside the old one, and every six-argument call is then ambiguous between
-- them — so the old signature is dropped by name first. Re-appliable: the second time round
-- there is nothing to drop.
drop function if exists public.fn_confirm_transport_receipt(uuid, uuid, date, numeric, text, text);

create or replace function public.fn_confirm_transport_receipt(
  p_idempotency_key     uuid,
  p_line_id             uuid,
  p_event_date          date,
  p_received_weight_kg  numeric,
  p_variance_reason     text    default null,
  p_variance_settlement text    default null,
  p_received_bag_count  integer default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor     uuid;
  v_line      transport_lines;
  v_kind      location_kind;
  v_route     transport_route;
  v_bags_off  boolean;
  v_threshold numeric;
  v_pct       numeric;
  v_verdict   text;
  v_needs     boolean;
  v_partial   boolean;
  v_cleared   numeric(12,2);
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- ^fix-numeric-scale: a third decimal is refused by name, not rounded by the column.
  perform fn_require_two_decimals('p_received_weight_kg', p_received_weight_kg);

  if p_event_date is null then
    raise exception 'RECEIPT_EVENT_DATE_REQUIRED: the receipt resolves its own config by its own date, never now() (R12)';
  end if;

  if p_received_weight_kg is null or p_received_weight_kg < 0 then
    raise exception 'RECEIPT_WEIGHT_INVALID: received_weight_kg must be >= 0, got %',
      p_received_weight_kg;
  end if;

  if p_received_bag_count < 1 then
    raise exception 'RECEIPT_BAG_COUNT_INVALID: received_bag_count is a count of bags that arrived, got %',
      p_received_bag_count;
  end if;

  -- Locked before the retry is even asked, unlike the dispatch. A dispatch replay competes
  -- with nothing; two receipts compete for one row, and the row is what they compete for.
  select * into v_line from transport_lines where id = p_line_id for update;
  if not found then
    raise exception 'LINE_NOT_FOUND: no transport line %', p_line_id;
  end if;

  if v_line.receipt_idempotency_key = p_idempotency_key then
    -- A replay. Looks exactly like the first call succeeded: same id, no second write, no
    -- second TRANSFER_IN (R4).
    return v_line.id;
  end if;

  if v_line.receipt_idempotency_key is not null then
    raise exception 'LINE_ALREADY_RECEIVED: line % was signed for on %, with a different key',
      p_line_id, v_line.received_at;
  end if;

  ------------------------------------------------------------------ who may sign for this
  select kind into v_kind from locations where id = v_line.to_location_id;
  if not found then
    raise exception 'LOCATION_NOT_FOUND: line % has no destination location', p_line_id;
  end if;

  if v_kind = 'BRANCH' then
    v_actor := fn_require_branch(v_line.to_location_id);
  elsif v_kind = 'CENTRAL' then
    v_actor := fn_require_central_receiver();
  else
    -- CHEF_HOUSE. Actor first, for fn_require_owner's reason: fn_current_role() folds in
    -- is_active and goes null for a deactivated operator holding a live token, who would
    -- otherwise be reported as merely forbidden.
    select id into v_actor from profiles where id = auth.uid() and is_active;
    if v_actor is null then
      raise exception 'NO_ACTOR: the caller has no active profile (R31)';
    end if;
    if fn_current_role() <> 'L3_CM_OPERATOR' then
      raise exception 'FORBIDDEN: a CHEF_HOUSE receipt is signed by the CM operator (ADR-004)';
    end if;
    if v_line.to_location_id <> all (fn_current_locations()) then
      raise exception 'FORBIDDEN_LOCATION: the caller is not assigned to location %',
        v_line.to_location_id;
    end if;
  end if;

  ----------------------------------------------------------------------------- D06 / UAT-11
  if p_received_weight_kg < v_line.dispatched_weight_kg then
    v_partial := fn_config_boolean('partial_receipt_allowed', p_event_date, v_line.to_location_id);
    if not v_partial then
      raise exception 'PARTIAL_RECEIPT_NOT_ALLOWED: % kg against % kg dispatched, and partial receipt is off for this location (D06)',
        p_received_weight_kg, v_line.dispatched_weight_kg;
    end if;
  end if;

  v_threshold := fn_config_numeric('receipt_variance_threshold_pct', p_event_date);
  select variance_pct, verdict
    into v_pct, v_verdict
    from fn_check_variance(p_received_weight_kg, v_line.dispatched_weight_kg, 'ALERT', v_threshold);

  -- Null on either side is "not counted", so the comparison is null and reads as agreement.
  v_bags_off := coalesce(p_received_bag_count <> v_line.bag_count, false);

  if v_verdict <> 'WITHIN' or v_bags_off then
    v_needs := fn_config_boolean('receipt_variance_requires_reason', p_event_date);
    if v_needs and coalesce(btrim(p_variance_reason), '') = '' then
      if v_verdict <> 'WITHIN' then
        raise exception 'VARIANCE_REASON_REQUIRED: % kg against % kg dispatched is %%% off, past a tolerance of %%% (UAT-11, BR12)',
          p_received_weight_kg, v_line.dispatched_weight_kg, coalesce(v_pct::text, 'an unmeasurable'), v_threshold;
      end if;
      raise exception 'VARIANCE_REASON_REQUIRED: % bag(s) counted against % loaded; a whole bag is never cut, so the difference is somewhere else (BR 02, v0.2:89)',
        p_received_bag_count, v_line.bag_count;
    end if;
  end if;

  update transport_lines
     set received_weight_kg      = p_received_weight_kg,
         received_by             = v_actor,
         received_at             = now(),
         variance_reason         = p_variance_reason,
         variance_settlement     = p_variance_settlement,
         received_bag_count      = p_received_bag_count,
         receipt_idempotency_key = p_idempotency_key
   where id = p_line_id;

  ------------------------------------------------------------------------------ the ledger
  -- Nothing arrived: the line is signed for at zero and the whole dispatch stays
  -- outstanding in IN_TRANSIT. No ledger rows, because stock_ledger.qty_delta carries
  -- `check (qty_delta <> 0)` and a zero movement is not a movement.
  v_cleared := least(p_received_weight_kg, v_line.dispatched_weight_kg);

  if v_cleared > 0 then
    -- Off the truck. The caller's own key, so a replay finds it committed (Seam 2).
    --
    -- least(), NOT the received weight. On an over-delivery the truck brought more than the
    -- note said, and IN_TRANSIT only ever held the dispatched weight — drawing 45 out of a
    -- 40 kg tuple is refused by fn_post_ledger's non-negative guard (R3, BR24), correctly.
    -- What clears the truck is what went onto it.
    perform fn_post_ledger(
      p_idempotency_key     => p_idempotency_key,
      p_item_type           => 'SMOKED_MEAT',
      p_location_id         => v_line.to_location_id,
      p_stock_state         => 'IN_TRANSIT',
      p_movement_type       => 'TRANSFER_IN',
      p_qty_delta           => -v_cleared,
      p_business_date       => p_event_date,
      p_lot_id              => v_line.lot_id,
      p_smoke_date_group_id => v_line.smoke_date_group_id,
      p_source_table        => 'transport_lines',
      p_source_id           => v_line.id);

    -- And onto the shelf. FROZEN is the at-rest state for smoked meat: R14 moves weight
    -- FROZEN -> READY at the branch and a sale deducts READY only, so arriving stock that
    -- landed in READY would leave THAW_OUT with nothing to draw from.
    perform fn_post_ledger(
      p_idempotency_key     => md5(p_idempotency_key::text || ':in')::uuid,
      p_item_type           => 'SMOKED_MEAT',
      p_location_id         => v_line.to_location_id,
      p_stock_state         => 'FROZEN',
      p_movement_type       => 'TRANSFER_IN',
      p_qty_delta           => v_cleared,
      p_business_date       => p_event_date,
      p_lot_id              => v_line.lot_id,
      p_smoke_date_group_id => v_line.smoke_date_group_id,
      p_source_table        => 'transport_lines',
      p_source_id           => v_line.id);
  end if;

  -- THE OVERAGE IS AN ADJUSTMENT, NOT A TRANSFER. 45 kg arriving against a 40 kg note is 5
  -- kg of real meat on a real shelf that no transfer accounts for, and calling it TRANSFER_IN
  -- would make the ledger say 5 kg travelled from a truck that never carried it. ADJUSTMENT
  -- is the movement_type that exists for a quantity nobody moved, it carries the receiver's
  -- reason, and it is what F8's settlement reads when it closes the gap (D06, UAT-11).
  --
  -- Refusing the receipt instead is not an option: the meat is here, and a line that cannot
  -- be signed for is a line somebody signs for at the wrong weight.
  if p_received_weight_kg > v_line.dispatched_weight_kg then
    perform fn_post_ledger(
      p_idempotency_key     => md5(p_idempotency_key::text || ':adj')::uuid,
      p_item_type           => 'SMOKED_MEAT',
      p_location_id         => v_line.to_location_id,
      p_stock_state         => 'FROZEN',
      p_movement_type       => 'ADJUSTMENT',
      p_qty_delta           => p_received_weight_kg - v_line.dispatched_weight_kg,
      p_business_date       => p_event_date,
      p_lot_id              => v_line.lot_id,
      p_smoke_date_group_id => v_line.smoke_date_group_id,
      p_source_table        => 'transport_lines',
      p_source_id           => v_line.id,
      p_reason              => coalesce(p_variance_reason,
                                        'over-delivery against the dispatch note'));
  end if;

  -- The return leg's lot transition (header). On the first receipt of any line on the run that
  -- brought meat, partial or not: the lot IS at central, and how much of it is still on the
  -- truck is v_outstanding_receipts' question and the ledger's answer (ADR-026). A receipt of
  -- nothing leaves it where it was — none of it is central stock. Later lines of the same lot
  -- find it already moved and change nothing.
  select route into v_route from transport_runs where id = v_line.run_id;
  if v_route = 'CM_TO_FOODIVA' and v_kind = 'CENTRAL' and p_received_weight_kg > 0 then
    update lots set state = 'CENTRAL_STOCK'
     where id = v_line.lot_id and state = 'RETURN_SCHEDULED';
  end if;

  return v_line.id;
end $$;

revoke execute on function public.fn_confirm_transport_receipt(uuid, uuid, date, numeric, text, text, integer) from public, anon, authenticated;
grant  execute on function public.fn_confirm_transport_receipt(uuid, uuid, date, numeric, text, text, integer) to authenticated;
