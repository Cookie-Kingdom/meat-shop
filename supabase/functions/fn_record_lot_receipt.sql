-- Card ^ref-26 — fn_record_lot_receipt. The chef house signs for what the truck actually
-- brought, and then, on a later afternoon, for what it weighed after draining
-- (CM 02, CM 03, R16a, R38, BR12).
--
-- NEITHER WEIGHT IS EVER A LOSS BASE (R16a, ADR-011). received_weight_kg and
-- post_drain_weight_kg are CROSS-CHECK figures. The loss divisor is
-- lots.foodiva_sent_weight_kg and nothing else: dispatch 100 → CM receives 98 → post-smoke
-- 75 reads 25%, not 23.47%. This function stores both figures and computes no percentage at
-- all, which is the only version of it that cannot get that wrong.
--
-- IT POSTS NO LEDGER ROW, AND THAT IS THE POINT (TC-14, Finding 10). The meat is already in
-- the ledger: fn_confirm_transport_receipt (^ref-22) took the IN_TRANSIT tuple down and put
-- the received weight up as FROZEN at the chef house on the same lot. Posting again here
-- would double the chef house balance. A receipt row is a measurement, not a movement.
--
-- ONE ROW PER LOT, AND THE RETRY RIDES lot_id (R38, Finding 2). lot_receipts.lot_id is
-- unique, so it carries the retry the way ^ref-25's migration records: no idempotency_key
-- column, deliberately, unlike smoke_daily_logs and lot_bags whose natural keys cannot carry
-- one (R39). p_idempotency_key is still required — every write RPC takes one (ADR-005) and a
-- signature that quietly drops it is one the client cannot retry uniformly — it is just not
-- stored, because the natural key already answers the question it would answer.
--
-- SO IT IS AN UPSERT, AND A SECOND CALL IS A CORRECTION RATHER THAN A CONFLICT (Seam 3).
-- CM 02 and CM 03 are two visits to the same row on two different afternoons: the first
-- records what arrived, the second supplies post_drain. A second call with the same payload
-- is therefore indistinguishable from a retry and returns the same id having written the
-- same values — which is what R4 asks for — and a second call with a different payload is
-- the correction the screens are built around. Only the fields the caller actually sent
-- move; a null p_post_drain_weight_kg on the CM 02 call does not erase a post-drain weight
-- recorded earlier, and neither does a null reason.
--
-- POST-DRAIN IS BOUNDED TWICE, ON PURPOSE (Finding 6). ...0013's
-- lot_receipts_post_drain_le_received is what survives a writer added in 2027; the named
-- raise below is what CM 03 can render in Thai, because a check_violation arrives as a
-- constraint name and not as a message anyone can translate. They fail at different layers
-- and only one of them is a message.
--
-- VARIANCE IS ALERT, NEVER BLOCK (CM 02, BR12, ADR-019). The meat weighed what it weighed
-- and refusing to record it does not change the scale. Past threshold, a reason is demanded
-- when the Owner has receipt_variance_requires_reason on — exactly as ^ref-22 does it — and
-- the row is then written. The threshold is receipt_variance_threshold_pct resolved by the
-- receipt's own event date (R12/BR23); fn_check_variance's own 20.00 default is never relied
-- on, because a dated rate resolved without a date is what R12 forbids.
--
-- THE REASON IS THE EFFECTIVE ONE, NOT THE PARAMETER. On the CM 03 visit the caller sends a
-- post-drain weight and no reason, and the same over-threshold received weight is still on
-- the row. Testing p_variance_reason alone would refuse that second call for a variance
-- somebody already explained on the first one.
--
-- p_event_date IS A PARAMETER because both config lookups resolve by it and the row's own
-- event_date is the day the truck arrived, which is not now() and not the lot's event_date
-- (R12). A receipt has no shift, so ADR-014's business day is not derivable here.
--
-- STATE ADVANCES TO CM_RECEIVED AND NO FURTHER. SMOKING is the first daily log's transition
-- (^ref-27) — the meat being on the premises is not the meat being in the smoker.
--
-- THE STATE GUARD IS A FLOOR (^fix-receipt-state-floor). It refuses only a lot that has not
-- left Foodiva, or an opening lot. A closed lot is refused by fn_guard_lot_closed, which lets
-- an approved, unexpired unlock through (R8/R42). See the comment above the guard.
--
-- Covered by supabase/tests/production_test.sql (TC-13 ... TC-18) and
-- supabase/tests/receipt_state_floor_test.sql (RSF-01 ... RSF-09).

create or replace function public.fn_record_lot_receipt(
  p_idempotency_key      uuid,
  p_lot_id               uuid,
  p_event_date           date,
  p_received_weight_kg   numeric,
  p_post_drain_weight_kg numeric default null,
  p_variance_reason      text    default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor     uuid;
  v_lot       lots;
  v_receipt   lot_receipts;
  v_drain     numeric(12,2);
  v_reason    text;
  v_threshold numeric;
  v_pct       numeric;
  v_verdict   text;
  v_id        uuid;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- ^fix-numeric-scale: a third decimal is refused by name, not rounded by the column.
  perform fn_require_two_decimals('p_received_weight_kg', p_received_weight_kg);
  perform fn_require_two_decimals('p_post_drain_weight_kg', p_post_drain_weight_kg);

  if p_event_date is null then
    raise exception 'RECEIPT_EVENT_DATE_REQUIRED: the receipt resolves its own config by its own date, never now() (R12)';
  end if;

  if p_received_weight_kg is null or p_received_weight_kg < 0 then
    raise exception 'RECEIPT_WEIGHT_INVALID: received_weight_kg must be >= 0, got %',
      p_received_weight_kg;
  end if;

  if p_post_drain_weight_kg is not null and p_post_drain_weight_kg < 0 then
    raise exception 'POST_DRAIN_WEIGHT_INVALID: post_drain_weight_kg must be >= 0, got %',
      p_post_drain_weight_kg;
  end if;

  -- Four questions, and LOT_NOT_FOUND among them. See fn_require_operator's header.
  v_actor := fn_require_operator(p_lot_id);

  -- Locked before the retry is asked: two operators on two phones are signing for one lot,
  -- and the row is what they compete for. Same shape as ^ref-22's receipt.
  select * into v_lot from lots where id = p_lot_id for update;

  -- A FLOOR, NOT A RANGE (^fix-receipt-state-floor). The lower end is this function's job: a
  -- receipt against PO_CREATED is a receipt for meat still on Foodiva's floor, and nothing
  -- else refuses it. The UPPER end belongs to ...0013's fn_guard_lot_closed (R8). At
  -- LOT_CLOSED or beyond, it refuses the write unless an approved, unexpired unlock_request
  -- exists (R42). The old `not in ('IN_TRANSIT','CM_RECEIVED')` refused that correction
  -- before the trigger ever ran, so for this table the unlock path could never do anything.
  --
  -- The floor is IN_TRANSIT, not the CM_RECEIVED that ^ref-27 uses, because a receipt is
  -- signed while the lot is still IN_TRANSIT (TC-13). A correction at SMOKING is therefore
  -- accepted now. R8 guards closed lots only.
  --
  -- An opening lot keeps its refusal. It sits at LOT_CLOSED, the trigger exempts it
  -- (ADR-021), and it has no dispatch weight to receive against. The old `not in` refused
  -- it, and a bare floor would not.
  if v_lot.state < 'IN_TRANSIT' or v_lot.is_opening then
    raise exception 'LOT_STATE_INVALID: lot % is at % (opening: %) — a receipt is signed from IN_TRANSIT on, and never against an opening lot',
      v_lot.lot_code, v_lot.state, v_lot.is_opening;
  end if;

  select * into v_receipt from lot_receipts where lot_id = p_lot_id for update;

  -- The effective values: what the caller sent, falling back to what is already on the row.
  -- This is the whole of the correction/retry behaviour and it is deliberately not a branch
  -- on "is this a replay" — the natural key makes the two indistinguishable and the same
  -- three lines are right for both (Seam 3).
  v_drain  := coalesce(p_post_drain_weight_kg, v_receipt.post_drain_weight_kg);
  v_reason := coalesce(p_variance_reason,      v_receipt.variance_reason);

  if v_drain is not null and v_drain > p_received_weight_kg then
    raise exception 'POST_DRAIN_EXCEEDS_RECEIVED: % kg after draining against % kg received on lot % (CM 03)',
      v_drain, p_received_weight_kg, v_lot.lot_code;
  end if;

  ------------------------------------------------------------------------ CM 02 / BR12 / R22
  v_threshold := fn_config_numeric('receipt_variance_threshold_pct', p_event_date);
  select variance_pct, verdict
    into v_pct, v_verdict
    from fn_check_variance(p_received_weight_kg, v_lot.foodiva_sent_weight_kg, 'ALERT', v_threshold);

  if v_verdict <> 'WITHIN'
     and fn_config_boolean('receipt_variance_requires_reason', p_event_date)
     and coalesce(btrim(v_reason), '') = ''
  then
    raise exception 'VARIANCE_REASON_REQUIRED: % kg received against % kg dispatched is %%% off, past a tolerance of %%% (CM 02, BR12)',
      p_received_weight_kg, v_lot.foodiva_sent_weight_kg,
      coalesce(v_pct::text, 'an unmeasurable'), v_threshold;
  end if;

  insert into lot_receipts (lot_id, event_date, received_weight_kg, post_drain_weight_kg,
                            variance_reason, recorded_by)
       values (p_lot_id, p_event_date, p_received_weight_kg, v_drain, v_reason, v_actor)
  on conflict (lot_id) do update
     set event_date           = excluded.event_date,
         received_weight_kg   = excluded.received_weight_kg,
         post_drain_weight_kg = excluded.post_drain_weight_kg,
         variance_reason      = excluded.variance_reason,
         recorded_by          = excluded.recorded_by
  returning id into v_id;

  -- Idempotent on its own: the lot is already CM_RECEIVED on the second visit.
  update lots set state = 'CM_RECEIVED' where id = p_lot_id and state = 'IN_TRANSIT';

  return v_id;
end $$;

revoke execute on function public.fn_record_lot_receipt(uuid, uuid, date, numeric, numeric, text) from public, anon, authenticated;
grant  execute on function public.fn_record_lot_receipt(uuid, uuid, date, numeric, numeric, text) to authenticated;
