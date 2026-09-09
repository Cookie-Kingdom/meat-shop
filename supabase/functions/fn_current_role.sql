-- fn_current_role() — the caller's role, resolved inside a policy with no round trip.
--
-- SECURITY DEFINER is not hardening here, it is correctness. A policy on `profiles` that
-- calls this function would re-enter `profiles`' own policy and recurse; running as the
-- owner, who owns the table, bypasses RLS and breaks the cycle.
--
-- The corollary is a standing rule: never `alter table … force row level security` on a
-- table a helper reads. That removes the owner's bypass and the recursion comes back.
--
-- `is_active` is folded in on purpose. A deactivated profile holding a valid JWT resolves
-- to null, and `null = 'L1_OWNER'` is null, which every policy reads as false. One place
-- to get it wrong instead of one per call site.

create or replace function public.fn_current_role()
  returns user_role
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select role from profiles where id = auth.uid() and is_active
$$;

revoke execute on function public.fn_current_role() from public;
grant  execute on function public.fn_current_role() to authenticated;
