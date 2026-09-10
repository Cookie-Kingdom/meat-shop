-- Card ^ref-40, PLAN-thaw.md T3 — the front door for a branch-scoped write the Owner may also
-- make. fn_record_thaw is the first caller; lane C's fn_record_sales / fn_record_waste /
-- fn_close_daily_report and lane D's branch materials writers call it too, against this exact
-- contract, and none of them creates it (PARALLEL-LANES.md, "Files one lane owns").
--
-- WHY A THIRD PREAMBLE. v0.2:57 gives branch operations — "รับเข้า ละลาย ขาย Waste Diff" — to
-- the L2 for their own branch and to the Owner for every branch: "ดูและแก้ไขทุกสาขา". UAT-15
-- (v0.2:441) repeats it, "Owner ดู/แก้ทุกสาขา". fn_require_branch is L2 only on purpose
-- (fn_open_daily_report stays the branch's act, its own header), and fn_require_owner is L1
-- only. Folding an L1 arm into fn_require_branch would widen every existing caller at once.
-- A caller picks the preamble that says its rule, and each preamble says one thing.
--
-- THE ORDER IS THE BEHAVIOUR, and callers depend on it (PLAN-sales.md T2 is the same design):
--
--   1. Is there an active profile behind this JWT?  No  -> NO_ACTOR (R31).
--   2. Is it L1?                                    Yes -> return the actor. The location is
--                                                          not asked about: the Owner edits
--                                                          every branch and holds no
--                                                          user_locations row for any of them.
--   3. Is it L2, and is p_location_id theirs?       No  -> FORBIDDEN_LOCATION.
--   4. Anything else (L3, or a role added later)        -> FORBIDDEN (ADR-004).
--
-- Actor first, because fn_current_role() folds in is_active and goes null for a deactivated
-- Owner holding a live token. Asking the role first would report that Owner as FORBIDDEN —
-- true, and it hides the real state from whoever reads the error (TC-06).
--
-- MEMBERSHIP IS ASKED BEFORE ANYTHING ABOUT THE LOCATION IS LEARNED. A null p_location_id is
-- FORBIDDEN_LOCATION for an L2, the same answer a non-member gets for a real branch and for a
-- uuid that names nothing. So a caller that passes the location of a row it looked up — a
-- daily report that may not exist — leaks nothing to an L2 of another branch.
--
-- The L3 test is step 4, not a step of its own: an L3 holds user_locations rows too (their
-- chef house), so membership alone is not a role check. fn_require_branch's TC-23 is the
-- same trap one preamble over.
--
-- The returned uuid becomes created_by (or closed_by, or opened_by) in the caller and is
-- never a parameter anywhere: a caller must not be able to sign a row as somebody else.
--
-- EXECUTE is granted to nobody: it is a preamble, not an endpoint. Sweep 1f of
-- rls_deny_all_test.sql names it (TC-05).
--
-- Covered by supabase/tests/thaw_test.sql (TC-06 ... TC-08, and through fn_record_thaw at
-- TC-10 and TC-28).

create or replace function public.fn_require_branch_or_owner(p_location_id uuid)
  returns uuid
  language plpgsql
  stable
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_role  user_role;
begin
  select id, role into v_actor, v_role from profiles where id = auth.uid() and is_active;
  if v_actor is null then
    raise exception 'NO_ACTOR: the caller has no active profile (R31)';
  end if;

  if v_role = 'L1_OWNER' then
    return v_actor;
  end if;

  if v_role = 'L2_BRANCH_ADMIN' then
    -- fn_current_locations() returns '{}' and never null, so `<> all` is true rather than
    -- null for an L2 with no memberships at all.
    if p_location_id is null or p_location_id <> all (fn_current_locations()) then
      raise exception 'FORBIDDEN_LOCATION: the caller is not assigned to location %', p_location_id;
    end if;
    return v_actor;
  end if;

  raise exception 'FORBIDDEN: this write is for the branch''s own admin or the Owner (ADR-004, v0.2:57)';
end $$;

revoke execute on function public.fn_require_branch_or_owner(uuid) from public, anon, authenticated;
