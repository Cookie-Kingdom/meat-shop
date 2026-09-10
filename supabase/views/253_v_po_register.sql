-- v_po_register — the OW 01 list: a PO's terms beside its derived progress (card ^ref-20,
-- lane F).
--
-- WHY IT EXISTS. ^ref-20's acceptance line is "records a PO with supplier, ordered weight,
-- price, brine offer and brine cost". Once saved, those have to be readable, and
-- purchase_orders is deny-all. v_po_outstanding carries the progress and none of the terms.
--
-- IT READS FROM v_po_outstanding, NOT FROM po_deliveries. Dispatched and outstanding are
-- derived once, there (D01, F4 clause 3). A second SUM here would be a second derivation
-- that can disagree with the first, which is the failure ADR-003 forbids for balances.
-- TC-S06 asserts the two agree row for row. 253 > 030, so the dependency respects the
-- apply order (R33).
--
-- THE DATABASE DOES THE MONEY ARITHMETIC. meat_total_thb = ordered x price/kg, and
-- brine_offered_kg = ordered x brine % / 100, both round(..., 2) — numeric, never a JS
-- number (CLAUDE.md). The OW 01 form previews the same figures before submit; this is the
-- figure that is kept. Null in, null out: a PO saved with no price has no total, not a
-- total of 0.00, and a PO with no brine offer has no brine weight.
--
-- received_weight_kg IS LEFT OUT DELIBERATELY. It is a cross-check figure (R16a, ADR-011),
-- and a register row with ordered, sent and received side by side is where somebody starts
-- subtracting received from sent and calling it loss. It stays on v_po_outstanding, under
-- that view's own warning.
--
-- L1 ONLY, IN THE WHERE (R34, R20). Every money column on the PO is here, and v0.2's
-- permission table gives L2 no access to purchasing and L3 no price.
--
-- SECURITY DEFINER (the Postgres default), never security_invoker — purchase_orders has RLS
-- on with no policies.
--
-- Covered by supabase/tests/purchasing_screen_test.sql (TC-S02, TC-S05 ... TC-S08).

create or replace view public.v_po_register as
select
  o.po_id,
  o.po_number,
  o.supplier_id,
  o.supplier_name,
  o.order_date,
  o.ordered_weight_kg,
  o.dispatched_weight_kg,
  o.outstanding_weight_kg,
  o.round_count,
  po.unit_price_thb_per_kg,
  po.brine_pct_offered,
  po.brine_cost_thb,
  round(po.ordered_weight_kg * po.unit_price_thb_per_kg, 2)::numeric(12,2)
                                as meat_total_thb,
  round(po.ordered_weight_kg * po.brine_pct_offered / 100, 2)::numeric(12,2)
                                as brine_offered_kg,
  po.note,
  po.created_at
from v_po_outstanding o
join purchase_orders po on po.id = o.po_id
where fn_current_role() = 'L1_OWNER';

comment on view public.v_po_register is
  'OW 01 list. v_po_outstanding''s derived progress (D01) beside the PO''s terms; '
  'meat_total_thb and brine_offered_kg computed here, never in the client. No '
  'received_weight_kg (R16a). L1 only via the WHERE (R34, R20).';

revoke all    on public.v_po_register from anon, authenticated;
grant  select on public.v_po_register to   authenticated;
