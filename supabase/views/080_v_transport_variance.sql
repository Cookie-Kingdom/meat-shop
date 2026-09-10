-- v_transport_variance — dispatched against received, per line, with the reason (UAT-11,
-- BR12, cards ^ref-23 / ^ref-24).
--
-- THE PERCENTAGE COMES FROM fn_check_variance AND NOT FROM transport_lines.variance_pct
-- (ADR-019, R22, Seam 4). The generated column rounds to 4 decimals and compares raw; the
-- function rounds to 2 and then compares, so at a 20% tolerance they disagree on a line that
-- is 20.004% off. fn_confirm_transport_receipt already took its verdict from the function,
-- and a view that displayed the column instead would put a different number on screen from
-- the one that decided whether a reason was demanded. TC-21 asserts the two disagree on a
-- constructed case, so the day somebody "simplifies" this select onto the column, the suite
-- says why they must not.
--
-- THERE IS NO VERDICT COLUMN HERE, AND THAT IS NOT AN OVERSIGHT. A verdict needs a
-- threshold, the threshold is receipt_variance_threshold_pct resolved by event date, and
-- fn_config_numeric is granted to nobody — deliberately, because config_settings holds
-- prices and R20 keeps an L3 session out of them. A view calls its functions as the invoking
-- session, not as the view owner, so this view cannot resolve a dated threshold without
-- opening exactly the read path ^ref-12 closed. The percentage is threshold-independent and
-- is what the screen needs; the verdict that mattered was taken at write time, and
-- variance_reason is the record that it was.
--
-- SCOPE, from API_DATA_MODEL.md's view table: all for L1, own branch for L2, own lots for
-- L3. "Own branch" is either end of the line, because a branch that sent something has the
-- same interest in the variance as one that received it. "Own lots" is
-- lots.assigned_operator_id — the CM operator sees the lines for the lots they are working,
-- which is narrower than every line touching the chef house and is what the table says.
--
-- No money column appears here at all, so the L2 and L3 rows carry no R20 exposure. The
-- freight share lives in v_freight_allocation, which is L1 only.
--
-- SECURITY DEFINER (the Postgres default), never security_invoker — the base tables have RLS
-- on with no policies (R34).
--
-- Covered by supabase/tests/transport_test.sql (TC-37) and transport_schema_test.sql
-- (TC-21, TC-38).

create or replace view public.v_transport_variance as
select
  tl.id                    as line_id,
  tr.id                    as run_id,
  tr.route,
  tr.event_date            as dispatch_date,
  l.lot_code,
  tl.lot_id,
  tl.smoke_date_group_id,
  tl.from_location_id,
  tl.to_location_id,
  tl.dispatched_weight_kg,
  tl.received_weight_kg,
  tl.outstanding_weight_kg,
  -- ADR-019's number, not the generated column's. Mode ALERT never raises; the default
  -- threshold is irrelevant to variance_pct, which is why only that field is taken.
  (fn_check_variance(tl.received_weight_kg, tl.dispatched_weight_kg, 'ALERT')).variance_pct
                           as variance_pct,
  tl.variance_reason,
  tl.variance_settlement,
  tl.received_by,
  tl.received_at,
  tl.created_at            as dispatched_at
from transport_lines tl
join transport_runs tr on tr.id = tl.run_id
join lots l            on l.id  = tl.lot_id
where fn_current_role() = 'L1_OWNER'
   or (fn_current_role() = 'L2_BRANCH_ADMIN'
       and (tl.to_location_id = any (fn_current_locations())
         or tl.from_location_id = any (fn_current_locations())))
   or (fn_current_role() = 'L3_CM_OPERATOR' and l.assigned_operator_id = auth.uid());

comment on view public.v_transport_variance is
  'UAT-11 / BR12. variance_pct is fn_check_variance''s figure (ADR-019), never '
  'transport_lines.variance_pct — the two disagree at the third decimal. No verdict column: '
  'a dated threshold needs fn_config_numeric, which no session may execute (R20). '
  'L1 all, L2 either end of their own branch, L3 their assigned lots (R34).';

revoke all    on public.v_transport_variance from anon, authenticated;
grant  select on public.v_transport_variance to   authenticated;
