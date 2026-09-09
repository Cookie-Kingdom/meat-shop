-- v_po_outstanding — ordered against dispatched against received, one row per PO (UAT-01).
--
-- DERIVED, NEVER STORED. There is no dispatched_weight_kg or outstanding_weight_kg column
-- on purchase_orders and there never will be, for the same reason ADR-003 forbids a balance
-- column on stock: a stored cumulative and the rounds it summarises diverge the first time
-- a write half-fails, and after that nobody can say which one is right. It is SUM over the
-- rows or it is nothing (D01, F4 clause 3).
--
-- LEFT JOIN throughout. A PO with no round yet reads dispatched 0.00, outstanding =
-- ordered — never a null row and never an absent one. That PO is precisely the one the
-- Owner opened the screen to find (TC-28).
--
-- received_weight_kg IS A CROSS-CHECK FIGURE AND NOTHING ELSE (R16a, ADR-011). It sits in
-- an Owner-facing view next to dispatched_weight_kg, which is exactly where somebody starts
-- subtracting one from the other and calling the difference loss. It is not loss. The loss
-- base is lots.foodiva_sent_weight_kg — the weight that left Foodiva — and the yield
-- divisor is that and only that (BR03, R16). Dispatch 100, CM receives 98, post-smoke 75
-- reads 25%, not 23.47%. No report may label either figure "loss".
--
-- It comes from lot_receipts, whose writer is fn_record_lot_receipt (^ref-26). The table
-- exists in ...0003 and is simply empty until that card lands, which is what the coalesce
-- is for — no dependency on ^ref-25/^ref-26 is created. Not from
-- transport_lines.received_weight_kg: lot_receipts is the row R16a names as the CM
-- cross-check. If the two ever disagree at ^ref-22, pick one and say why; do not average.
--
-- L1 ONLY, AND THAT CANNOT BE A GRANT. There is one database role for application users —
-- `authenticated` — and L1/L2/L3 lives on profiles, so R20's "L3 has no grant" has to be a
-- WHERE clause (R34), the same pattern as v_stock_balance. An L3 session gets zero rows
-- from the database rather than a hidden nav item, and that is how F4's "the CM operator
-- never sees any price field" is actually enforced (ADR-004). A screen that works around it
-- by selecting the underlying tables gets permission denied — they are deny-all (TC-33).
--
-- SECURITY DEFINER (the Postgres default), not security_invoker: purchase_orders has RLS on
-- with no policies, so an invoker view would return nothing for every role including L1.
-- Standing consequence, same as v_stock_balance's — never force row level security on these
-- tables.
--
-- Covered by supabase/tests/purchasing_test.sql (TC-27 ... TC-32).

create or replace view public.v_po_outstanding as
select
  po.id                       as po_id,
  po.po_number,
  po.supplier_id,
  s.name                      as supplier_name,
  po.event_date               as order_date,
  po.ordered_weight_kg,
  coalesce(d.dispatched_weight_kg, 0)::numeric(12,2) as dispatched_weight_kg,
  -- cross-check only (R16a) — never a loss base, never a yield divisor
  coalesce(r.received_weight_kg, 0)::numeric(12,2)   as received_weight_kg,
  (po.ordered_weight_kg - coalesce(d.dispatched_weight_kg, 0))::numeric(12,2)
                              as outstanding_weight_kg,
  coalesce(d.round_count, 0)  as round_count
from purchase_orders po
join suppliers s on s.id = po.supplier_id
left join (
  select po_id,
         sum(foodiva_sent_weight_kg) as dispatched_weight_kg,
         count(*)                    as round_count
    from po_deliveries
   group by po_id
) d on d.po_id = po.id
left join (
  -- per PO, over its lots: one receipt per lot, so no round is double-counted
  select l.po_id, sum(lr.received_weight_kg) as received_weight_kg
    from lot_receipts lr
    join lots l on l.id = lr.lot_id
   group by l.po_id
) r on r.po_id = po.id
where fn_current_role() = 'L1_OWNER';

comment on view public.v_po_outstanding is
  'UAT-01. dispatched/outstanding are derived from po_deliveries (D01). received_weight_kg '
  'is a CM cross-check only (R16a) — the loss base and yield divisor is '
  'lots.foodiva_sent_weight_kg (BR03, ADR-011). L1 only, enforced in the WHERE (R34).';

grant select on public.v_po_outstanding to authenticated;
