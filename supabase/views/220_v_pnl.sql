-- v_pnl — round one's profit per branch and business day (BR14, D04, C07, UAT-17, v0.2:455,
-- card ^ref-57; PLAN-reporting.md K11).
--
-- ROUND ONE'S SCOPE IS ON THE ROW'S FACE (D04, UAT-17). Revenue is LINE MAN only, with no
-- discounts and no returns (revenue_source). Tax, central overhead and labour are excluded by
-- decision and named in scope_excludes on every row. Owner expenses are never subtracted (M11):
-- only v_cost_breakdown rows with in_pnl_round_one = true enter here. ADR-020 closed with no
-- depreciation, so there is no fuller version to wait for.
--
--   revenue_thb           Σ 200 (the BR23 snapshot, rounded per line)
--   <part>_thb            Σ 213 in-scope rows of that category; null if any of them is unknown,
--                         0.00 when the day had none (nothing incurred is a real zero)
--   total_cost_thb        Σ every known in-scope amount (171's convention: the known parts)
--   profit_round_one_thb  revenue_thb − total_cost_thb
--
-- COMPLETE MEANS CLOSED AND FULLY PRICED. is_complete is false when any in-scope row is not
-- (213's codes, e.g. PRODUCT_COST:RICE_KG, or a lot's RETURN_FREIGHT), when the report is not
-- CLOSED (REPORT_OPEN), or when no report exists (NO_DAILY_REPORT). OW 08 shows
-- IncompleteDataNotice in place of an incomplete profit, never the number with a caveat (F13).
--
-- THE KEYS ARE A UNION. Every daily_reports row, plus every (cost_date, location_id) that carries
-- an in-scope cost. A consumption with no report that day (a reversal dated on a day nobody
-- opened, a write-off at central) still has a row and its cost is not lost (TC-30).
--
-- L1 ONLY, AS A WHERE (R34, R20). SECURITY DEFINER (the default).
--
-- 221_v_pnl_monthly reads this view. Changing its column list means dropping 221 in the same
-- change, never adding CASCADE.
--
-- Covered by supabase/tests/reports_pnl_test.sql (TC-25 ... TC-31).

create or replace view public.v_pnl as
with inscope as (
  select * from v_cost_breakdown where in_pnl_round_one and location_id is not null
), keys as (
  select r.report_date as business_date, r.location_id from daily_reports r
  union
  select c.cost_date, c.location_id from inscope c
), rev as (
  select d.business_date, d.location_id, sum(d.revenue_thb) as revenue_thb
    from v_daily_sales d
   group by d.business_date, d.location_id
), cost as (
  select c.cost_date,
         c.location_id,
         -- a part is null if any of its rows is unknown, 0 if it has none
         case when count(*) filter (where c.category = 'MEAT'           and c.amount_thb is null) = 0
              then coalesce(sum(c.amount_thb) filter (where c.category = 'MEAT'), 0) end           as meat,
         case when count(*) filter (where c.category = 'BRINE'          and c.amount_thb is null) = 0
              then coalesce(sum(c.amount_thb) filter (where c.category = 'BRINE'), 0) end          as brine,
         case when count(*) filter (where c.category = 'SMOKE_FEE'      and c.amount_thb is null) = 0
              then coalesce(sum(c.amount_thb) filter (where c.category = 'SMOKE_FEE'), 0) end      as smoke,
         case when count(*) filter (where c.category = 'TRANSPORT'      and c.amount_thb is null) = 0
              then coalesce(sum(c.amount_thb) filter (where c.category = 'TRANSPORT'), 0) end      as freight,
         case when count(*) filter (where c.category = 'OPENING_STOCK'  and c.amount_thb is null) = 0
              then coalesce(sum(c.amount_thb) filter (where c.category = 'OPENING_STOCK'), 0) end  as opening,
         case when count(*) filter (where c.category = 'CHILLI_PASTE'   and c.amount_thb is null) = 0
              then coalesce(sum(c.amount_thb) filter (where c.category = 'CHILLI_PASTE'), 0) end   as chilli,
         case when count(*) filter (where c.category = 'PRODUCT_COST'   and c.amount_thb is null) = 0
              then coalesce(sum(c.amount_thb) filter (where c.category = 'PRODUCT_COST'), 0) end   as product,
         case when count(*) filter (where c.category = 'PACKAGING'      and c.amount_thb is null) = 0
              then coalesce(sum(c.amount_thb) filter (where c.category = 'PACKAGING'), 0) end      as packaging,
         case when count(*) filter (where c.category = 'BRANCH_EXPENSE' and c.amount_thb is null) = 0
              then coalesce(sum(c.amount_thb) filter (where c.category = 'BRANCH_EXPENSE'), 0) end as branch_exp,
         coalesce(sum(c.amount_thb), 0) as total,
         bool_and(c.is_complete)        as all_complete
    from inscope c
   group by c.cost_date, c.location_id
), miss as (
  select c.cost_date, c.location_id, array_agg(distinct x order by x) as codes
    from inscope c
   cross join unnest(c.missing_inputs) as x
   group by c.cost_date, c.location_id
)
select k.business_date,
       to_char(k.business_date, 'YYYY-MM')                               as pnl_month,
       k.location_id,
       loc.name_th                                                       as location_name_th,
       r.id                                                              as daily_report_id,
       r.status                                                          as report_status,
       coalesce(v.revenue_thb, 0)::numeric(12,2)                         as revenue_thb,
       -- A day with no cost row at all has spent nothing: 0.00. A day whose part is unknown
       -- keeps cost's null. Never coalesce the part itself (TDD Seam 4).
       (case when c.cost_date is null then 0 else c.meat       end)::numeric(12,2) as meat_cost_thb,
       (case when c.cost_date is null then 0 else c.brine      end)::numeric(12,2) as brine_cost_thb,
       (case when c.cost_date is null then 0 else c.smoke      end)::numeric(12,2) as smoke_fee_thb,
       (case when c.cost_date is null then 0 else c.freight    end)::numeric(12,2) as freight_thb,
       (case when c.cost_date is null then 0 else c.opening    end)::numeric(12,2) as opening_stock_cost_thb,
       (case when c.cost_date is null then 0 else c.chilli     end)::numeric(12,2) as chilli_paste_cost_thb,
       (case when c.cost_date is null then 0 else c.product    end)::numeric(12,2) as product_cost_thb,
       (case when c.cost_date is null then 0 else c.packaging  end)::numeric(12,2) as packaging_thb,
       (case when c.cost_date is null then 0 else c.branch_exp end)::numeric(12,2) as branch_expense_thb,
       coalesce(c.total, 0)::numeric(12,2)                               as total_cost_thb,
       (coalesce(v.revenue_thb, 0) - coalesce(c.total, 0))::numeric(12,2) as profit_round_one_thb,
       (coalesce(r.status = 'CLOSED', false) and coalesce(c.all_complete, true)) as is_complete,
       coalesce(m.codes, '{}'::text[])
         || array_remove(array[case when r.id is null          then 'NO_DAILY_REPORT'
                                    when r.status <> 'CLOSED'  then 'REPORT_OPEN' end]::text[], null)
                                                                         as missing_inputs,
       'LINE_MAN'::text                                                  as revenue_source,
       '{TAX,CENTRAL_OVERHEAD,LABOUR}'::text[]                           as scope_excludes
  from keys k
  join locations loc          on loc.id = k.location_id
  left join daily_reports r   on r.location_id = k.location_id and r.report_date = k.business_date
  left join rev v             on v.location_id = k.location_id and v.business_date = k.business_date
  left join cost c            on c.location_id = k.location_id and c.cost_date = k.business_date
  left join miss m            on m.location_id = k.location_id and m.cost_date = k.business_date
 where fn_current_role() = 'L1_OWNER';

comment on view public.v_pnl is
  'BR14 / D04 / UAT-17 — round-one P&L per branch and business day: LINE MAN revenue (no '
  'discounts or returns) minus meat, brine, smoke fee, freight, opening stock, chilli paste, '
  'other product cost, packaging and branch expenses. Tax, central overhead and labour are '
  'excluded by decision (D04, scope_excludes); owner expenses are never subtracted (M11). '
  'A part is null when any of its inputs is unknown; is_complete needs a CLOSED report and '
  'every input priced. L1 only (R34).';

revoke all    on public.v_pnl from anon, authenticated;
grant  select on public.v_pnl to   authenticated;
