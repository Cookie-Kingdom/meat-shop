-- v_lot_cost — what a lot has cost so far, part by part, and whether that is the whole of it
-- (R30, R41, ADR-012, ADR-023, ADR-024, BR02, BR10, BR23, card ^ref-32).
--
--   meat      = purchase_orders.unit_price_thb_per_kg × lots.foodiva_sent_weight_kg
--   brine     = foodiva_sent_weight_kg × brine_pct_of_meat / 100 × brine_cost_thb_per_kg
--   smoke fee = coalesce(lots.smoke_fee_override_thb, <tier applied to foodiva_sent_weight_kg>)
--   freight   = Σ transport_lines.freight_share_thb for the lot, outbound + return
--
-- EVERY BASE IS THE FOODIVA DISPATCH WEIGHT (BR10, D02, ADR-024). Not the CM received weight
-- and not the post-smoke weight: dispatch 100 at 50 THB/kg is a 5000.00 fee, never 4900.00 or
-- 3750.00 (TC-14). The brine is BR02's "10% of the meat weight, with a unit cost"; it does not
-- read purchase_orders.brine_cost_thb or smoke_daily_logs.brine_used_kg, because v0.2 M1 keeps
-- the offered figure separate from actual use.
--
-- A MISSING INPUT IS NULL, NEVER 0, AND IS NAMED (ADR-023, PLAN-cost Finding 2). ADR-024's
-- wording was "refuses through CONFIG_NOT_SET", but a raise inside a view fails every row: one
-- lot priced before the first tier date would blank the screen for all the others. So each
-- part that cannot be resolved reads null, total_cost_thb sums only the parts that are known
-- ("ต้นทุน ณ เวลานั้น", v0.2 M3), and missing_inputs says what the lot is waiting for:
--
--   LOT_OPEN          the lot has not closed — every figure is provisional
--   MEAT_PRICE        the PO carries no unit price
--   BRINE_PCT         no brine_pct_of_meat on or before priced_at
--   BRINE_RATE        no brine_cost_thb_per_kg on or before priced_at
--   SMOKE_FEE_RATE    no tier band holds the dispatch weight, and there is no override
--   OUTBOUND_FREIGHT  no FOODIVA_TO_CM line, or one not yet allocated
--   RETURN_FREIGHT    no CM_TO_FOODIVA line, or one not yet allocated
--   RETURN_RECEIPT    a CM_TO_FOODIVA line not yet received
--   CHEF_HOUSE_STOCK  FROZEN meat of this lot still sits at its chef house
--
-- is_complete IS R30's "no view labels a lot's cost final before its return leg is received":
-- true only when that list is empty. The chef-house test is FROZEN only — a short partial
-- receipt leaves IN_TRANSIT outstanding for ever, and that must not keep a lot incomplete for
-- ever; meat not yet sent back is FROZEN at the chef house until its return line draws it.
--
-- CONFIG IS RESOLVED AT priced_at = coalesce(closed_at, now())::date (BR23, ADR-024). A tier or
-- rate dated after a lot closed does not move it (TC-21). An open lot is priced today and is
-- marked LOT_OPEN. The date is taken in the session timezone, as fn_close_lot's current_date
-- is (fn_backdating_allowed records the same assumption: Asia/Bangkok, ADR-010).
--
-- CONFIG IS READ FROM THE TABLES, NOT THROUGH fn_config_numeric. A view's function calls run
-- with the caller's privileges and fn_config_* is granted to nobody (rls_deny_all 1f), so a
-- call here would refuse every L1 read. The lateral selects below are fn_config_value's
-- resolution for a global key — scope null, effective_from on or before the date, newest first
-- (R12) — and fn_set_smoke_fee_tier's band rule: the newest set on or before the date, the
-- band [min, max) holding the weight.
--
-- THE OVERRIDE (R41). smoke_fee_thb = coalesce(override, computed) and smoke_fee_is_overridden
-- says which, so a discounted lot never reads as if the rate had changed. 0.00 is honoured: a
-- coalesce, never a nullif. The computed figure and the rate that produced it stay visible
-- beside it, which is how a discount stays legible as a difference from the rate.
--
-- TRACEABLE (F13). Every part carries its inputs: the PO and its unit price, the brine
-- percentage and rate with the rate's date, the tier id, rate, basis and set date, the override
-- and its reason. Freight per line is v_freight_allocation's.
--
-- OPENING LOTS ARE EXCLUDED: their cost lives in opening_costs (^ref-62, ADR-021), and lane K's
-- v_cost_breakdown unions the two.
--
-- L1 ONLY, AS A WHERE (R34, R20). Every column here is a price. SECURITY DEFINER (the Postgres
-- default), never security_invoker — the base tables have RLS on with no policies.
--
-- Covered by supabase/tests/cost_test.sql (TC-13 ... TC-22) and, for columns and grants,
-- supabase/tests/cost_schema_test.sql (TC-10, TC-12).

create or replace view public.v_lot_cost as
with base as (
  select
    l.id                                                         as lot_id,
    l.lot_code,
    l.state,
    l.closed_at,
    p.priced_at,
    l.po_id,
    po.po_number,
    l.foodiva_sent_weight_kg,
    po.unit_price_thb_per_kg                                     as meat_unit_price_thb_per_kg,
    round(po.unit_price_thb_per_kg * l.foodiva_sent_weight_kg, 2)::numeric(12,2)
                                                                 as meat_cost_thb,
    bp.value_numeric                                             as brine_pct_of_meat,
    br.value_numeric                                             as brine_cost_thb_per_kg,
    br.effective_from                                            as brine_rate_effective_from,
    round(l.foodiva_sent_weight_kg * bp.value_numeric / 100 * br.value_numeric, 2)::numeric(12,2)
                                                                 as brine_cost_thb,
    tier.id                                                      as smoke_fee_tier_id,
    tier.effective_from                                          as smoke_fee_tier_effective_from,
    tier.rate_thb                                                as smoke_fee_rate_thb,
    tier.rate_basis                                              as smoke_fee_rate_basis,
    (case tier.rate_basis
       when 'PER_KG' then round(tier.rate_thb * l.foodiva_sent_weight_kg, 2)
       when 'FLAT'   then tier.rate_thb
     end)::numeric(12,2)                                         as smoke_fee_computed_thb,
    l.smoke_fee_override_thb,
    l.smoke_fee_override_reason,
    fr.outbound_thb,
    fr.return_thb,
    fr.freight_thb,
    fr.out_lines,
    fr.out_unallocated,
    fr.ret_lines,
    fr.ret_unallocated,
    fr.ret_unreceived,
    ch.frozen_kg
  from lots l
  cross join lateral (
    select coalesce(l.closed_at, now())::date as priced_at
  ) p
  left join purchase_orders po on po.id = l.po_id
  left join lateral (
    select c.value_numeric
      from config_settings c
     where c.key = 'brine_pct_of_meat'
       and c.scope_location_id is null
       and c.effective_from <= p.priced_at
     order by c.effective_from desc
     limit 1
  ) bp on true
  left join lateral (
    select c.value_numeric, c.effective_from
      from config_settings c
     where c.key = 'brine_cost_thb_per_kg'
       and c.scope_location_id is null
       and c.effective_from <= p.priced_at
     order by c.effective_from desc
     limit 1
  ) br on true
  left join lateral (
    select t.id, t.effective_from, t.rate_thb, t.rate_basis
      from smoke_fee_tiers t
     where t.effective_from = (select max(t2.effective_from)
                                 from smoke_fee_tiers t2
                                where t2.effective_from <= p.priced_at)
       and l.foodiva_sent_weight_kg >= t.min_weight_kg
       and (t.max_weight_kg is null or l.foodiva_sent_weight_kg < t.max_weight_kg)
     order by t.min_weight_kg desc
     limit 1
  ) tier on true
  cross join lateral (
    select
      sum(tl.freight_share_thb) filter (where tr.route = 'FOODIVA_TO_CM')::numeric(12,2)
                                                                 as outbound_thb,
      sum(tl.freight_share_thb) filter (where tr.route = 'CM_TO_FOODIVA')::numeric(12,2)
                                                                 as return_thb,
      sum(tl.freight_share_thb) filter (where tr.route in ('FOODIVA_TO_CM', 'CM_TO_FOODIVA'))::numeric(12,2)
                                                                 as freight_thb,
      count(*) filter (where tr.route = 'FOODIVA_TO_CM')         as out_lines,
      count(*) filter (where tr.route = 'FOODIVA_TO_CM'
                         and tl.freight_share_thb is null)       as out_unallocated,
      count(*) filter (where tr.route = 'CM_TO_FOODIVA')         as ret_lines,
      count(*) filter (where tr.route = 'CM_TO_FOODIVA'
                         and tl.freight_share_thb is null)       as ret_unallocated,
      count(*) filter (where tr.route = 'CM_TO_FOODIVA'
                         and tl.received_weight_kg is null)      as ret_unreceived
      from transport_lines tl
      join transport_runs tr on tr.id = tl.run_id
     where tl.lot_id = l.id
  ) fr
  cross join lateral (
    select coalesce(sum(s.qty_delta), 0)::numeric(12,2) as frozen_kg
      from stock_ledger s
     where s.item_type   = 'SMOKED_MEAT'
       and s.lot_id      = l.id
       and s.location_id = l.chef_house_location_id
       and s.stock_state = 'FROZEN'
  ) ch
  where not l.is_opening
    and fn_current_role() = 'L1_OWNER'
)
select
  b.lot_id,
  b.lot_code,
  b.state,
  b.closed_at,
  b.priced_at,
  b.po_id,
  b.po_number,
  b.foodiva_sent_weight_kg,
  b.meat_unit_price_thb_per_kg,
  b.meat_cost_thb,
  b.brine_pct_of_meat,
  b.brine_cost_thb_per_kg,
  b.brine_rate_effective_from,
  b.brine_cost_thb,
  b.smoke_fee_tier_id,
  b.smoke_fee_tier_effective_from,
  b.smoke_fee_rate_thb,
  b.smoke_fee_rate_basis,
  b.smoke_fee_computed_thb,
  b.smoke_fee_override_thb,
  b.smoke_fee_override_reason,
  f.smoke_fee_thb,
  b.smoke_fee_override_thb is not null                           as smoke_fee_is_overridden,
  b.outbound_thb                                                 as freight_outbound_thb,
  b.return_thb                                                   as freight_return_thb,
  b.freight_thb                                                  as freight_share_thb,
  b.frozen_kg                                                    as chef_house_frozen_kg,
  (select sum(x)
     from unnest(array[b.meat_cost_thb, b.brine_cost_thb, f.smoke_fee_thb, b.freight_thb]) as x
  )::numeric(12,2)                                               as total_cost_thb,
  cardinality(m.missing) = 0                                     as is_complete,
  m.missing                                                      as missing_inputs
from base b
cross join lateral (
  select coalesce(b.smoke_fee_override_thb, b.smoke_fee_computed_thb)::numeric(12,2) as smoke_fee_thb
) f
cross join lateral (
  select array_remove(array[
    case when b.state < 'LOT_CLOSED'                          then 'LOT_OPEN'         end,
    case when b.meat_cost_thb is null                         then 'MEAT_PRICE'       end,
    case when b.brine_pct_of_meat is null                     then 'BRINE_PCT'        end,
    case when b.brine_cost_thb_per_kg is null                 then 'BRINE_RATE'       end,
    case when f.smoke_fee_thb is null                         then 'SMOKE_FEE_RATE'   end,
    case when b.out_lines = 0 or b.out_unallocated > 0        then 'OUTBOUND_FREIGHT' end,
    case when b.ret_lines = 0 or b.ret_unallocated > 0        then 'RETURN_FREIGHT'   end,
    case when b.ret_unreceived > 0                            then 'RETURN_RECEIPT'   end,
    case when b.frozen_kg > 0                                 then 'CHEF_HOUSE_STOCK' end
  ]::text[], null) as missing
) m;

comment on view public.v_lot_cost is
  'R30, R41, ADR-024 — meat, brine, smoke fee and freight per lot on the Foodiva dispatch base, '
  'config resolved at priced_at = coalesce(closed_at, now())::date. A missing input is null, '
  'never 0, and named in missing_inputs; is_complete is true only when that list is empty '
  '(closed, all rates set, freight allocated both ways, return received, nothing left FROZEN at '
  'the chef house). smoke_fee_thb = coalesce(override, computed). Non-opening lots, L1 only in '
  'the WHERE (R34, R20).';

revoke all    on public.v_lot_cost from anon, authenticated;
grant  select on public.v_lot_cost to   authenticated;
