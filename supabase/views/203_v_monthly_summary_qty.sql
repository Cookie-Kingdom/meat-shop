-- v_monthly_summary_qty — v_monthly_summary without the money, for the branch (M12.2, R34,
-- card ^ref-55; PLAN-reporting.md K4, Finding 1).
--
-- A grouping of 201, so an L2's month equals the sum of the days 201 shows them. It states its
-- own role WHERE instead of trusting 201 alone (R34). No money-shaped column (TC-S04), so
-- `select revenue_thb` here is 42703 for everyone.
--
-- days_reported / days_closed are counted from daily_reports for the row's own location only,
-- so an L2 learns nothing about another branch's days.
--
-- SCOPE: L1 all branches, an L2 their own, L3 none. SECURITY DEFINER (the default).
--
-- Covered by supabase/tests/reports_sales_test.sql (TC-R2, TC-R4, TC-R5).

create or replace view public.v_monthly_summary_qty as
with rep as (
  select r.location_id,
         to_char(r.report_date, 'YYYY-MM')           as sales_month,
         count(*)                                    as days_reported,
         count(*) filter (where r.status = 'CLOSED') as days_closed
    from daily_reports r
   group by r.location_id, to_char(r.report_date, 'YYYY-MM')
)
select d.sales_month,
       d.location_id,
       d.location_name_th,
       d.product_id,
       d.product_code,
       d.product_name_th,
       d.item_type,
       d.sale_unit,
       sum(d.sold_qty)::numeric(12,2)      as sold_qty,
       count(*)                            as days_with_sales,
       rep.days_reported,
       rep.days_closed,
       rep.days_reported = rep.days_closed as is_complete
  from v_daily_sales_qty d
  join rep on rep.location_id = d.location_id and rep.sales_month = d.sales_month
 where fn_current_role() = 'L1_OWNER'
    or (fn_current_role() = 'L2_BRANCH_ADMIN' and d.location_id = any (fn_current_locations()))
 group by d.sales_month, d.location_id, d.location_name_th, d.product_id, d.product_code,
          d.product_name_th, d.item_type, d.sale_unit, rep.days_reported, rep.days_closed;

comment on view public.v_monthly_summary_qty is
  'M12.2, R34 — v_monthly_summary with no money column. L1 all branches, L2 own branches, L3 none.';

revoke all    on public.v_monthly_summary_qty from anon, authenticated;
grant  select on public.v_monthly_summary_qty to   authenticated;
