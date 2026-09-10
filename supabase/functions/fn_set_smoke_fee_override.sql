-- Card ^ref-32 — fn_set_smoke_fee_override. What the chef house actually charged for one lot,
-- when it differs from the configured rate (ADR-024, R41).
--
-- L1 ONLY. It is a price: R20 keeps an L3 session out of the column and BR15 keeps the chef
-- house from entering it. fn_require_owner() runs FIRST, before the lot is even looked up, so
-- an L3 or L2 probing lot ids learns nothing — not even LOT_NOT_FOUND (ADR-004).
--
-- A CLOSED LOT IS ACCEPTED. A discount is usually agreed after the run, and R30 already says
-- cost accrues past close. lots carries no fn_guard_lot_closed trigger — only its five child
-- tables do — so nothing here needs an unlock.
--
-- NULL CLEARS, AND CLEARING TAKES NO REASON (PLAN-cost Finding 8). The API row said clearing
-- also requires one, but lots_smoke_fee_override_pair makes both columns null together, so
-- there is nowhere to keep it; a reason accepted and then thrown away is theatre. R32's audit
-- row already carries the before-snapshot — the amount and reason that were cleared, who
-- cleared them and when. p_reason is ignored on a clear.
--
-- 0.00 IS A REAL VALUE. A free run is entered deliberately and v_lot_cost honours it. Only a
-- negative amount is refused.
--
-- AN OPENING LOT IS REFUSED (LOT_IS_OPENING). Its cost lives in opening_costs (^ref-62) and
-- v_lot_cost excludes it, so an override there would be a number nothing ever reads.
--
-- THE KEY IS REQUIRED AND NOT STORED (ADR-005, R4). The replay rides the row, as
-- fn_record_lot_receipt's does (R38): if the same (amount, reason) already stands the call
-- returns without writing, so a retried submit adds no second audit row. The `for update`
-- makes two concurrent overrides queue rather than interleave; the second simply wins, and
-- both are in the audit trail.
--
-- Covered by supabase/tests/cost_test.sql (TC-17 ... TC-20, TC-22).

create or replace function public.fn_set_smoke_fee_override(
  p_idempotency_key uuid,
  p_lot_id          uuid,
  p_amount_thb      numeric,
  p_reason          text
) returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_lot    lots;
  v_amount numeric(12,2);
  v_reason text;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- NO_ACTOR, FORBIDDEN. Before the lookup, on purpose (header).
  perform fn_require_owner();

  select * into v_lot from lots where id = p_lot_id for update;
  if not found then
    raise exception 'LOT_NOT_FOUND: no lot %', p_lot_id;
  end if;

  if v_lot.is_opening then
    raise exception 'LOT_IS_OPENING: lot % was counted in at go-live; its cost is opening_costs''s, not a smoke fee (ADR-021)',
      v_lot.lot_code;
  end if;

  if p_amount_thb is not null then
    if p_amount_thb < 0 then
      raise exception 'SMOKE_FEE_OVERRIDE_INVALID: lot % cannot be charged % THB — 0.00 is a free run, below it is nothing (R41)',
        v_lot.lot_code, p_amount_thb;
    end if;

    v_reason := nullif(btrim(p_reason), '');
    if v_reason is null then
      raise exception 'SMOKE_FEE_REASON_REQUIRED: an override on lot % needs the reason it differs from the rate (R41)',
        v_lot.lot_code;
    end if;

    v_amount := round(p_amount_thb, 2);
  end if;
  -- else: a clear. Both stay null, and p_reason is ignored (header).

  -- R4: the standing value again is a retry, and a retry writes nothing.
  if v_lot.smoke_fee_override_thb    is not distinct from v_amount
     and v_lot.smoke_fee_override_reason is not distinct from v_reason then
    return;
  end if;

  update lots
     set smoke_fee_override_thb    = v_amount,
         smoke_fee_override_reason = v_reason
   where id = p_lot_id;
end $$;

revoke execute on function public.fn_set_smoke_fee_override(uuid, uuid, numeric, text) from public, anon, authenticated;
grant  execute on function public.fn_set_smoke_fee_override(uuid, uuid, numeric, text) to authenticated;
