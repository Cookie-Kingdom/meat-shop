-- opening_costs — RLS posture.
--
-- Deny-all until a role-specific v_* for this table exists: reads arrive through a view,
-- writes only through a SECURITY DEFINER fn_* (ADR-002, ADR-004).
--
-- R20 makes the posture load-bearing rather than provisional here. This table holds a price,
-- and an L3 chef house operator is exactly who counts the meat it belongs to. BR15 keeps the
-- price out of fn_record_opening_balance's signature; this keeps it out of a select.
--
-- Migration ...0005 set this posture in one loop over pg_tables at its own migration time,
-- so a table created afterwards inherits none of it. This file is the per-table declaration
-- that does not go stale, and sweep 1a of rls_deny_all_test.sql is what catches its absence.

alter table public.opening_costs enable row level security;
revoke all on public.opening_costs from anon, authenticated;
