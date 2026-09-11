-- v_monthly_summary — the month per branch and SKU, with the money (M12.2, F13 "split by
-- branch", card ^ref-55; PLAN-reporting.md K3).
--
-- IT IS A GROUPING OF 200, NOT A SECOND QUERY OVER sales_lines, so the month equals the sum of
-- its days by construction (TC-07). sales_month is 'YYYY-MM', the same text shape as
-- v_owner_expenses.pnl_month.
--
-- days_reported / days_closed ARE THE LOCATION'S, repeated on each of its product rows. They
-- count daily_reports, so a reported day with no sales still counts as reported (TC-09) without
-- adding a zero-revenue product row. is_complete = every reported day is CLOSED. An UNLOCKED day
-- is not closed. Products are data, so the month cannot be pivoted into product columns.
--
-- L1 ONLY. 200 already filters, and the WHERE is stated again here so this view's scope does not
-- rest on another file (R34). SECURITY DEFINER (the default), never security_invoker.
--
-- Covered by supabase/tests/reports_sales_test.sql (TC-07 ... TC-09, TC-R3).

create or replace view public.v_monthly_summary as
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
       sum(d.sold_qty)::numeric(12,2)    as sold_qty,
       sum(d.revenue_thb)::numeric(12,2) as revenue_thb,
       count(*)                          as days_with_sales,
       rep.days_reported,
       rep.days_closed,
       rep.days_reported = rep.days_closed as is_complete,
       'LINE_MAN'::text                  as revenue_source
  from v_daily_sales d
  join rep on rep.location_id = d.location_id and rep.sales_month = d.sales_month
 where fn_current_role() = 'L1_OWNER'
 group by d.sales_month, d.location_id, d.location_name_th, d.product_id, d.product_code,
          d.product_name_th, d.item_type, d.sale_unit, rep.days_reported, rep.days_closed;

comment on view public.v_monthly_summary is
  'M12.2 — v_daily_sales summed per month, branch and SKU, with the branch''s days_reported and '
  'days_closed; is_complete when every reported day is CLOSED. LINE MAN only (D04). L1 only (R34).';

revoke all    on public.v_monthly_summary from anon, authenticated;
grant  select on public.v_monthly_summary to   authenticated;
