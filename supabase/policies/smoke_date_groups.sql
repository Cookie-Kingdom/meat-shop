-- smoke_date_groups — RLS posture.
--
-- Deny-all until a role-specific v_* view for this table exists: reads arrive through the
-- view, writes only through a SECURITY DEFINER fn_* (ADR-002, ADR-004). This file is where
-- smoke_date_groups's SELECT policy lands when the card that owns its view is written.
--
-- Migration ...0005 set this posture in one loop over pg_tables at its own migration time,
-- so a table created afterwards inherits none of it. This file is the per-table
-- declaration that does not go stale.

alter table public.smoke_date_groups enable row level security;
revoke all on public.smoke_date_groups from anon, authenticated;
