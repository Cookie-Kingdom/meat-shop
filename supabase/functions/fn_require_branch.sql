-- Card ^ref-39 — the shared front door for every L2 branch-scoped write function.
--
-- The counterpart of fn_require_owner(), and deliberately a second small function rather
-- than a role branch added to that one. Folding L2 into fn_require_owner would put two
-- role policies in one place and every future L1-only setter would inherit the branch arm.
-- Two preambles that each say one thing.
--
-- Three questions, and the ORDER IS THE BEHAVIOUR, same as fn_require_owner:
--
--   1. Is there an active profile behind this JWT?  No → NO_ACTOR (R31).
--   2. Is it L2?                                    No → FORBIDDEN (ADR-004).
--   3. Is p_location_id one of theirs?              No → FORBIDDEN_LOCATION.
--
-- Actor first, because fn_current_role() folds in is_active and goes null for a deactivated
-- branch admin holding a live token. Asking the role first reports that admin as FORBIDDEN
-- — true, but it hides the real state from whoever reads the error, and TC-25 pins it.
--
-- STEP 3 IS NOT REDUNDANT WITH STEP 2, in either direction. L3_CM_OPERATOR also holds
-- user_locations rows, so membership alone is not a role check (TC-23); and an L2 at branch
-- A must not open branch B's day, so a role check alone is not membership (TC-24). Both, or
-- the guard has a hole.
--
-- Membership is asked BEFORE the caller learns anything about the location — whether it
-- exists, what kind it is. A non-member gets FORBIDDEN_LOCATION for a location that does
-- not exist and for one that does, which is the same answer on purpose (Edge case 13).
--
-- The role is checked here rather than by a policy because the callers are SECURITY
-- DEFINER: RLS does not apply inside them, so there is no policy to consult. The function
-- is the boundary (ADR-002).
--
-- L1 IS REFUSED. API_DATA_MODEL.md's RPC table says fn_open_daily_report | L2, and opening
-- a shift is the branch's act — an Owner who needs a day opened uses the branch login or
-- the unlock path. Recorded as Open Question 1 in TDD-branch-daily-open.md because it is
-- the kind of rule an Owner overrules in week one, and the fix is one line here rather
-- than in every caller.
--
-- The returned uuid becomes opened_by and is never a parameter, for fn_require_owner's
-- reason: a caller must not be able to sign a row as somebody else.
--
-- EXECUTE is granted to nobody: it is a preamble, not an endpoint.
--
-- Covered by supabase/tests/branch_daily_test.sql (TC-22 ... TC-25, TC-31).

create or replace function public.fn_require_branch(p_location_id uuid)
  returns uuid
  language plpgsql
  stable
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
begin
  select id into v_actor from profiles where id = auth.uid() and is_active;
  if v_actor is null then
    raise exception 'NO_ACTOR: the caller has no active profile (R31)';
  end if;

  if fn_current_role() <> 'L2_BRANCH_ADMIN' then
    raise exception 'FORBIDDEN: this write is L2 only (ADR-004)';
  end if;

  -- fn_current_locations() returns '{}' and never null, so `= any(...)` is false rather
  -- than null for a caller with no memberships at all.
  if p_location_id is null or p_location_id <> all (fn_current_locations()) then
    raise exception 'FORBIDDEN_LOCATION: the caller is not assigned to location %', p_location_id;
  end if;

  return v_actor;
end $$;

revoke execute on function public.fn_require_branch(uuid) from public;
