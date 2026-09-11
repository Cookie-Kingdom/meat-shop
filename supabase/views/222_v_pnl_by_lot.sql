-- v_pnl_by_lot — round one's profit per lot (BR14 "ราย Lot", ADR-026, card ^ref-57;
-- PLAN-reporting.md K13, Findings 3 and 12).
--
--   meat_revenue_thb       Σ round(qty × unit_price_thb, 2) over the meat sales lines naming the lot
--   attributed_cost_thb    Σ 212 for the lot: the cost of the kilograms that left
--   lot_total_cost_thb     211: the lot's whole cost as far as it is known
--   unattributed_cost_thb  lot total − attributed: the cost of weight still on hand, or never
--                          consumed (shrink). It stays on the lot and is never spread onto a day.
--   profit_round_one_thb   meat revenue − attributed cost
--
-- THE SAME ATOMS AS THE DAY P&L, grouped by lot instead of by day and branch, so the two cannot
-- disagree (TC-32). Non-meat lines (chilli, rice, water) carry no lot and are out of this view's
-- scope: scope_excludes adds NON_MEAT_LINES to D04's three.
--
-- A LOT IS COMPLETE WHEN ITS COST IS FINAL AND ITS STOCK IS GONE (ADR-026, Finding 12).
-- remaining_kg is Σ v_stock_balance for the lot, so exhaustion is always current and reverses
-- itself when an R2 reversal puts weight back. There is no "retirement act". While stock
-- remains, missing_inputs names STOCK_REMAINING beside 211's codes.
--
-- POPULATION: every lot with consumption, a meat sale or a non-zero balance.
--
-- L1 ONLY, AS A WHERE (R34, R20). SECURITY DEFINER (the default).
--
-- Covered by supabase/tests/reports_pnl_test.sql (TC-29, TC-32 ... TC-35).

create or replace view public.v_pnl_by_lot as
with cons as (
  select m.lot_id,
         sum(m.consumed_kg) filter (where m.consumption_kind = 'SALE')                 as sold_kg,
         sum(m.consumed_kg) filter (where m.consumption_kind in ('WASTE', 'GIVEAWAY')) as wasted_kg
    from v_meat_consumption m
   group by m.lot_id
), attr as (
  select a.lot_id, sum(a.attributed_cost_thb) as attributed
    from v_meat_cost_attribution a
   group by a.lot_id
), rev as (
  select s.lot_id, sum(round(s.qty * s.unit_price_thb, 2)) as revenue
    from sales_lines s
    join products p on p.id = s.product_id
   where p.item_type = 'SMOKED_MEAT'
     and s.lot_id is not null
   group by s.lot_id
), bal as (
  select b.lot_id, sum(b.balance_qty) as remaining
    from v_stock_balance b
   where b.item_type = 'SMOKED_MEAT'
     and b.lot_id is not null
   group by b.lot_id
)
select u.lot_id,
       u.lot_code,
       u.is_opening,
       u.output_kg,
       coalesce(c.sold_kg,   0)::numeric(12,2)                           as sold_kg,
       coalesce(c.wasted_kg, 0)::numeric(12,2)                           as wasted_kg,
       coalesce(b.remaining, 0)::numeric(12,2)                           as remaining_kg,
       coalesce(v.revenue,   0)::numeric(12,2)                           as meat_revenue_thb,
       coalesce(a.attributed, 0)::numeric(12,2)                          as attributed_cost_thb,
       u.total_cost_thb                                                  as lot_total_cost_thb,
       (u.total_cost_thb - coalesce(a.attributed, 0))::numeric(12,2)     as unattributed_cost_thb,
       (coalesce(v.revenue, 0) - coalesce(a.attributed, 0))::numeric(12,2) as profit_round_one_thb,
       u.cost_is_complete,
       (u.cost_is_complete and coalesce(b.remaining, 0) = 0)             as is_complete,
       u.missing_inputs
         || array_remove(array[case when coalesce(b.remaining, 0) <> 0
                                    then 'STOCK_REMAINING' end]::text[], null)
                                                                         as missing_inputs,
       'LINE_MAN'::text                                                  as revenue_source,
       '{TAX,CENTRAL_OVERHEAD,LABOUR,NON_MEAT_LINES}'::text[]            as scope_excludes
  from v_lot_unit_cost u
  left join cons c on c.lot_id = u.lot_id
  left join attr a on a.lot_id = u.lot_id
  left join rev  v on v.lot_id = u.lot_id
  left join bal  b on b.lot_id = u.lot_id
 where (c.lot_id is not null or v.lot_id is not null or coalesce(b.remaining, 0) <> 0)
   and fn_current_role() = 'L1_OWNER';

comment on view public.v_pnl_by_lot is
  'BR14 / D04 — round-one P&L per lot: meat revenue from the lot''s sales lines against the '
  'attributed cost of its consumed kg (212); the rest of its cost stays on the lot as '
  'unattributed_cost_thb. is_complete = cost final and Σ v_stock_balance = 0 (ADR-026). '
  'Tax, central overhead, labour and non-meat lines are out of scope. L1 only (R34).';

revoke all    on public.v_pnl_by_lot from anon, authenticated;
grant  select on public.v_pnl_by_lot to   authenticated;
