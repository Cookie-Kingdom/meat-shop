-- opening_balance_close — RLS posture.
--
-- Deny-all until a role-specific v_* for this table exists: reads arrive through a view,
-- writes only through a SECURITY DEFINER fn_* (ADR-002, ADR-004). ^ref-61's
-- v_config_readiness is the view that will read it — as a WARN row while the table is empty
-- — and this file is where its SELECT policy lands if that view ever needs one of its own.
--
-- Migration ...0005 set this posture in one loop over pg_tables at its own migration time,
-- so a table created afterwards inherits none of it. This file is the per-table declaration
-- that does not go stale, and sweep 1a of rls_deny_all_test.sql is what catches its absence.
--
-- There is no DELETE path anywhere in this repo and there must not be one. The deny-all
-- posture is half of that; the other half is that no fn_* deletes from it (ADR-021).

alter table public.opening_balance_close enable row level security;
revoke all on public.opening_balance_close from anon, authenticated;
