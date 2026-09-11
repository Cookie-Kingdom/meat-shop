-- v_daily_sales — what each branch sold each business day, per SKU, with the money (M12.1,
-- card ^ref-55; PLAN-reporting.md K1, Finding 1).
--
-- REVENUE IS THE SNAPSHOT ON THE LINE (BR23, R29). sales_lines.unit_price_thb is the price
-- fn_record_sales resolved at the report's business date, so a price entered next month cannot
-- move a closed day (TC-05). Rounded per line, then summed: Σ round(qty × unit_price_thb, 2).
-- No product_prices read anywhere in this view.
--
-- ROUND ONE IS LINE MAN ONLY (D04). revenue_source is the literal 'LINE_MAN', matching the
-- constant fn_record_sales writes into sales_lines.channel. It is a stated scope on the row's
-- face (UAT-17), not a grouping key; the day M13 adds a channel, this becomes a column.
--
-- GRAIN (business_date, location_id, product_id). business_date is the report's report_date
-- (ADR-007, ADR-014), never created_at. A box and an add-on bag are two SKUs and stay two rows
-- (D03.1, TC-02). An OPEN day is present and says so in report_status (TC-04). A day with no
-- sales has no row here; v_monthly_summary counts it through daily_reports.
--
-- L1 ONLY, AS A WHERE (R34, R20). One database role carries every app user, so a column grant
-- cannot separate L1 from L2. An L2 or L3 session reads zero rows here and reads quantities
-- from v_daily_sales_qty, which has no money column at all, so `select revenue_thb` there is
-- 42703 (Finding 1). SECURITY DEFINER (the default), never security_invoker: the base tables
-- are deny-all.
--
-- 202_v_monthly_summary reads this view. Changing its column list means dropping 202 in the
-- same change, never adding CASCADE.
--
-- Covered by supabase/tests/reports_sales_test.sql (TC-01 ... TC-06, TC-R1, TC-R3) and
-- reports_schema_test.sql.

create or replace view public.v_daily_sales as
select r.report_date                                          as business_date,
       to_char(r.report_date, 'YYYY-MM')                      as sales_month,
       r.location_id,
       l.name_th                                              as location_name_th,
       r.id                                                   as daily_report_id,
       r.status                                               as report_status,
       p.id                                                   as product_id,
       p.code                                                 as product_code,
       p.name_th                                              as product_name_th,
       p.item_type,
       p.sale_unit,
       sum(s.qty)::numeric(12,2)                              as sold_qty,
       sum(round(s.qty * s.unit_price_thb, 2))::numeric(12,2) as revenue_thb,
       count(*)                                               as line_count,
       'LINE_MAN'::text                                       as revenue_source
  from sales_lines s
  join daily_reports r on r.id = s.daily_report_id
  join products p      on p.id = s.product_id
  join locations l     on l.id = r.location_id
 where fn_current_role() = 'L1_OWNER'
 group by r.report_date, r.location_id, l.name_th, r.id, r.status,
          p.id, p.code, p.name_th, p.item_type, p.sale_unit;

comment on view public.v_daily_sales is
  'M12.1 — sales per branch, business day and SKU. revenue_thb = Σ round(qty × the BR23 price '
  'snapshot, 2); revenue_source = LINE_MAN (D04 round-one scope). L1 only in the WHERE (R34); '
  'L2 reads v_daily_sales_qty.';

revoke all    on public.v_daily_sales from anon, authenticated;
grant  select on public.v_daily_sales to   authenticated;
