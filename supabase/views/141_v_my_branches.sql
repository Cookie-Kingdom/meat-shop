-- v_my_branches — the branches the caller may work in (card ^ref-41, PLAN-thaw.md T7, Finding 9).
--
-- BR 01's header is "Branch name · date" (LAYOUT-SKELETONS.md S6) and every branch screen needs
-- the location id its writes name. locations and user_locations are both deny-all
-- (policies/*.sql), so without this view a branch screen cannot name its own branch.
--
-- SCOPE (R34, ADR-004), in the WHERE, resolved through R31's helpers:
--   L1  every active BRANCH — v0.2:57 "ดูและแก้ไขทุกสาขา";
--   L2  their own active BRANCH location(s) only;
--   L3  nothing. The operator's location is a chef house and no branch screen is theirs.
-- CENTRAL and CHEF_HOUSE rows never appear, for anyone: this is the branch picker, not a
-- location list. An inactive branch is not offered either — nothing may be opened there.
--
-- No money column (R20). rice_model is here because BR 01 renders the M7A or M7B rice item
-- from it, and fn_open_daily_report returns it only after the day is open.
--
-- Covered by supabase/tests/branch_screens_test.sql (TC-36, TC-39, TC-40).

create or replace view public.v_my_branches as
select l.id,
       l.code,
       l.name_th,
       l.rice_model
  from locations l
 where l.kind = 'BRANCH'
   and l.is_active
   and (fn_current_role() = 'L1_OWNER'
     or (fn_current_role() = 'L2_BRANCH_ADMIN' and l.id = any (fn_current_locations())))
 order by l.code;

comment on view public.v_my_branches is
  'BR 01 - the caller''s active BRANCH locations: L1 all, L2 their own, L3 none (R34). '
  'Never a CENTRAL or CHEF_HOUSE row.';

revoke all    on public.v_my_branches from anon, authenticated;
grant  select on public.v_my_branches to   authenticated;
