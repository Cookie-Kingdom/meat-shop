-- v_meat_consumption — the kilograms of each lot that left the business, per day, branch and
-- kind (ADR-017, ADR-025, R2, card ^ref-56; PLAN-reporting.md K6, Finding 3).
--
-- CONSUMPTION IS SALE, WASTE AND GIVEAWAY, AND NOTHING ELSE. PRODUCTION is never consumption:
-- ADR-025 put the smoke loss inside every kilogram's cost, so reading a PRODUCTION row as a
-- cost as well would count it twice (TC-10). INTAKE, TRANSFER_*, THAW_*, ADJUSTMENT and OPENING
-- move or seed stock and are inert here (TC-10b). The predicate is one list of movement types.
--
-- A REVERSAL COUNTS AS WHAT IT REVERSES (R2), the same rule as 150_v_branch_diff: a reversed
-- sale nets out of its own atom, and fn_reverse_ledger_entry dates the reversal and its
-- replacement on the original's business_date, so a corrected sale lands in the same atom
-- (TC-19). A group that nets to zero has no row.
--
-- EVERY STOCK STATE COUNTS. A spoiled-FROZEN write-off left the business too; the Diff
-- (150) excludes it because the Diff is a READY question, and this view is a cost question.
--
-- GRAIN (business_date, location_id, lot_id, consumption_kind). consumed_kg = −Σ qty_delta.
-- No money here: 212 prices the atoms.
--
-- L1 ONLY, AS A WHERE (R34, R20). It is price-free, but it is the base of the cost chain and
-- no branch screen reads it. SECURITY DEFINER (the default), never security_invoker.
--
-- ponytail: one level of reversal, as in 150. fn_reverse_ledger_entry refuses to reverse a
-- REVERSAL row (NOT_REVERSIBLE), so a second level cannot be written.
--
-- 212_v_meat_cost_attribution and 222_v_pnl_by_lot read this view. Changing its column list
-- means dropping them in the same change, never adding CASCADE.
--
-- Covered by supabase/tests/reports_cost_test.sql (TC-10, TC-10b, TC-19, TC-R3, TC-R5).

create or replace view public.v_meat_consumption as
select l.business_date,
       l.location_id,
       l.lot_id,
       lt.lot_code,
       lt.is_opening,
       coalesce(o.movement_type, l.movement_type)::text as consumption_kind,
       (-sum(l.qty_delta))::numeric(12,2)                as consumed_kg
  from stock_ledger l
  left join stock_ledger o on o.id = l.reversal_of
  join lots lt             on lt.id = l.lot_id
 where l.item_type = 'SMOKED_MEAT'
   and coalesce(o.movement_type, l.movement_type) in ('SALE', 'WASTE', 'GIVEAWAY')
   and fn_current_role() = 'L1_OWNER'
 group by l.business_date, l.location_id, l.lot_id, lt.lot_code, lt.is_opening,
          coalesce(o.movement_type, l.movement_type)
having sum(l.qty_delta) <> 0;

comment on view public.v_meat_consumption is
  'ADR-025 / Finding 3 — SMOKED_MEAT kilograms consumed per business day, branch, lot and kind '
  '(SALE, WASTE, GIVEAWAY; a REVERSAL counts as the row it reverses). PRODUCTION is never '
  'consumption. No money. L1 only (R34).';

revoke all    on public.v_meat_consumption from anon, authenticated;
grant  select on public.v_meat_consumption to   authenticated;
