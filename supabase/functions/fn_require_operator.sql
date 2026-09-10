-- Card ^ref-26 — the shared front door for every L3 chef-house write function.
--
-- The third preamble, beside fn_require_owner() (^ref-11) and fn_require_branch(uuid)
-- (^ref-39), and deliberately a third small function rather than an arm added to either.
-- fn_require_branch's header gives the reason and it applies unchanged here: folding a
-- second role into one preamble means every future caller of that preamble inherits the
-- other role's policy. Three preambles that each say one thing.
--
-- FOUR questions, and the ORDER IS THE BEHAVIOUR:
--
--   1. Is there an active profile behind this JWT?   No → NO_ACTOR (R31).
--   2. Is it L3?                                     No → FORBIDDEN (ADR-004).
--   3. Is the lot's chef house one of theirs?        No → FORBIDDEN_LOCATION.
--   4. Is the lot assigned to them?                  No → NOT_ASSIGNED_OPERATOR (CM 01).
--
-- Actor first, for fn_require_owner's reason: fn_current_role() folds in is_active and goes
-- null for a deactivated operator holding a live token. Asking the role first reports that
-- operator as merely forbidden, which is true and hides the real state (TC-09).
--
-- STEPS 3 AND 4 ARE NOT REDUNDANT, IN EITHER DIRECTION. An operator moved to another chef
-- house keeps whatever assigned_operator_id rows were already written against them, so
-- assignment alone is not membership (TC-11); and every L3 at a chef house holds that
-- membership, so membership alone is not assignment — CM 01's "the operator sees only their
-- own assigned lots" is step 4 and nothing else (TC-12). Both, or the guard has a hole, and
-- the two tests exist precisely because one check reads like it covers the other.
--
-- LOT_NOT_FOUND IS RAISED, NOT FOLDED INTO FORBIDDEN_LOCATION. fn_require_branch answers a
-- non-member identically for a location that exists and one that does not, because there a
-- caller supplies a bare location uuid and the uniform answer is what stops enumeration.
-- Here the caller has already passed steps 1 and 2 — they are an active L3 operator, not an
-- anonymous prober — and the two states need different screens: "this lot is not yours" is
-- a permissions message, "no such lot" is a stale link. Merging them would make every
-- caller in this range report a typo as a permissions failure.
--
-- Returns the actor, which becomes recorded_by / closed_by and is therefore never a
-- parameter: a caller who can name the signer can sign as somebody else.
--
-- The role is checked here rather than by a policy because the callers are SECURITY
-- DEFINER: RLS does not apply inside them, so there is no policy to consult (ADR-002).
--
-- EXECUTE is granted to nobody — a preamble, not an endpoint (^ref-64). rls_deny_all_test's
-- sweep 1f names it alongside the other no-grant functions, and 1g excludes it by the same
-- list, so losing the revoke fails the suite either way.
--
-- Covered by supabase/tests/production_test.sql (TC-09 ... TC-12).

create or replace function public.fn_require_operator(p_lot_id uuid)
  returns uuid
  language plpgsql
  stable
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor    uuid;
  v_chef     uuid;
  v_assigned uuid;
begin
  select id into v_actor from profiles where id = auth.uid() and is_active;
  if v_actor is null then
    raise exception 'NO_ACTOR: the caller has no active profile (R31)';
  end if;

  if fn_current_role() <> 'L3_CM_OPERATOR' then
    raise exception 'FORBIDDEN: this write is L3 only (ADR-004, BR15)';
  end if;

  select chef_house_location_id, assigned_operator_id
    into v_chef, v_assigned
    from lots where id = p_lot_id;
  if not found then
    raise exception 'LOT_NOT_FOUND: no lot %', p_lot_id;
  end if;

  -- fn_current_locations() returns '{}' and never null, so `= any(...)` is false rather than
  -- null for a caller with no memberships at all.
  if v_chef <> all (fn_current_locations()) then
    raise exception 'FORBIDDEN_LOCATION: the caller is not assigned to location %', v_chef;
  end if;

  -- `is distinct from` rather than `<>`: an unassigned lot has a null here, and `null <>
  -- actor` is null, which would fall through and let any L3 at the chef house write to a lot
  -- nobody owns. CM 01 says the operator sees their own assigned lots; an unassigned lot is
  -- not one of them.
  if v_assigned is distinct from v_actor then
    raise exception 'NOT_ASSIGNED_OPERATOR: lot % is not assigned to the caller (CM 01)', p_lot_id;
  end if;

  return v_actor;
end $$;

revoke execute on function public.fn_require_operator(uuid) from public, anon, authenticated;
