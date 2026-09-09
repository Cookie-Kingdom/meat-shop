-- Card ^ref-11 — the shared front door for every L1-only write function.
--
-- Written for the four config setters; ^ref-19's fn_create_po and fn_add_po_delivery are
-- the second caller, which is why the FORBIDDEN message no longer says "config".
--
-- Every fn_set_* on this card opens with the same two questions, and the order they are
-- asked in is the behaviour, not a detail:
--
--   1. Is there an active profile behind this JWT?  No → NO_ACTOR (R31).
--   2. Is it L1?                                    No → FORBIDDEN (ADR-004).
--
-- Actor first, because fn_current_role() folds in is_active and goes null for a
-- deactivated Owner holding a live token. Asking the role first would report that Owner as
-- FORBIDDEN — true, but it hides the real state from whoever reads the error, and TC-12
-- pins the distinction.
--
-- The role is checked here rather than by a policy because these are SECURITY DEFINER
-- functions: RLS does not apply inside them, so there is no policy to consult. The
-- function is the boundary (ADR-002).
--
-- created_by comes out of this and is never a parameter. A rate change is the thing the
-- audit trail exists for, and a caller must not be able to sign one as somebody else.
--
-- EXECUTE is granted to nobody: it is the setters' preamble, not an endpoint.

create or replace function public.fn_require_owner()
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

  if fn_current_role() <> 'L1_OWNER' then
    raise exception 'FORBIDDEN: this write is L1 only (ADR-004)';
  end if;

  return v_actor;
end $$;

revoke execute on function public.fn_require_owner() from public;
