-- v_meat_cost_attribution — each consumption atom's share of its lot's cost (card ^ref-56;
-- PLAN-reporting.md K8, Finding 3 — proposed ADR "cost reaches a day and a branch per kilogram
-- consumed").
--
-- A branch never buys a lot, so P&L by day and branch (BR14) needs a cost basis that exists on
-- every one of those dimensions. That basis is consumption: each kilogram that leaves as a sale,
-- a waste or a giveaway (210) carries its lot's cost per kilogram of output (211).
--
-- CUMULATIVE ROUNDING, SO A SOLD-OUT LOT RECONCILES TO THE SATANG (TDD Seam 2). Atoms are
-- ordered (business_date, location_id, consumption_kind) within the lot, cum_kg is the running
-- kilograms, and each component c is
--     round(c × least(cum_kg / output_kg, 1), 2)  −  the previous atom's running figure
-- so the atoms telescope to c exactly when cum_kg reaches output_kg. Three 1.00 kg sales of a
-- 1,000.00, 3.00 kg lot read 333.33 + 333.34 + 333.33, never 333.33 × 3 (TC-14).
--
-- CAPPED AT THE OUTPUT (TC-15). Past output_kg the ratio stays at 1, so over-delivered or
-- adjusted-in meat costs 0.00 and cannot charge the lot twice; over_consumed flags the atom.
-- Weight never consumed (still in a freezer, or a shortfall) keeps its cost on the lot, as
-- 222's unattributed_cost_thb — it is never spread onto somebody else's day.
--
-- UNKNOWN IS NULL (ADR-023). A null component (171 could not price it, or an opening lot has
-- no meat part) gives a null atom; a null output_kg gives null everywhere and 211 already names
-- OUTPUT_WEIGHT. attributed_cost_thb is the sum of the known parts, 171's convention, and
-- cost_is_complete / missing_inputs are the lot's, carried on every atom.
--
-- L1 ONLY, AS A WHERE (R34, R20). SECURITY DEFINER (the default).
--
-- 213 and 222 read this view. Changing its column list means dropping them in the same change,
-- never adding CASCADE.
--
-- Covered by supabase/tests/reports_cost_test.sql (TC-13 ... TC-15, TC-17, TC-19).

create or replace view public.v_meat_cost_attribution as
with atoms as (
  select m.business_date,
         m.location_id,
         m.lot_id,
         m.lot_code,
         m.is_opening,
         m.consumption_kind,
         m.consumed_kg,
         u.output_kg,
         u.meat_cost_thb          as lot_meat,
         u.brine_cost_thb         as lot_brine,
         u.smoke_fee_thb          as lot_smoke,
         u.freight_thb            as lot_freight,
         u.opening_stock_cost_thb as lot_opening,
         u.cost_is_complete,
         u.missing_inputs,
         sum(m.consumed_kg) over (partition by m.lot_id
                                  order by m.business_date, m.location_id, m.consumption_kind
                                  rows between unbounded preceding and current row) as cum_kg
    from v_meat_consumption m
    join v_lot_unit_cost u on u.lot_id = m.lot_id
), running as (
  select a.*,
         round(a.lot_meat    * s.share, 2) as run_meat,
         round(a.lot_brine   * s.share, 2) as run_brine,
         round(a.lot_smoke   * s.share, 2) as run_smoke,
         round(a.lot_freight * s.share, 2) as run_freight,
         round(a.lot_opening * s.share, 2) as run_opening
    from atoms a
   cross join lateral (select least(a.cum_kg / nullif(a.output_kg, 0), 1) as share) s
), parts as (
  select r.*,
         r.run_meat    - coalesce(lag(r.run_meat)    over w, 0) as meat,
         r.run_brine   - coalesce(lag(r.run_brine)   over w, 0) as brine,
         r.run_smoke   - coalesce(lag(r.run_smoke)   over w, 0) as smoke,
         r.run_freight - coalesce(lag(r.run_freight) over w, 0) as freight,
         r.run_opening - coalesce(lag(r.run_opening) over w, 0) as opening
    from running r
  window w as (partition by r.lot_id order by r.business_date, r.location_id, r.consumption_kind)
)
select p.business_date,
       p.location_id,
       p.lot_id,
       p.lot_code,
       p.is_opening,
       p.consumption_kind,
       p.consumed_kg::numeric(12,2)                                        as consumed_kg,
       p.cum_kg::numeric(12,2)                                             as cum_kg,
       p.output_kg::numeric(12,2)                                          as output_kg,
       p.meat::numeric(12,2)                                               as meat_cost_thb,
       p.brine::numeric(12,2)                                              as brine_cost_thb,
       p.smoke::numeric(12,2)                                              as smoke_fee_thb,
       p.freight::numeric(12,2)                                            as freight_thb,
       p.opening::numeric(12,2)                                            as opening_stock_cost_thb,
       (select sum(x) from unnest(array[p.meat, p.brine, p.smoke, p.freight, p.opening]) as x
       )::numeric(12,2)                                                    as attributed_cost_thb,
       p.cost_is_complete,
       p.missing_inputs,
       coalesce(p.cum_kg > p.output_kg, false)                             as over_consumed
  from parts p
 where fn_current_role() = 'L1_OWNER';

comment on view public.v_meat_cost_attribution is
  'Finding 3 (proposed ADR) — each consumption atom (210) priced at its lot''s cost per output kg '
  '(211), by cumulative rounding so a fully consumed lot sums to its cost to the satang; capped '
  'at the output (over_consumed). Unknown parts are null. L1 only (R34, R20).';

revoke all    on public.v_meat_cost_attribution from anon, authenticated;
grant  select on public.v_meat_cost_attribution to   authenticated;
