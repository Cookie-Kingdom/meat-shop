-- v_sales_trace — F13's trace: sale date → smoke-date group → lot → PO → supplier, one row per
-- meat sales line (BR18, ADR-017, card ^ref-58; PLAN-reporting.md K17).
--
-- THE TRACE STOPS AT THE LOT, NOT THE BAG (BR18). A sales line names its lot and the smoke-date
-- group its READY balance was held on (fn_record_sales, R21); the group names its smoke date,
-- the lot its PO, the PO its supplier. An opening lot has no PO and no supplier: those columns
-- are null and the screen reads สต็อกตั้งต้น (ADR-021).
--
-- NO MONEY COLUMN. The trace is provenance, not price; the price is 200's. It is still L1 only,
-- because it names suppliers and POs, which are the Owner's (R20).
--
-- SECURITY DEFINER (the default), never security_invoker.
--
-- Covered by supabase/tests/reports_dashboard_test.sql (TC-41).

create or replace view public.v_sales_trace as
select s.id                         as sales_line_id,
       r.report_date                as business_date,
       r.location_id,
       loc.name_th                  as location_name_th,
       p.code                       as product_code,
       p.name_th                    as product_name_th,
       s.qty::numeric(12,2)         as sold_qty,
       s.pack_weight_kg,
       s.smoke_date_group_id,
       g.smoke_date,
       s.lot_id,
       l.lot_code,
       l.is_opening,
       l.po_id,
       po.po_number,
       po.supplier_id,
       sup.name                     as supplier_name
  from sales_lines s
  join daily_reports r          on r.id   = s.daily_report_id
  join products p               on p.id   = s.product_id
  join locations loc            on loc.id = r.location_id
  join lots l                   on l.id   = s.lot_id
  left join smoke_date_groups g on g.id   = s.smoke_date_group_id
  left join purchase_orders po  on po.id  = l.po_id
  left join suppliers sup       on sup.id = po.supplier_id
 where p.item_type = 'SMOKED_MEAT'
   and fn_current_role() = 'L1_OWNER';

comment on view public.v_sales_trace is
  'F13 / BR18 — each meat sales line traced to its smoke-date group, lot, PO and supplier (null '
  'PO and supplier for an opening lot). No money column. L1 only (R34, R20).';

revoke all    on public.v_sales_trace from anon, authenticated;
grant  select on public.v_sales_trace to   authenticated;
