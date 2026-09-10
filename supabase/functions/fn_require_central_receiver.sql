-- Card ^ref-34 — the front door for the acts BR12 and BR17 let an Owner delegate: naming a
-- return pickup date (fn_set_return_pickup_date) and, at ^ref-35, signing for central intake.
--
-- The fourth preamble, beside fn_require_owner, fn_require_branch and fn_require_operator, and
-- a fourth small function rather than an arm on fn_require_owner, for fn_require_branch's
-- reason: every future caller of a preamble inherits every role it admits.
--
-- TWO questions, and the ORDER IS THE BEHAVIOUR (PLAN-movement.md Finding 4):
--
--   1. Is there an active profile behind this JWT?                     No → NO_ACTOR (R31).
--   2. Is it L1, or does any of its user_locations rows carry
--      can_receive_central?                                             No → FORBIDDEN.
--
-- Actor first, for fn_require_owner's reason: fn_current_role() folds in is_active, so a
-- deactivated Owner holding a live token would otherwise read as merely forbidden (TC-08).
--
-- THE LOCATION QUESTION IS DELIBERATELY NOT ASKED. An L2 of Branch A delegated central intake
-- carries the flag on their Branch A row, and signs for central all the same (TC-10). That is
-- the delegation: it grants the act, not the data — and the data half stays true because
-- fn_current_locations(), which every view and policy filters on, never reads the flag
-- (fn_current_locations.sql, R27, Seam 1). Checking which location the flagged row names
-- reads like defensive coding and makes the delegation impossible to use.
--
-- Returns the actor, which becomes return_pickup_set_by / received_by and is therefore never a
-- parameter.
--
-- EXECUTE is granted to nobody — a preamble, not an endpoint (^ref-64). rls_deny_all_test's
-- sweep 1f names it, and 1g excludes it by the same list (TC-03).
--
-- Covered by supabase/tests/movement_test.sql (TC-08 ... TC-10).

create or replace function public.fn_require_central_receiver()
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

  if fn_current_role() <> 'L1_OWNER'
     and not exists (select 1 from user_locations
                      where profile_id = v_actor and can_receive_central) then
    raise exception 'FORBIDDEN: this write is L1 or a can_receive_central delegate only (BR12, BR17)';
  end if;

  return v_actor;
end $$;

revoke execute on function public.fn_require_central_receiver() from public, anon, authenticated;
