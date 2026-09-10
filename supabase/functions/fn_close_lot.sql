-- Card ^ref-29 — fn_close_lot. CM 05: the operator confirms production is finished, and in
-- one transaction the lot locks, posts its only ledger rows and, past threshold, alerts the
-- Owner. No approval step follows it (C02, ADR-015, UAT-23).
--
-- THE LEDGER IS WRITTEN HERE AND NOWHERE ELSE IN F6 (ADR-025). At the lot's chef house:
--
--   -(the whole raw balance)   on (lot, group = null, FROZEN)   PRODUCTION
--   +packed_weight_kg          on (lot, group,        FROZEN)   PRODUCTION, one per group
--
-- The whole raw balance, not Σ input. On a D05 cross-lot day the output lands on the lot the
-- log is filed under while part of the input came out of another lot; drawing each raw tuple
-- exactly once, entirely, at its own close is right in either order, because
-- fn_guard_lot_closed already refuses any source row that names a closed lot. Σ input would
-- leave the blood drain standing as raw meat at a closed lot for ever. No third row: the
-- shortfall is the net of these rows, and it is not WASTE, not ADJUSTMENT, and not "loss".
--
-- THE RESPONSE CARRIES NO PRICE AND NO YIELD (UAT-15, BR15). v0.2 line 441 says the L3 must
-- not see price or Yield and that the API is checked too — and the L3 is the caller. So the
-- contract's loss_pct, smoke_yield_pct, yield_alert and cost_thb are not in the body. The
-- yield figures travel to the Owner in the YIELD_ALERT payload (notifications is deny-all to
-- every session) and, for every lot, through v_lot_yield (^ref-31).
--
-- NO COST (ADR-024, R30). "A lot may be closed and priced later": a missing smoke-fee band
-- must not stop a close, cost is not final at close anyway, and there is no column to hold
-- one and no caller allowed to read it. What the close fixes is closed_at — the date
-- v_lot_cost (^ref-32) resolves config at, which is what keeps BR23 true.
--
-- THE ALERT IS fn_check_variance, NOT A SECOND BOUNDARY (ADR-019, R16). ADR-019 names "loss
-- above 20%" as an ALERT call site of the one variance rule: rounded first, then `<=` is
-- WITHIN, so 80.00 kg of a 100 kg dispatch is silent and 79.99 alerts. The base is
-- lots.foodiva_sent_weight_kg and never the received weight (R16a, ADR-011). It never blocks
-- (R16b): the lot closes either way.
--
-- Output is Σ smoke_date_groups.packed_weight_kg — CM 04 "รวมผลผลิตจากรายการแพ็ค" (v0.2 line
-- 81) — which is the roll-up of the bags, not the logs' smoked_weight_kg reading.
--
-- IDEMPOTENCY (R4) rides lots.close_idempotency_key (...0015), read under `for update`. The
-- same key returns the original response and writes nothing; a different key on a closed lot
-- is LOT_ALREADY_CLOSED. The lock is what makes two concurrent closes one winner and one
-- named refusal rather than two sets of ledger rows (TC-54).
--
-- "LOCKS THE LOT" IS fn_guard_lot_closed, not this function. Setting LOT_CLOSED is what arms
-- ...0013's trigger on all five child tables; R42's unlock is evaluated there.
--
-- NO TRANSPORT JOB (BR17). The return leg needs RETURN_SCHEDULED, which ^ref-34 sets once
-- somebody names a pickup date. Nothing here touches transport_runs or transport_lines.
--
-- The business date is current_date, fn_backdating_allowed's precedent: the close is the act
-- itself, not a record of an earlier one.
--
-- Covered by supabase/tests/lot_close_test.sql (TC-38 ... TC-59) and, for TC-54,
-- supabase/tests/production_concurrency_test.sh.

create or replace function public.fn_close_lot(
  p_idempotency_key uuid,
  p_lot_id          uuid
) returns jsonb
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor     uuid;
  v_lot       lots;
  v_rec       lot_receipts;
  v_day       date := current_date;
  v_bad       date;
  v_threshold numeric;
  v_raw       numeric(12,2);
  v_grp       smoke_date_groups;
  v_out       numeric(12,2);
  v_verdict   text;
  v_resp      jsonb;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- NO_ACTOR, FORBIDDEN, FORBIDDEN_LOCATION, LOT_NOT_FOUND, NOT_ASSIGNED_OPERATOR.
  v_actor := fn_require_operator(p_lot_id);

  select * into v_lot from lots where id = p_lot_id for update;

  if v_lot.close_idempotency_key is distinct from p_idempotency_key then
    if v_lot.state >= 'LOT_CLOSED' then
      raise exception 'LOT_ALREADY_CLOSED: lot % is at %, closed at % under a different key',
        v_lot.lot_code, v_lot.state, v_lot.closed_at;
    end if;

    --------------------------------------------------------------------------- ready to close
    select * into v_rec from lot_receipts where lot_id = p_lot_id;
    if not found or not exists (select 1 from smoke_daily_logs where lot_id = p_lot_id) then
      raise exception 'LOT_NOT_READY: lot % needs a receipt and at least one smoke log before it can close',
        v_lot.lot_code;
    end if;

    -- Blocking is deliberate: R18 forbids deriving the input from the output.
    select min(l.event_date) into v_bad
      from smoke_daily_logs l
     where l.lot_id = p_lot_id
       and not exists (select 1 from smoke_daily_log_sources s where s.smoke_daily_log_id = l.id);
    if v_bad is not null then
      raise exception 'INPUT_WEIGHT_MISSING: lot % has a log on % with no input sources (R18)',
        v_lot.lot_code, v_bad;
    end if;

    select min(l.event_date) into v_bad
      from smoke_daily_logs l
     where l.lot_id = p_lot_id
       and l.input_weight_kg <> (select sum(s.input_weight_kg)
                                   from smoke_daily_log_sources s
                                  where s.smoke_daily_log_id = l.id);
    if v_bad is not null then
      raise exception 'SOURCE_SUM_MISMATCH: lot %''s log on % does not equal the sum of its sources (R6a)',
        v_lot.lot_code, v_bad;
    end if;

    -- Before any write, so an unset threshold refuses with nothing half-done (ADR-023, R35).
    v_threshold := fn_config_numeric('yield_alert_threshold_pct', v_day);

    ------------------------------------------------------------------ the ledger (ADR-025)
    -- ponytail: read under the lot lock, not fn_post_ledger's tuple lock. A second transport
    -- receipt for this lot landing mid-close would stay on (lot, null) — a lot at SMOKING
    -- received its meat long ago. Take the tuple's advisory lock here first if partial
    -- deliveries ever arrive after smoking starts.
    select coalesce(sum(qty_delta), 0) into v_raw
      from stock_ledger
     where item_type = 'SMOKED_MEAT'
       and lot_id = p_lot_id
       and smoke_date_group_id is null
       and product_id is null
       and packaging_item_id is null
       and location_id = v_lot.chef_house_location_id
       and stock_state = 'FROZEN';

    if v_raw > 0 then
      perform fn_post_ledger(
        p_idempotency_key => md5(p_idempotency_key::text || ':raw')::uuid,
        p_item_type       => 'SMOKED_MEAT',
        p_location_id     => v_lot.chef_house_location_id,
        p_stock_state     => 'FROZEN',
        p_movement_type   => 'PRODUCTION',
        p_qty_delta       => -v_raw,
        p_business_date   => v_day,
        p_lot_id          => p_lot_id,
        p_source_table    => 'lots',
        p_source_id       => p_lot_id);
    end if;

    for v_grp in
      select * from smoke_date_groups
       where lot_id = p_lot_id and packed_weight_kg > 0
       order by smoke_date
    loop
      perform fn_post_ledger(
        p_idempotency_key     => md5(p_idempotency_key::text || ':' || v_grp.id::text)::uuid,
        p_item_type           => 'SMOKED_MEAT',
        p_location_id         => v_lot.chef_house_location_id,
        p_stock_state         => 'FROZEN',
        p_movement_type       => 'PRODUCTION',
        p_qty_delta           => v_grp.packed_weight_kg,
        p_business_date       => v_day,
        p_lot_id              => p_lot_id,
        p_smoke_date_group_id => v_grp.id,
        p_source_table        => 'smoke_date_groups',
        p_source_id           => v_grp.id);
    end loop;

    -- The lost weight is STORED (...0015's loss_weight_kg): dispatch minus output, the
    -- numerator of Loss (v0.2 line 168), written once here so v_lot_yield (^ref-31) and the
    -- alert below read one number instead of two derivations of it. Yield-bearing, so it is
    -- not in the response.
    select coalesce(sum(packed_weight_kg), 0) into v_out
      from smoke_date_groups where lot_id = p_lot_id;

    update lots
       set state                 = 'LOT_CLOSED',
           closed_at             = now(),
           closed_by             = v_actor,
           close_idempotency_key = p_idempotency_key,
           loss_weight_kg        = foodiva_sent_weight_kg - v_out
     where id = p_lot_id
    returning * into v_lot;

    ------------------------------------------------------------------- the alert (R16, R16b)
    select verdict into v_verdict
      from fn_check_variance(v_out, v_lot.foodiva_sent_weight_kg, 'ALERT', v_threshold);

    if v_verdict <> 'WITHIN' then
      insert into notifications (kind, target_role, location_id, lot_id, payload)
      values ('YIELD_ALERT', 'L1_OWNER', v_lot.chef_house_location_id, p_lot_id,
              jsonb_build_object(
                'lot_code',               v_lot.lot_code,
                'loss_weight_kg',         v_lot.loss_weight_kg,
                'loss_pct',               round(v_lot.loss_weight_kg
                                                / v_lot.foodiva_sent_weight_kg * 100, 2),
                -- Finding 9: the pre-smoke weight is the base, and null stays null (v0.2:349).
                'smoke_yield_pct',        round(v_out / nullif(v_rec.post_drain_weight_kg, 0) * 100, 2),
                'threshold_pct',          v_threshold,
                'foodiva_sent_weight_kg', v_lot.foodiva_sent_weight_kg,
                'cm_received_weight_kg',  v_rec.received_weight_kg,
                'post_drain_weight_kg',   v_rec.post_drain_weight_kg,
                'output_weight_kg',       v_out));
    end if;
  end if;

  -------------------------------------------------------- the response: no price, no yield
  -- Built from the rows, so a replay answers exactly what the first call did.
  select jsonb_build_object(
           'lot_id',            l.id,
           'lot_code',          l.lot_code,
           'state',             'LOT_CLOSED',
           'closed_at',         l.closed_at,
           'smoke_date_groups', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'smoke_date',       g.smoke_date,
                      'packed_weight_kg', g.packed_weight_kg,
                      'bag_count',        g.bag_count) order by g.smoke_date)
               from smoke_date_groups g
              where g.lot_id = l.id), '[]'::jsonb))
    into v_resp
    from lots l
   where l.id = p_lot_id;

  return v_resp;
end $$;

revoke execute on function public.fn_close_lot(uuid, uuid) from public, anon, authenticated;
grant  execute on function public.fn_close_lot(uuid, uuid) to authenticated;
