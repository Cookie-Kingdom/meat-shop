-- v_cost_breakdown — every cost the business can name, one row per source grouping, in long
-- format (M12.3, BR13, M11, ADR-020, ADR-023, card ^ref-56; PLAN-reporting.md K9, Findings 4–9).
--
--   category        from                                             basis       in P&L?
--   MEAT, BRINE,    212, one row per atom and part (a round lot)     consumed    yes
--   SMOKE_FEE,
--   TRANSPORT
--   OPENING_STOCK   212, one row per atom (an opening lot)           consumed    yes
--   CHILLI_PASTE    CHILLI_PASTE SALE/WASTE/GIVEAWAY tubes × the     consumed    yes
--                   chilli_paste_cost_thb_per_tube in force (BR13)
--   PRODUCT_COST    sales_lines of every other SKU × product_prices  sold        yes
--                   .cost_thb in force at the report date (Finding 6)
--   PACKAGING       branch_expenses with category = 'PACKAGING'      incurred    yes
--   BRANCH_EXPENSE  every other branch_expenses row                  incurred    yes
--   INVESTMENT,     owner_expenses via 191 (M11, memo only)          incurred    NO
--   MONTHLY_FIXED,
--   OWNER_OTHER
--
-- NO LABOUR ROW, EVER (Finding 9, D04, F17 Phase 2). No source holds a wage, and a 0.00 labour
-- row would read as "labour was free". The screen lists labour as a stated scope (TC-24).
--
-- OWNER EXPENSES ARE A MEMO (M11 AC: "โดยไม่กระทบสูตรกำไรรอบแรก"). They are listed here with
-- in_pnl_round_one = false and every P&L view ignores them (TC-29). cost_date follows
-- v_owner_expenses.pnl_month: a MONTHLY_FIXED row lands on the first day of the month it covers,
-- anything else on the day it was paid (ADR-020: an investment is expensed in the month bought).
--
-- MISSING IS NULL, NEVER 0 (ADR-023, TDD Seam 4). An unknown rate gives amount_thb null,
-- is_complete false, and a named code in missing_inputs: CONFIG:chilli_paste_cost_thb_per_tube,
-- PRODUCT_COST:<sku>, or the lot's codes from 211/171. No coalesce(…, 0) on a rate anywhere.
--
-- CONFIG IS A DIRECT SUBSELECT, NOT fn_config_numeric (Finding 8): that function is granted to
-- nobody and a view calls functions as the caller. The subselect is fn_config_value's
-- resolution: branch scope beats recency (R36), then the newest effective_from on or before the
-- business date (R12, BR23). The chilli cost's only home is that key; product_prices.cost_thb is
-- ignored for CHILLI_PASTE and for meat (Finding 7). Product cost reads the product_prices row in
-- force at the report date, the one that priced the sale (BR23).
--
-- PACKAGING IS A CONVENTION, NOT A VOCABULARY (Finding 5, Cross-lane gap 4). fn_record_branch_
-- expense documents 'PACKAGING' as the exact code for a packaging purchase and enforces none. A
-- packaging buy typed another way lands in BRANCH_EXPENSE: the total is right, the split is not.
-- source_label keeps the text the branch typed.
--
-- source_id is set only where one source row stands behind the row (an expense). Meat, chilli
-- and product rows are groupings; their source_table names where the atoms live.
--
-- L1 ONLY, AS A WHERE on the outer select (R34, R20). SECURITY DEFINER (the default).
--
-- 220 and 222 read this view. Changing its column list means dropping them in the same change,
-- never adding CASCADE.
--
-- Covered by supabase/tests/reports_cost_test.sql (TC-16 ... TC-24).

create or replace view public.v_cost_breakdown as
with chilli as (
  select l.business_date,
         l.location_id,
         coalesce(o.movement_type, l.movement_type)::text as consumption_kind,
         -sum(l.qty_delta)                                as tubes
    from stock_ledger l
    left join stock_ledger o on o.id = l.reversal_of
   where l.item_type = 'CHILLI_PASTE'
     and coalesce(o.movement_type, l.movement_type) in ('SALE', 'WASTE', 'GIVEAWAY')
   group by l.business_date, l.location_id, coalesce(o.movement_type, l.movement_type)
  having sum(l.qty_delta) <> 0
), sold as (
  select r.report_date,
         r.location_id,
         s.product_id,
         p.code     as product_code,
         sum(s.qty) as qty
    from sales_lines s
    join daily_reports r on r.id = s.daily_report_id
    join products p      on p.id = s.product_id
   where p.item_type not in ('SMOKED_MEAT', 'CHILLI_PASTE')
   group by r.report_date, r.location_id, s.product_id, p.code
), u as (
  -- meat, per atom and part
  select a.business_date          as cost_date,
         a.location_id,
         a.lot_id,
         a.lot_code,
         a.consumption_kind,
         c.category,
         c.amount                 as amount_thb,
         a.consumed_kg,
         null::numeric            as consumed_tubes,
         null::numeric            as sold_qty,
         'stock_ledger'::text     as source_table,
         null::uuid               as source_id,
         null::text               as source_label,
         (c.amount is not null and a.cost_is_complete) as is_complete,
         a.missing_inputs,
         true                     as in_pnl_round_one
    from v_meat_cost_attribution a
   cross join lateral (values
           ('MEAT',          a.meat_cost_thb,          false),
           ('BRINE',         a.brine_cost_thb,         false),
           ('SMOKE_FEE',     a.smoke_fee_thb,          false),
           ('TRANSPORT',     a.freight_thb,            false),
           ('OPENING_STOCK', a.opening_stock_cost_thb, true)
         ) c(category, amount, for_opening_lot)
   where c.for_opening_lot = a.is_opening
  union all
  -- chilli paste, per day, branch and kind (BR13)
  select c.business_date, c.location_id, null::uuid, null::text, c.consumption_kind,
         'CHILLI_PASTE',
         round(c.tubes * r.rate, 2),
         null::numeric, c.tubes, null::numeric,
         'stock_ledger', null::uuid, null::text,
         r.rate is not null,
         case when r.rate is null then array['CONFIG:chilli_paste_cost_thb_per_tube']
              else '{}' end::text[],
         true
    from chilli c
    left join lateral (
      select cs.value_numeric as rate
        from config_settings cs
       where cs.key = 'chilli_paste_cost_thb_per_tube'
         and (cs.scope_location_id = c.location_id or cs.scope_location_id is null)
         and cs.effective_from <= c.business_date
       order by (cs.scope_location_id is not null) desc, cs.effective_from desc
       limit 1
    ) r on true
  union all
  -- every other SKU (rice, water), per report day and SKU (Finding 6)
  select s.report_date, s.location_id, null::uuid, null::text, 'SALE',
         'PRODUCT_COST',
         round(s.qty * pc.cost_thb, 2),
         null::numeric, null::numeric, s.qty,
         'sales_lines', null::uuid, s.product_code,
         pc.cost_thb is not null,
         case when pc.cost_thb is null then array['PRODUCT_COST:' || s.product_code]
              else '{}' end::text[],
         true
    from sold s
    left join lateral (
      select pp.cost_thb
        from product_prices pp
       where pp.product_id = s.product_id
         and pp.effective_from <= s.report_date
       order by pp.effective_from desc
       limit 1
    ) pc on true
  union all
  -- branch expenses, dated by their report's business day (Finding 5)
  select r.report_date, r.location_id, null::uuid, null::text, null::text,
         case when e.category = 'PACKAGING' then 'PACKAGING' else 'BRANCH_EXPENSE' end,
         e.amount_thb,
         null::numeric, null::numeric, null::numeric,
         'branch_expenses', e.id, e.category,
         true, '{}'::text[], true
    from branch_expenses e
    join daily_reports r on r.id = e.daily_report_id
  union all
  -- owner expenses: listed, never in round one's profit (M11, ADR-020)
  select case when o.kind = 'MONTHLY_FIXED' then to_date(o.pnl_month || '-01', 'YYYY-MM-DD')
              else o.event_date end,
         o.location_id, null::uuid, null::text, null::text,
         case o.kind when 'INVESTMENT'    then 'INVESTMENT'
                     when 'MONTHLY_FIXED' then 'MONTHLY_FIXED'
                     else 'OWNER_OTHER' end,
         o.amount_thb,
         null::numeric, null::numeric, null::numeric,
         'owner_expenses', o.id, o.detail,
         true, '{}'::text[], false
    from v_owner_expenses o
)
select u.cost_date,
       to_char(u.cost_date, 'YYYY-MM')  as cost_month,
       u.location_id,
       loc.name_th                      as location_name_th,
       u.lot_id,
       u.lot_code,
       u.consumption_kind,
       u.category,
       u.amount_thb::numeric(12,2)      as amount_thb,
       u.consumed_kg::numeric(12,2)     as consumed_kg,
       u.consumed_tubes::numeric(12,2)  as consumed_tubes,
       u.sold_qty::numeric(12,2)        as sold_qty,
       u.source_table,
       u.source_id,
       u.source_label,
       u.is_complete,
       u.missing_inputs,
       u.in_pnl_round_one
  from u
  left join locations loc on loc.id = u.location_id
 where fn_current_role() = 'L1_OWNER';

comment on view public.v_cost_breakdown is
  'M12.3 — every nameable cost in long format: meat, brine, smoke fee, transport and opening '
  'stock per consumed kg (212); chilli paste tubes x dated config (BR13); other SKUs x '
  'product_prices.cost_thb; branch expenses (PACKAGING by code); owner expenses with '
  'in_pnl_round_one = false (M11). Unknown is null and named in missing_inputs. No LABOUR row '
  '(D04, F17 Phase 2). L1 only (R34).';

revoke all    on public.v_cost_breakdown from anon, authenticated;
grant  select on public.v_cost_breakdown to   authenticated;
