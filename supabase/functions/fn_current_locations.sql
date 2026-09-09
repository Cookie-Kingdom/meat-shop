-- fn_current_locations() — the locations the caller may touch, as a uuid[].
--
-- SECURITY DEFINER for the same reason as fn_current_role(): a policy on `user_locations`
-- must be able to call this without re-entering itself.
--
-- Returns '{}' and never null. `x = any(null)` is null, which a policy happens to read as
-- false; an empty array makes that the right answer by construction rather than by luck,
-- and keeps array_length() call sites from special-casing it.
--
-- `can_receive_central` is deliberately NOT read here (R27, BR12, BR17): the delegation
-- grants the act of receiving, not one row of extra read scope. Whichever fn_* implements
-- the act checks that column itself.

create or replace function public.fn_current_locations()
  returns uuid[]
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select coalesce(array_agg(ul.location_id), '{}')
    from user_locations ul
    join profiles p on p.id = ul.profile_id
   where ul.profile_id = auth.uid()
     and p.is_active
$$;

revoke execute on function public.fn_current_locations() from public;
grant  execute on function public.fn_current_locations() to authenticated;
