-- v_po_rounds — one row per dispatch round, with the lot it created (card ^ref-20, lane F).
--
-- D01 IS THIS VIEW'S WHOLE JOB. One PO delivered over several rounds is several lots, and
-- the screen has to make that obvious: PO 100 kg, rounds of 40 and 30 are TWO lots, each
-- with its own code, not one PO with a weight on it (UAT-01). v_po_outstanding has only
-- round_count, which says how many and not which — so the Owner could not see the lot a
-- round created, and OW 02 could not pick the lots waiting for a truck.
--
-- Inner join to lots on purpose. lots.po_delivery_id is UNIQUE and fn_add_po_delivery
-- writes the round and its lot in one transaction, so a round with no lot is a state D01
-- forbids. If one ever appears, it is missing here rather than shown as a lot-less round
-- that looks legitimate.
--
-- NO PRICE COLUMN. Weights, dates, codes and state only. The lot codes and weights are
-- still L1-only here — v0.2 gives the CM operator "ดู Batch ที่ส่งมา" through F6's own lot
-- views, which carry their own scope, and this view is not one of them. TC-S04 asserts no
-- price, cost, thb or brine column ever lands on it.
--
-- foodiva_sent_weight_kg is the round's weight, which fn_add_po_delivery copies onto the lot
-- and freezes as the loss base (BR03, R16, ADR-011). OW 02 dispatches exactly this weight
-- (PLAN-transport.md, ^ref-24 build notes), so the lot cannot carry two "sent" weights.
--
-- SECURITY DEFINER (the Postgres default), never security_invoker — po_deliveries, lots,
-- purchase_orders, suppliers and locations all have RLS on with no policies (R34).
--
-- Covered by supabase/tests/purchasing_screen_test.sql (TC-S02 ... TC-S04, TC-S08).

create or replace view public.v_po_rounds as
select
  d.id                       as delivery_id,
  d.po_id,
  po.po_number,
  s.name                     as supplier_name,
  d.seq,
  d.event_date               as dispatch_date,
  d.foodiva_sent_weight_kg,
  l.id                       as lot_id,
  l.lot_code,
  l.state                    as lot_state,
  l.chef_house_location_id,
  loc.name_th                as chef_house_name,
  d.note
from po_deliveries d
join purchase_orders po on po.id = d.po_id
join suppliers s        on s.id  = po.supplier_id
join lots l             on l.po_delivery_id = d.id
left join locations loc on loc.id = l.chef_house_location_id
where fn_current_role() = 'L1_OWNER';

comment on view public.v_po_rounds is
  'D01 / UAT-01 — one row per dispatch round with the lot it created (lot_code = '
  '<po_number>-<seq>). Weights and state only, no price. L1 only via the WHERE (R34).';

revoke all    on public.v_po_rounds from anon, authenticated;
grant  select on public.v_po_rounds to   authenticated;
