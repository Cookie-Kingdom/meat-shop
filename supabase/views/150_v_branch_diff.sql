-- v_branch_diff — R23's Diff, per branch and business day, against R22's band (card ^ref-45,
-- PLAN-sales.md T5, Finding 8, B5; TDD Seams 1, 2 and 6).
--
--   Diff = น้ำหนักพร้อมขาย − (ยอดขาย × น้ำหนักเฉลี่ยต่อซองจาก Config) − Waste      (v0.2:207)
--
-- IT READS THE LEDGER AND NO CONFIG (Finding 8, Seam 2). fn_record_sales posts every meat SALE
-- in kilograms, computed from the avg_pack_weight_kg snapshot stored on the line (R29). So the
-- "× pack weight" half of the formula is already in stock_ledger at the rate that applied on
-- the day. Recomputing it here from config would re-price a closed day the moment the Owner
-- changes 0.20 to 0.22 (BR23). There is no config call anywhere in this view, and TC-41 proves
-- that a later config row moves nothing.
--
-- READY ONLY, AND A REVERSAL COUNTS AS WHAT IT REVERSES (B5). Over SMOKED_MEAT rows in READY:
--   sold_kg     = -(SALE rows)
--   wasted_kg   = -(WASTE and GIVEAWAY rows)
--   ready_in_kg =   every other READY movement, net: the thaw, an ADJUSTMENT, and the reversal
--                   of either
-- each summed with a REVERSAL row classified by the movement_type of the row it reverses. So a
-- corrected sale drops out of sold_kg instead of inflating ready_in_kg, and a spoiled-FROZEN
-- write-off (fn_record_waste, p_stock_state FROZEN) never enters the day's Diff: the freezer
-- is not part of today's ready reconciliation.
--
-- ready_in_kg IS THE DAY'S INFLOW, NOT THE CLOSING BALANCE (Seam 1). The closing balance is
-- already net of every sale and write-off, and a Diff computed from it is zero by construction.
-- The consequence runs the other way as well: diff_kg = ready_in - sold - wasted IS the day's
-- net READY movement, exactly. That is why fn_close_daily_report asks the Diff BEFORE R13 (B6):
-- once R13 has forced READY to zero, the Diff is zero too.
--
-- variance_pct and verdict come from fn_check_variance(sold + wasted, ready_in, 'ALERT'): actual
-- is what went out, expected is what came in. ALERT, because a view that raises cannot be
-- selected from on the very day somebody needs to read it. fn_close_daily_report reads THIS
-- view's sums and calls the same function in BLOCK mode (B10), so the two cannot compute the
-- Diff two ways. With no threshold argument it takes R22's 20.00 (Finding 9). At
-- ready_in_kg = 0 it returns a null percentage and REASON_REQUIRED and does not divide.
--
-- sold_pack_qty comes from sales_lines, for the screen to render. The Diff is NOT computed from
-- it. It counts packs as keyed, so a sale later corrected in the ledger is still counted here
-- (Cross-lane gap G9).
--
-- NO MONEY COLUMN (Finding 8). The Diff is a weight question and F13 is the money one, and a
-- price here would need a second, role-specific view to keep it from L2 (R20).
--
-- SCOPE is v_stock_balance's: L1 all branches, an L2 only their own, L3 none (R34). SECURITY
-- DEFINER (the default), never security_invoker, because the base tables are deny-all.
--
-- Numbered 150 (lane C's range), not PLAN T5's 110, which is v_lot_progress. It depends on no
-- other view.
--
-- ponytail: one level of reversal. A reversal of a reversal is classified as REVERSAL and read
-- as inflow. fn_reverse_ledger_entry does not produce one today.
--
-- Covered by supabase/tests/day_close_test.sql (TC-38 ... TC-42).

create or replace view public.v_branch_diff as
with moves as (
  select l.location_id,
         l.business_date,
         coalesce(o.movement_type, l.movement_type) as effective_type,
         l.qty_delta
    from stock_ledger l
    left join stock_ledger o on o.id = l.reversal_of
   where l.item_type   = 'SMOKED_MEAT'
     and l.stock_state = 'READY'
), days as (
  select m.location_id,
         m.business_date,
         coalesce(sum(m.qty_delta) filter (
                    where m.effective_type not in ('SALE', 'WASTE', 'GIVEAWAY')), 0)::numeric(12,2)
           as ready_in_kg,
         coalesce(-sum(m.qty_delta) filter (where m.effective_type = 'SALE'), 0)::numeric(12,2)
           as sold_kg,
         coalesce(-sum(m.qty_delta) filter (
                    where m.effective_type in ('WASTE', 'GIVEAWAY')), 0)::numeric(12,2)
           as wasted_kg
    from moves m
   group by m.location_id, m.business_date
), packs as (
  select r.location_id,
         r.report_date   as business_date,
         sum(s.qty)      as sold_pack_qty
    from sales_lines s
    join daily_reports r on r.id = s.daily_report_id
    join products p      on p.id = s.product_id
   where p.item_type = 'SMOKED_MEAT'
   group by r.location_id, r.report_date
)
select d.location_id,
       d.business_date,
       d.ready_in_kg,
       coalesce(k.sold_pack_qty, 0)::numeric(12,2)                   as sold_pack_qty,
       d.sold_kg,
       d.wasted_kg,
       (d.ready_in_kg - d.sold_kg - d.wasted_kg)::numeric(12,2)       as diff_kg,
       v.variance_pct,
       v.verdict
  from days d
  left join packs k
    on k.location_id = d.location_id and k.business_date = d.business_date
 cross join lateral fn_check_variance(d.sold_kg + d.wasted_kg, d.ready_in_kg, 'ALERT') v
 where fn_current_role() = 'L1_OWNER'
    or (fn_current_role() = 'L2_BRANCH_ADMIN' and d.location_id = any (fn_current_locations()));

comment on view public.v_branch_diff is
  'R23 per branch and business day, READY smoked meat only: ready_in (net inflow, not balance), '
  'sold and wasted from the ledger, where a reversal counts as the row it reverses; '
  'diff = ready_in - sold - wasted. variance_pct and verdict are fn_check_variance in ALERT mode '
  '(R22, 20%). No config read (R29) and no money column. L1 all, L2 own branch, L3 none (R34).';

revoke all    on public.v_branch_diff from anon, authenticated;
grant  select on public.v_branch_diff to   authenticated;
