-- v_lot_pending_work — how much of this lot is still waiting to go into the smoker
-- (R18, R34, BR15, card ^ref-26).
--
--   pending = post_drain_weight_kg − Σ input_weight_kg drawn OUT OF this lot
--
-- THE JOIN IS THE WHOLE TEST, AND THE OBVIOUS ONE IS WRONG (Seam 2, TC-31). R18's figure is
-- inputs CONSUMED OUT OF the lot, and smoke_daily_log_sources.lot_id is the D05 column that
-- says which lot each kilogram came out of. So the sum is over sources.lot_id = lots.id, NOT
-- over the logs filed under the lot. On a cross-lot day — a log filed under lot A drawing 30
-- kg from A and 10 kg from B — filing and sourcing are different relationships: joining
-- through smoke_daily_logs.lot_id charges all 40 kg to A and none to B, and the number looks
-- entirely plausible while B silently never runs out of meat. This is the one place in F6
-- where the wrong join produces a wrong number and no error.
--
-- NEVER OUTPUT-DERIVED (R18). smoked_weight_kg is sitting one join away on
-- smoke_daily_logs and is the obvious wrong answer: what came out of the smoker says nothing
-- about what is still waiting to go in, and using it would make pending work drift with the
-- production loss. There is no output column in this view at all, which is how the rule is
-- kept rather than by remembering it (TC-32).
--
-- pending_weight_kg IS NULL UNTIL CM 03, and that is honest. post_drain_weight_kg is
-- nullable — the receipt row exists after CM 02 and the draining is measured on a later
-- afternoon (Finding 6). Coalescing it to received_weight_kg would report a pending figure
-- computed from a weight R18 does not name, on a lot nobody has finished weighing.
--
-- SCOPE (R34, BR15): L1 all, L3 their own assigned lots, L2 nothing — F6 is not a branch
-- feature. The role test is in the WHERE rather than in a policy because the base tables
-- have RLS on with no policies; this is a SECURITY DEFINER view (the Postgres default),
-- never security_invoker.
--
-- NO PRICE AND NO YIELD COLUMN EXISTS HERE AT ALL, which is how BR15 is met — an L3 session
-- cannot read what the view does not select, and a later card adding a cost column has to do
-- it visibly rather than by widening a grant (TC-33's shape, TC-15's slice).
--
-- Covered by supabase/tests/production_test.sql (TC-30 ... TC-32, TC-34 ... TC-36).

create or replace view public.v_lot_pending_work as
select
  l.id                     as lot_id,
  l.lot_code,
  l.state,
  l.chef_house_location_id,
  l.assigned_operator_id,
  r.event_date             as receipt_date,
  r.received_weight_kg,
  r.post_drain_weight_kg,
  coalesce(s.consumed_weight_kg, 0)                        as input_consumed_kg,
  r.post_drain_weight_kg - coalesce(s.consumed_weight_kg, 0) as pending_weight_kg
from lots l
join lot_receipts r on r.lot_id = l.id
left join (
  select lot_id, sum(input_weight_kg) as consumed_weight_kg
    from smoke_daily_log_sources
   group by lot_id
) s on s.lot_id = l.id
where fn_current_role() = 'L1_OWNER'
   or (fn_current_role() = 'L3_CM_OPERATOR' and l.assigned_operator_id = auth.uid());

comment on view public.v_lot_pending_work is
  'R18 — post_drain_weight_kg minus the inputs drawn out of this lot, summed over '
  'smoke_daily_log_sources.lot_id (D05) and never over the logs filed under it. Never '
  'output-derived: smoked_weight_kg is not in this view on purpose. L1 all, L3 own assigned '
  'lots, L2 nothing (R34). No price and no yield column (BR15).';

revoke all    on public.v_lot_pending_work from anon, authenticated;
grant  select on public.v_lot_pending_work to   authenticated;
