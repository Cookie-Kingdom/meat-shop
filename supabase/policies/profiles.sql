-- profiles — the one table that carries a read policy on card ^ref-05.
--
-- Two reasons it is the exception. It is the table the helpers read, so it is where the
-- recursion risk is real and where a live policy proves fn_current_role() resolves instead
-- of asserting it (TC-02). And it carries no price and no yield column — display_name, role
-- and is_active — so granting SELECT here cannot leak what R20 protects.
--
-- Writes stay revoked forever. A role or an is_active flag changes through a
-- SECURITY DEFINER fn_* on the OW 10 card, never through a direct UPDATE (ADR-002).
--
-- Never `alter table profiles force row level security`: that removes the owner's RLS
-- bypass, which is the only thing keeping fn_current_role() from re-entering this policy.

alter table public.profiles enable row level security;

revoke all    on public.profiles from anon, authenticated;
grant  select on public.profiles to   authenticated;

-- A caller sees their own row; an Owner sees everyone. An L2 or L3 reading someone else
-- gets zero rows, not an error — the shape UAT-15 asks for (TC-05).
--
-- The `fn_current_role() is not null` guard is the deactivated-user case (TC-07) and it has
-- to be written this way round. Filtering on the *row's* `is_active` would also hide a
-- deactivated user from the Owner, and OW 10 exists to manage exactly those rows; the
-- helper returns null for a deactivated *caller*, so gating on the helper refuses the
-- session without narrowing what the Owner can see.
drop policy if exists profiles_select_self_or_owner on public.profiles;
create policy profiles_select_self_or_owner
  on public.profiles
  for select
  to authenticated
  using (
    fn_current_role() is not null
    and (id = auth.uid() or fn_current_role() = 'L1_OWNER')
  );
