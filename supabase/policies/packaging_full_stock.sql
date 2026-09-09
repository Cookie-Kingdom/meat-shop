-- packaging_full_stock — RLS posture.
--
-- Deny-all until a role-specific v_* view for this table exists: reads arrive through the
-- view, writes only through a SECURITY DEFINER fn_* (ADR-002, ADR-004). This file is where
-- packaging_full_stock's SELECT policy lands when the card that owns its view is written.
--
-- Migration ...0005 set this posture in one loop over pg_tables at its own migration time,
-- so a table created afterwards inherits none of it. This file is the per-table
-- declaration that does not go stale.

alter table public.packaging_full_stock enable row level security;
revoke all on public.packaging_full_stock from anon, authenticated;
