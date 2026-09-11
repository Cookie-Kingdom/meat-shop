-- v_daily_sales_qty — v_daily_sales without the money, for the branch (R34, BR15, card ^ref-55;
-- PLAN-reporting.md K2, Finding 1).
--
-- THIS VIEW IS HOW "L2 SEES QUANTITY ONLY" IS ENFORCED. There is one database role, so a grant
-- on revenue_thb would reach L1, L2 and L3 alike. R34's answer is a separately granted view with
-- no money-shaped column at all: an L2 selecting revenue_thb here gets 42703 undefined_column
-- from the catalogue (TC-R4), and v_daily_sales gives the same session zero rows (TC-R3). No
-- column anywhere is nulled per role — a blanked column would be a third access shape.
--
-- It reads the base tables, not 200: 200's WHERE is L1-only, so an L2 would read nothing
-- through it. The grain and every non-money column are 200's, in 200's order.
--
-- SCOPE is v_stock_balance's: L1 all branches, an L2 their own, L3 none (R34, R20).
-- SECURITY DEFINER (the default), never security_invoker.
--
-- 203_v_monthly_summary_qty reads this view. Changing its column list means dropping 203 in the
-- same change, never adding CASCADE.
--
-- Covered by supabase/tests/reports_sales_test.sql (TC-R1 ... TC-R7) and
-- reports_schema_test.sql (TC-S04).

create or replace view public.v_daily_sales_qty as
select r.report_date                     as business_date,
       to_char(r.report_date, 'YYYY-MM') as sales_month,
       r.location_id,
       l.name_th                         as location_name_th,
       r.id                              as daily_report_id,
       r.status                          as report_status,
       p.id                              as product_id,
       p.code                            as product_code,
       p.name_th                         as product_name_th,
       p.item_type,
       p.sale_unit,
       sum(s.qty)::numeric(12,2)         as sold_qty,
       count(*)                          as line_count
  from sales_lines s
  join daily_reports r on r.id = s.daily_report_id
  join products p      on p.id = s.product_id
  join locations l     on l.id = r.location_id
 where fn_current_role() = 'L1_OWNER'
    or (fn_current_role() = 'L2_BRANCH_ADMIN' and r.location_id = any (fn_current_locations()))
 group by r.report_date, r.location_id, l.name_th, r.id, r.status,
          p.id, p.code, p.name_th, p.item_type, p.sale_unit;

comment on view public.v_daily_sales_qty is
  'M12.1, R34 — v_daily_sales with no money column: quantity per branch, business day and SKU. '
  'L1 all branches, L2 own branches, L3 none. Selecting revenue_thb here is 42703 by design.';

revoke all    on public.v_daily_sales_qty from anon, authenticated;
grant  select on public.v_daily_sales_qty to   authenticated;
