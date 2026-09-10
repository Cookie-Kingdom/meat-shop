-- v_lot_progress — how far through the smoker this lot is (R17, R34, BR15, card ^ref-27).
--
-- Days logged, what has gone in, and what has come back out. CM 05 reads it, and OW 03 reads
-- it for a lot that has not been closed yet.
--
-- R17 IS IMPLEMENTED AS COLUMNS THAT DO NOT EXIST. "A lot still in SMOKING is never evaluated
-- for final loss — partial output against a full dispatch is a progress figure, not a Loss
-- figure." Every ingredient of that division is in this view and the division is not: there is
-- no loss_pct, no yield_pct and no percentage of any kind, for any role. A figure that is not
-- selected cannot be mislabelled on a screen, and ^ref-31's v_lot_yield — which filters on
-- lots.state and is where a final figure belongs — has to be written rather than reached for.
-- TC-33 asserts the absence, so restoring one of them fails the suite.
--
-- OUTPUT COMES FROM THE SMOKE-DATE GROUPS, NOT FROM THE LOG (Finding 7). PRODUCT.md's CM 04
-- totals output from the pack lines, and the pack lines hang off smoke_date_groups. So
-- packed_weight_kg and bag_count here are ...0013's trg_rollup_smoke_group_packed roll-up
-- summed over the lot's groups; smoke_daily_logs.packed_weight_kg and .bag_count are a third
-- copy of that number, are never written by anything, and are not read here.
--
-- smoked_weight_kg IS THE LOGS' FIGURE AND IS A DIFFERENT THING. What came off the racks that
-- day, before packing — the operator's own reading, not derived from the bags. It is left NULL
-- rather than coalesced to zero when no day has recorded one, because "no output entered yet"
-- and "nothing came out" are different states and CM 05 renders them differently.
--
-- input_consumed_kg SUMS OVER sources.lot_id, NOT OVER THE LOGS FILED UNDER THE LOT — the same
-- D05 join v_lot_pending_work's header argues at length (Seam 2). The two views are two halves
-- of one number and joining them differently is how they would stop adding up: on a cross-lot
-- day, consumed + pending equals post_drain only if both count by source lot.
--
-- days_logged IS THE OTHER RELATIONSHIP ON PURPOSE. A day the operator filed work for this
-- lot is smoke_daily_logs.lot_id, and R6's unique on (lot_id, event_date) makes count(*) the
-- day count with no distinct needed. Filing and sourcing are different questions and this view
-- answers one of each.
--
-- EVERY LOT THE ROLE CAN SEE, LOGGED OR NOT — a left join, not an inner one. A lot at
-- CM_RECEIVED with no log yet is exactly the row CM 05 needs to show as "nothing entered
-- today"; dropping it would make the screen's empty state depend on a view that has no row to
-- render it from.
--
-- SCOPE (R34, BR15): L1 all, L3 their own assigned lots, L2 nothing. Same shape and same
-- reasoning as v_lot_pending_work — the role test is in the WHERE because the base tables have
-- RLS on with no policies, and this is a SECURITY DEFINER view.
--
-- Covered by supabase/tests/production_test.sql (TC-19, TC-33 ... TC-36).

create or replace view public.v_lot_progress as
select
  l.id                             as lot_id,
  l.lot_code,
  l.state,
  l.chef_house_location_id,
  l.assigned_operator_id,
  coalesce(d.days_logged, 0)       as days_logged,
  d.first_log_date,
  d.last_log_date,
  coalesce(s.input_consumed_kg, 0) as input_consumed_kg,
  d.smoked_weight_kg,
  d.brine_used_kg,
  coalesce(g.packed_weight_kg, 0)  as packed_weight_kg,
  coalesce(g.bag_count, 0)         as bag_count
from lots l
left join (
  select lot_id,
         count(*)              as days_logged,
         min(event_date)       as first_log_date,
         max(event_date)       as last_log_date,
         sum(smoked_weight_kg) as smoked_weight_kg,
         sum(brine_used_kg)    as brine_used_kg
    from smoke_daily_logs
   group by lot_id
) d on d.lot_id = l.id
left join (
  select lot_id, sum(input_weight_kg) as input_consumed_kg
    from smoke_daily_log_sources
   group by lot_id
) s on s.lot_id = l.id
left join (
  select lot_id,
         sum(packed_weight_kg) as packed_weight_kg,
         sum(bag_count)        as bag_count
    from smoke_date_groups
   group by lot_id
) g on g.lot_id = l.id
where fn_current_role() = 'L1_OWNER'
   or (fn_current_role() = 'L3_CM_OPERATOR' and l.assigned_operator_id = auth.uid());

comment on view public.v_lot_progress is
  'R17 — days logged, input consumed and output so far, and NO percentage of any kind: '
  'partial output against a full dispatch is a progress figure, not a loss figure, so the '
  'division is left to v_lot_yield (^ref-31) after close. Output is the smoke-date groups '
  'roll-up (Finding 7), input is summed over smoke_daily_log_sources.lot_id (D05) like '
  'v_lot_pending_work, days are counted over the logs filed under the lot. L1 all, L3 own '
  'assigned lots, L2 nothing (R34). No price column (BR15).';

revoke all    on public.v_lot_progress from anon, authenticated;
grant  select on public.v_lot_progress to   authenticated;
