-- v_lot_yield — the finished lot's Loss and smoke yield, under two names that cannot be
-- confused (ADR-011, R16a, R17, card ^ref-31).
--
--   loss_pct        = loss_weight_kg / foodiva_sent_weight_kg × 100     the headline, BR03
--   smoke_yield_pct = output_weight_kg / pre_smoke_weight_kg × 100      Chiang Mai's figure
--
-- THE DIVISOR OF LOSS IS THE FOODIVA DISPATCH WEIGHT, NEVER THE CM RECEIVED WEIGHT (ADR-011,
-- UAT-02). Dispatch 100, CM receives 98, post-smoke 75 reads 25.00, not 23.47. The received
-- weight is a cross-check figure and is shown as cm_received_weight_kg; no column built on it
-- or on the pre-smoke weight carries the word "loss" (TC-04). Only loss_weight_kg and
-- loss_pct do, and both are on the dispatch base.
--
-- ONE NUMBER, NOT TWO. loss_weight_kg is the column fn_close_lot stored at close (…0015):
-- dispatch minus Σ smoke_date_groups.packed_weight_kg at that moment. output_weight_kg is
-- derived back from it rather than re-summed from the groups, so this view, the YIELD_ALERT
-- payload and every later screen divide the same two numbers (v0.2 line 299).
--
-- smoke_yield_pct DIVIDES BY THE PRE-SMOKE WEIGHT, lot_receipts.post_drain_weight_kg
-- (PLAN-lots Finding 9, v0.2 line 80: CM 03 "เป็นฐานคำนวณ Smoke Yield"). It is null when
-- that weight was never entered — "ข้อมูลไม่ครบ", never a division by zero (v0.2 line 349).
--
-- R17: CLOSED LOTS ONLY. A lot still smoking has partial output against a full dispatch —
-- a progress figure, which v_lot_progress carries without any division. `state >=
-- 'LOT_CLOSED'` relies on lot_state's declaration order, as fn_guard_lot_closed does.
--
-- OPENING LOTS ARE EXCLUDED. ADR-021: they have no dispatch weight, so there is no Loss base,
-- and their production happened before the software existed.
--
-- yield_alert IS THE ALERT THAT WAS RAISED, NOT A SECOND VERDICT. fn_close_lot runs ADR-019's
-- fn_check_variance and writes one YIELD_ALERT notification past threshold; this column says
-- whether that row exists. Recomputing `loss_pct > threshold` here would be a second
-- boundary rule that could disagree with the first at exactly 20.00 (R16).
--
-- alert_threshold_pct IS READ FROM config_settings DIRECTLY, NOT THROUGH fn_config_numeric.
-- A view's function calls run with the CALLER's privileges (only relation access runs as the
-- view owner), and fn_config_* is granted to nobody (rls_deny_all 1f) — calling it here would
-- refuse every L1 read. It would also raise CONFIG_NOT_SET for the whole view. The lateral
-- select below is fn_config_value's resolution for a global key: scope null, effective_from
-- on or before the close date, newest first (R12). Resolved at closed_at::date — the same
-- day, in the same session timezone, that fn_close_lot's `current_date` used.
--
-- L1 ONLY, AS A WHERE (R34, R20). There is one database role for application users, so a
-- grant reaches L1, L2 and L3 alike; the role test is in the WHERE and an L2 or L3 session
-- reads zero rows. Price-free but yield-bearing: BR15 and UAT-15 keep yield from the chef
-- house. SECURITY DEFINER (the Postgres default), never security_invoker — every base table
-- here has RLS on with no policies.
--
-- Covered by supabase/tests/cost_yield_test.sql (TC-01 ... TC-08).

create or replace view public.v_lot_yield as
select
  l.id                                                     as lot_id,
  l.lot_code,
  l.state,
  l.closed_at,
  l.chef_house_location_id,
  l.po_id,
  po.po_number,
  l.foodiva_sent_weight_kg,
  r.received_weight_kg                                     as cm_received_weight_kg,
  r.post_drain_weight_kg                                   as pre_smoke_weight_kg,
  (l.foodiva_sent_weight_kg - l.loss_weight_kg)::numeric(12,2)
                                                           as output_weight_kg,
  l.loss_weight_kg,
  round(l.loss_weight_kg / nullif(l.foodiva_sent_weight_kg, 0) * 100, 2)
                                                           as loss_pct,
  round((l.foodiva_sent_weight_kg - l.loss_weight_kg)
        / nullif(r.post_drain_weight_kg, 0) * 100, 2)      as smoke_yield_pct,
  exists (select 1
            from notifications n
           where n.lot_id = l.id
             and n.kind = 'YIELD_ALERT')                   as yield_alert,
  t.value_numeric                                          as alert_threshold_pct
from lots l
left join purchase_orders po on po.id = l.po_id
left join lot_receipts r     on r.lot_id = l.id
left join lateral (
  select c.value_numeric
    from config_settings c
   where c.key = 'yield_alert_threshold_pct'
     and c.scope_location_id is null
     and c.effective_from <= l.closed_at::date
   order by c.effective_from desc
   limit 1
) t on true
where l.state >= 'LOT_CLOSED'
  and not l.is_opening
  and fn_current_role() = 'L1_OWNER';

comment on view public.v_lot_yield is
  'ADR-011, R16a, R17 — a closed lot''s Loss on the Foodiva dispatch base (loss_pct, from the '
  'stored lots.loss_weight_kg) and its smoke yield on the pre-smoke base (smoke_yield_pct), '
  'under separate names; the CM received weight is a cross-check, never a divisor. Closed, '
  'non-opening lots only. yield_alert is the YIELD_ALERT fn_close_lot raised. L1 only, in the '
  'WHERE (R34, R20). No price column.';

revoke all    on public.v_lot_yield from anon, authenticated;
grant  select on public.v_lot_yield to   authenticated;
