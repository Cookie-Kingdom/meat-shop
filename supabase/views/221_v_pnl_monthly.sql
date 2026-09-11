-- v_pnl_monthly — round one's profit per branch and month (BR14, D04, UAT-17, card ^ref-57;
-- PLAN-reporting.md K12).
--
-- A GROUPING OF 220, so the month is the sum of its days by construction (TC-31). A part that
-- is null on any day is null for the month: the month cannot be more certain than its worst day.
-- total_cost_thb and profit_round_one_thb are sums of the days' known-part figures, as in 220.
--
-- is_complete = every day in the month is complete (closed, fully priced). missing_inputs is the
-- union of the days' codes. days_reported / days_closed count the month's daily reports.
--
-- THE OWNER-EXPENSE MEMO IS NOT HERE. No row of this view carries a figure that is not inside
-- its own profit; OW 08 reads the memo from 213 where in_pnl_round_one = false (M11, TC-29).
--
-- L1 ONLY, AS A WHERE (R34, R20). SECURITY DEFINER (the default).
--
-- Covered by supabase/tests/reports_pnl_test.sql (TC-29, TC-31).

create or replace view public.v_pnl_monthly as
with miss as (
  select p.pnl_month, p.location_id, array_agg(distinct x order by x) as codes
    from v_pnl p
   cross join unnest(p.missing_inputs) as x
   group by p.pnl_month, p.location_id
)
select p.pnl_month,
       p.location_id,
       p.location_name_th,
       sum(p.revenue_thb)::numeric(12,2)                                                    as revenue_thb,
       (case when bool_and(p.meat_cost_thb          is not null) then sum(p.meat_cost_thb)          end)::numeric(12,2) as meat_cost_thb,
       (case when bool_and(p.brine_cost_thb         is not null) then sum(p.brine_cost_thb)         end)::numeric(12,2) as brine_cost_thb,
       (case when bool_and(p.smoke_fee_thb          is not null) then sum(p.smoke_fee_thb)          end)::numeric(12,2) as smoke_fee_thb,
       (case when bool_and(p.freight_thb            is not null) then sum(p.freight_thb)            end)::numeric(12,2) as freight_thb,
       (case when bool_and(p.opening_stock_cost_thb is not null) then sum(p.opening_stock_cost_thb) end)::numeric(12,2) as opening_stock_cost_thb,
       (case when bool_and(p.chilli_paste_cost_thb  is not null) then sum(p.chilli_paste_cost_thb)  end)::numeric(12,2) as chilli_paste_cost_thb,
       (case when bool_and(p.product_cost_thb       is not null) then sum(p.product_cost_thb)       end)::numeric(12,2) as product_cost_thb,
       (case when bool_and(p.packaging_thb          is not null) then sum(p.packaging_thb)          end)::numeric(12,2) as packaging_thb,
       (case when bool_and(p.branch_expense_thb     is not null) then sum(p.branch_expense_thb)     end)::numeric(12,2) as branch_expense_thb,
       sum(p.total_cost_thb)::numeric(12,2)                                                 as total_cost_thb,
       sum(p.profit_round_one_thb)::numeric(12,2)                                           as profit_round_one_thb,
       count(p.daily_report_id)                                                             as days_reported,
       count(*) filter (where p.report_status = 'CLOSED')                                   as days_closed,
       bool_and(p.is_complete)                                                              as is_complete,
       coalesce(m.codes, '{}'::text[])                                                      as missing_inputs,
       'LINE_MAN'::text                                                                     as revenue_source,
       '{TAX,CENTRAL_OVERHEAD,LABOUR}'::text[]                                              as scope_excludes
  from v_pnl p
  left join miss m on m.pnl_month = p.pnl_month and m.location_id = p.location_id
 where fn_current_role() = 'L1_OWNER'
 group by p.pnl_month, p.location_id, p.location_name_th, m.codes;

comment on view public.v_pnl_monthly is
  'BR14 / D04 / UAT-17 — v_pnl summed per branch and month; a part unknown on any day is null '
  'for the month. LINE MAN revenue only; tax, central overhead and labour excluded (D04); owner '
  'expenses never subtracted (M11). L1 only (R34).';

revoke all    on public.v_pnl_monthly from anon, authenticated;
grant  select on public.v_pnl_monthly to   authenticated;
