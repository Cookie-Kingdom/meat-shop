-- v_rice_day — one row per branch day, with its sticky-rice record (card ^ref-52,
-- PLAN-material-screens.md T1, Finding 7; M7, BR 03).
--
-- BR 03 must "แสดงยอดยกมาจากเมื่อวาน" before anything is typed, and rice_records is deny-all. So
-- this view gives the screen the carry-in, and the day's figures once they exist.
--
-- ONE ROW PER daily_reports ROW, left-joined to its rice row (unique on daily_report_id). A day
-- with no rice row still appears, carrying nulls: nothing recorded is not zero recorded.
--
-- carried_in_cooked_kg IS THE ROW'S STORED FIGURE WHEN A ROW EXISTS. fn_record_rice stores what
-- the day actually carried, recomputed on every write. When no row exists yet it is THE SAME
-- QUERY fn_record_rice runs: the most recent cooked_remaining_kg strictly before report_date,
-- not yesterday's, and never coalesced. Null means nobody has recorded rice here yet, and 0.00
-- means no rice was left (TC-03, TC-04). The screen renders null as ยังไม่มีข้อมูล.
--
-- model IS THE ROW'S SNAPSHOT (R29), else the branch's current rice_model. An Owner who switches
-- a branch's model does not rewrite a day that was already recorded under the old one (TC-05).
--
-- NO PRICE COLUMN (R20): cooked_price_thb_per_kg and raw_price_thb_per_kg are L1-only and stay
-- in the table. SCOPE is v_daily_reports': L1 every branch day, L2 its own branch's, L3 none
-- (R34). SECURITY DEFINER (the default), because the base tables are deny-all. It depends on no
-- other view.
--
-- Covered by supabase/tests/material_screens_test.sql (TC-01 ... TC-06, TC-12).

create or replace view public.v_rice_day as
select r.id                                   as daily_report_id,
       r.location_id,
       r.report_date,
       coalesce(rr.model, l.rice_model)       as model,
       rr.id                                  as rice_record_id,
       (case when rr.id is not null
             then rr.carried_in_cooked_kg
             else (select p.cooked_remaining_kg
                     from rice_records p
                    where p.location_id = r.location_id
                      and p.event_date  < r.report_date
                    order by p.event_date desc
                    limit 1)
        end)::numeric(12,2)                   as carried_in_cooked_kg,
       rr.cooked_received_kg,
       rr.raw_purchased_kg,
       rr.cooked_today_kg,
       rr.raw_remaining_kg,
       rr.cooked_remaining_kg
  from daily_reports r
  join locations l          on l.id = r.location_id
  left join rice_records rr on rr.daily_report_id = r.id
 where fn_current_role() = 'L1_OWNER'
    or (fn_current_role() = 'L2_BRANCH_ADMIN' and r.location_id = any (fn_current_locations()));

comment on view public.v_rice_day is
  'BR 03 / BR 08 / M7 - one row per branch day: the rice model (the row''s snapshot, else the '
  'branch''s), the carry-in (stored, else fn_record_rice''s query; null = no data, never 0) and '
  'the day''s weights. No price column. L1 all, L2 own branch, L3 none (R34).';

revoke all    on public.v_rice_day from anon, authenticated;
grant  select on public.v_rice_day to   authenticated;
