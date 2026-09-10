-- v_daily_reports — one row per branch day (card ^ref-41, PLAN-thaw.md T7, Finding 9).
--
-- BR 01 opens on a date and shows that day's checklist; BR 05 needs the day's report id and its
-- status before it can offer a thaw. daily_reports is deny-all (policies/daily_reports.sql stays
-- so, on the ^ref-09 / ^ref-12 precedent: the view carries the role test, R34).
--
-- RENAMED FROM v_daily_report_current (done-ref-38-39-branch-daily-open/PLAN). BR 01 has a
-- DateNavigator, so the screen asks for a day BY DATE; "current" describes one row.
--
-- thawed_kg is the day's thawed weight, for BR 05's checklist item. ZERO MEANS SOMETHING HERE:
-- nothing was thawed that day, which is a fact, not a gap — so it is coalesced, unlike a
-- missing config value. It is a sum over thaw_records, which fn_record_thaw writes one row per
-- lot per call; it is not a balance (ADR-003) and never feeds one.
--
-- SCOPE: L1 every branch's days, L2 their own branch's, L3 none (R34). No money column (R20).
--
-- Covered by supabase/tests/branch_screens_test.sql (TC-37, TC-39, TC-40).

create or replace view public.v_daily_reports as
select r.id,
       r.location_id,
       r.report_date,
       r.status,
       r.shift_started_at,
       coalesce((select sum(t.thawed_weight_kg)
                   from thaw_records t
                  where t.daily_report_id = r.id), 0)::numeric(12,2) as thawed_kg
  from daily_reports r
 where fn_current_role() = 'L1_OWNER'
    or (fn_current_role() = 'L2_BRANCH_ADMIN' and r.location_id = any (fn_current_locations()));

comment on view public.v_daily_reports is
  'BR 01 / BR 05 - one row per branch day with the day''s thawed_kg (0.00 = nothing thawed). '
  'L1 all, L2 own branch, L3 none (R34).';

revoke all    on public.v_daily_reports from anon, authenticated;
grant  select on public.v_daily_reports to   authenticated;
