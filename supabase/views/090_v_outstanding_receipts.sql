-- v_outstanding_receipts — dispatched and not yet fully signed for (D06, card ^ref-24).
--
-- TWO WAYS A LINE IS OUTSTANDING, and the view has to show both or it shows the easy one.
-- received_weight_kg IS NULL is a line nobody has touched; outstanding_weight_kg > 0 is a
-- partial receipt that left a balance on the truck. The second is the one D06 exists for and
-- the one that disappears if the WHERE only asks whether a receipt row was written.
--
-- AGE COMES FROM transport_lines.created_at, WHICH IS WHY MIGRATION ...0010 ADDED IT. Before
-- it, a line had received_at and nothing else temporal: the dispatch date came from the run,
-- which is right, but "how long has this been outstanding" had no answer at all, and BR12's
-- alert had no clock to fire against (Finding 2). age_days is the derived figure; the raw
-- timestamp is exposed beside it so a screen never has to re-derive it a second way.
--
-- SCOPE, from API_DATA_MODEL.md's view table: all for L1, own branch for L2, nothing for L3.
-- The L3 em dash is the doc's, not an omission here — the CM operator's inbound work arrives
-- through F6's lot views, and a chef house line that has not been received is L1's problem
-- until it is. Worth confirming with the Owner before OW 02 ships, and recorded as such in
-- v.0.1/PLAN-transport.md rather than quietly widened.
--
-- No money column, so no R20 exposure at either scope. SECURITY DEFINER (the Postgres
-- default), never security_invoker — the base tables have RLS on with no policies (R34).
--
-- Covered by supabase/tests/transport_test.sql (TC-39) and transport_schema_test.sql
-- (TC-38).

create or replace view public.v_outstanding_receipts as
select
  tl.id                    as line_id,
  tr.id                    as run_id,
  tr.route,
  tr.event_date            as dispatch_date,
  tr.vehicle_type,
  l.lot_code,
  tl.lot_id,
  tl.smoke_date_group_id,
  tl.from_location_id,
  tl.to_location_id,
  tl.dispatched_weight_kg,
  tl.received_weight_kg,
  -- null received means nothing has been signed for, so the whole dispatch is outstanding.
  -- The generated column is null in that case too, by the same arithmetic.
  coalesce(tl.outstanding_weight_kg, tl.dispatched_weight_kg) as outstanding_weight_kg,
  tl.created_at            as dispatched_at,
  (current_date - tl.created_at::date)                        as age_days
from transport_lines tl
join transport_runs tr on tr.id = tl.run_id
join lots l            on l.id  = tl.lot_id
where (tl.received_weight_kg is null or tl.outstanding_weight_kg > 0)
  and (fn_current_role() = 'L1_OWNER'
    or (fn_current_role() = 'L2_BRANCH_ADMIN'
        and (tl.to_location_id = any (fn_current_locations())
          or tl.from_location_id = any (fn_current_locations()))));

comment on view public.v_outstanding_receipts is
  'D06 — lines never signed for, and partial receipts that left a balance in IN_TRANSIT. '
  'age_days derives from transport_lines.created_at, added by migration ...0010. '
  'L1 all, L2 either end of their own branch, L3 nothing (R34).';

revoke all    on public.v_outstanding_receipts from anon, authenticated;
grant  select on public.v_outstanding_receipts to   authenticated;
