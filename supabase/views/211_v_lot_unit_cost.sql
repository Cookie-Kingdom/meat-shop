-- v_lot_unit_cost — one row per lot: what it cost, part by part, and how many kilograms of
-- output that cost is spread over (R30, R41, ADR-021, R46, card ^ref-56; PLAN-reporting.md K7).
--
-- K NEVER RE-PRICES A LOT. A round lot's four parts, total, completeness and missing inputs are
-- 171_v_lot_cost's, read as they are; its output is 170_v_lot_yield's output_weight_kg
-- (dispatch − the loss fn_close_lot stored). Two cost engines would disagree the first time a
-- rule changed. A lot 170 does not list (not closed yet) has no output: output_kg is null and
-- OUTPUT_WEIGHT joins 171's missing list, so 212 attributes nothing it cannot divide.
--
-- AN OPENING LOT IS PRICED FROM opening_costs (ADR-021, R46), which 170 and 171 exclude.
-- output_kg = Σ its OPENING kilograms; opening_stock_cost_thb = Σ round(kg × cost_thb_per_kg, 2)
-- over those rows. One uncosted row makes the whole figure null and names OPENING_COST — never
-- a partial sum that reads as the lot's cost. A reversal of an OPENING row counts as OPENING and
-- carries its original's cost with the opposite sign; its replacement is a new OPENING row and
-- needs its own opening_costs row (fn_set_opening_cost keys on the ledger id).
--
-- Every numeric column is cast to its declared type in both branches of the UNION, so the view's
-- column types survive the union (TC-S03).
--
-- L1 ONLY, AS A WHERE (R34, R20): every column is a price. SECURITY DEFINER (the default).
--
-- 212_v_meat_cost_attribution and 222_v_pnl_by_lot read this view. Changing its column list
-- means dropping them in the same change, never adding CASCADE.
--
-- Covered by supabase/tests/reports_cost_test.sql (TC-11, TC-12, TC-17).

create or replace view public.v_lot_unit_cost as
select c.lot_id,
       c.lot_code,
       false                                                 as is_opening,
       y.output_weight_kg::numeric(12,2)                     as output_kg,
       c.meat_cost_thb::numeric(12,2)                        as meat_cost_thb,
       c.brine_cost_thb::numeric(12,2)                       as brine_cost_thb,
       c.smoke_fee_thb::numeric(12,2)                        as smoke_fee_thb,
       c.freight_share_thb::numeric(12,2)                    as freight_thb,
       null::numeric(12,2)                                   as opening_stock_cost_thb,
       c.total_cost_thb::numeric(12,2)                       as total_cost_thb,
       (c.is_complete and y.output_weight_kg is not null)    as cost_is_complete,
       case when y.output_weight_kg is null
            then c.missing_inputs || 'OUTPUT_WEIGHT'::text
            else c.missing_inputs end                        as missing_inputs
  from v_lot_cost c
  left join v_lot_yield y on y.lot_id = c.lot_id
 where fn_current_role() = 'L1_OWNER'
union all
select l.id,
       l.lot_code,
       true,
       o.output_kg::numeric(12,2),
       null::numeric(12,2),
       null::numeric(12,2),
       null::numeric(12,2),
       null::numeric(12,2),
       o.cost_thb::numeric(12,2),
       o.cost_thb::numeric(12,2),
       (o.output_kg is not null and coalesce(o.all_costed, false)),
       array_remove(array[
         case when o.output_kg is null                then 'OUTPUT_WEIGHT' end,
         case when not coalesce(o.all_costed, false)  then 'OPENING_COST'  end
       ]::text[], null)
  from lots l
 cross join lateral (
   select sum(s.qty_delta)                    as output_kg,
          bool_and(oc.ledger_id is not null)  as all_costed,
          case when bool_and(oc.ledger_id is not null)
               then sum(round(s.qty_delta * oc.cost_thb_per_kg, 2)) end as cost_thb
     from stock_ledger s
     left join stock_ledger r   on r.id = s.reversal_of
     left join opening_costs oc on oc.ledger_id = coalesce(s.reversal_of, s.id)
    where s.lot_id    = l.id
      and s.item_type = 'SMOKED_MEAT'
      and coalesce(r.movement_type, s.movement_type) = 'OPENING'
 ) o
 where l.is_opening
   and fn_current_role() = 'L1_OWNER';

comment on view public.v_lot_unit_cost is
  'R30, ADR-021 — per lot: the cost parts (171 for a round lot, opening_costs for an opening lot) '
  'and output_kg, the kilograms they are spread over (170 output_weight_kg, or Σ OPENING kg). '
  'Unknown is null and named in missing_inputs (OUTPUT_WEIGHT, OPENING_COST, and 171''s codes). '
  'L1 only (R34, R20).';

revoke all    on public.v_lot_unit_cost from anon, authenticated;
grant  select on public.v_lot_unit_cost to   authenticated;
