-- v_branch_expenses — the branch's own expense rows (card ^ref-52, PLAN-material-screens.md T2,
-- Finding 9; v0.2:59, :65, :94).
--
-- WHY A READ AT ALL. Without it the operator cannot see whether an expense was already saved, and
-- a duplicate follows. branch_expenses is deny-all, and fn_record_branch_expense returns only an
-- id.
--
-- AN L2 READS MONEY HERE, AND THAT IS v0.2. v0.2:59 gives the branch admin กรอกค่าใช้จ่ายสาขา, and
-- v0.2:65 says แอดมินเข้าถึงเฉพาะสาขาตน รวมค่าใช้จ่ายประจำวันของสาขา. These are amounts the branch
-- typed itself, not a final financial figure (R20). L3 never reads a price or a cost, so L3 gets
-- nothing (TC-09).
--
-- category IS FREE TEXT (no CHECK, PLAN Finding 8). BR 07's picker sends one of PACKAGING, RICE,
-- CHILLI_PASTE or OTHER, and lane K's cost split reads exactly 'PACKAGING'.
--
-- SCOPE: L1 all, L2 own branch through the report's location, L3 none (R34). A deactivated L2 is
-- shut out by fn_current_role alone (R31). SECURITY DEFINER (the default). It depends on no
-- other view.
--
-- Covered by supabase/tests/material_screens_test.sql (TC-07 ... TC-12).

create or replace view public.v_branch_expenses as
select e.id               as branch_expense_id,
       e.daily_report_id,
       r.location_id,
       r.report_date,
       e.category,
       e.amount_thb,
       e.paid_by_person,
       e.detail,
       e.created_at
  from branch_expenses e
  join daily_reports r on r.id = e.daily_report_id
 where fn_current_role() = 'L1_OWNER'
    or (fn_current_role() = 'L2_BRANCH_ADMIN' and r.location_id = any (fn_current_locations()));

comment on view public.v_branch_expenses is
  'BR 07 - one row per branch_expenses row, with its report''s branch and date. The amount is '
  'what the branch typed (v0.2:59, :65). L1 all, L2 own branch, L3 none (R34).';

revoke all    on public.v_branch_expenses from anon, authenticated;
grant  select on public.v_branch_expenses to   authenticated;
