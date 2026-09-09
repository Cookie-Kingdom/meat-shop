-- audit_log — RLS posture.
--
-- Deny-all, and that is the FINAL posture, not a placeholder. Card ^ref-09 wrote the view
-- this file used to be waiting on (v_audit_trail, supabase/views/040) and the answer it
-- came back with is that no SELECT policy lands here: the view is SECURITY DEFINER and
-- bypasses RLS, so reads arrive through it and writes only through fn_audit_row, which is
-- SECURITY DEFINER for the same reason (ADR-002, ADR-004).
--
-- A SELECT policy added here would not extend the audit screen; it would open a second
-- read path around the L1-only WHERE clause that is the card's whole acceptance.
--
-- Migration ...0005 set this posture in one loop over pg_tables at its own migration time,
-- so a table created afterwards inherits none of it. This file is the per-table
-- declaration that does not go stale.

alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon, authenticated;
