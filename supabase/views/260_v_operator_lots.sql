-- v_operator_lots — CM 01's "My Lots", and the lot header every CM screen stands on
-- (v0.2 line 78, R34, BR15, R20, card ^ref-30).
--
-- WHY IT EXISTS. CM 01 shows the operator their own assigned lots, the weight the Owner
-- declared and the status (v0.2 line 78), and a lot shows up there once OW 02 has set it
-- IN_TRANSIT (v0.2 line 103). Neither existing read path can say that: v_lot_pending_work
-- inner-joins lot_receipts, so a lot still on the truck is not in it, and v_lot_progress has
-- every lot but not the declared weight. lots itself is deny-all (lots.sql). One view, one
-- row per lot, the receipt left-joined.
--
-- foodiva_sent_weight_kg IS HERE ON PURPOSE AND loss_weight_kg IS NOT. The declared dispatch
-- weight is what v0.2 puts in front of the operator on CM 01 and CM 02 ("เทียบกับน้ำหนัก
-- Foodiva ส่งออก"). The stored lost weight (...0015) is dispatch minus output — with the
-- dispatch weight beside it, it IS the loss %, which UAT-15 keeps from an L3 (v0.2 line 441).
-- So is every other yield-bearing figure: there is no yield, loss, price, cost, fee or
-- freight column in this view for any role, which is how BR15 is met rather than by leaving
-- it out of a select list. cm_screens_test.sql sweeps the column names, so adding one fails
-- the suite instead of passing review.
--
-- OPENING LOTS ARE LEFT OUT. is_opening lots (^ref-62) are created at LOT_CLOSED with no
-- dispatch weight, no chef house and no operator — their production finished before the
-- software existed, so they never pass through a CM screen.
--
-- closed_by_name IS THE SIGNER, for LockIndicator's "who and when" (LAYOUT-SKELETONS'
-- LOCKED state). A display name, not a profile row: profiles stays behind its own policy.
--
-- SCOPE (R34, BR15): L1 all, L3 their own assigned lots, L2 nothing — F6 is not a branch
-- feature. Same shape as v_lot_pending_work and v_lot_progress: the role test is in the
-- WHERE because the base tables have RLS on with no policies, and this is a SECURITY
-- DEFINER view (the Postgres default), never security_invoker.
--
-- Depends on no other view. Covered by supabase/tests/cm_screens_test.sql (TC-56).

create or replace view public.v_operator_lots as
select
  l.id                     as lot_id,
  l.lot_code,
  l.state,
  l.event_date             as lot_date,
  l.chef_house_location_id,
  loc.name_th              as chef_house_name,
  l.assigned_operator_id,
  l.foodiva_sent_weight_kg,
  r.event_date             as receipt_date,
  r.received_weight_kg,
  r.post_drain_weight_kg,
  r.variance_reason,
  l.closed_at,
  cb.display_name          as closed_by_name
from lots l
left join lot_receipts r on r.lot_id = l.id
left join locations  loc on loc.id  = l.chef_house_location_id
left join profiles    cb on cb.id   = l.closed_by
where not l.is_opening
  and (   fn_current_role() = 'L1_OWNER'
       or (fn_current_role() = 'L3_CM_OPERATOR' and l.assigned_operator_id = auth.uid()));

comment on view public.v_operator_lots is
  'CM 01 — one row per non-opening lot with its receipt left-joined: the declared dispatch '
  'weight (v0.2 line 78), the state, the two receipt weights and who closed it. No price, '
  'cost, yield, loss, fee or freight column for any role (BR15, UAT-15); loss_weight_kg is '
  'left out on purpose. L1 all, L3 own assigned lots, L2 nothing (R34).';

revoke all    on public.v_operator_lots from anon, authenticated;
grant  select on public.v_operator_lots to   authenticated;
