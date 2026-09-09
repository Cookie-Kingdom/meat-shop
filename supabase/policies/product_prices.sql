-- product_prices — RLS posture. Final, not a placeholder (card ^ref-12).
--
-- Deny-all, and it stays deny-all. Reads arrive through v_config_history, writes only
-- through a SECURITY DEFINER fn_set_* (ADR-002, ADR-004).
--
-- ^ref-11 left this file saying "the SELECT policy lands when the card that owns its view
-- is written." ^ref-12 is that card, and the answer is that NO SELECT POLICY LANDS. The
-- view is SECURITY DEFINER and carries `where fn_current_role() = 'L1_OWNER'` (R34, R20);
-- a policy here would be a second read path around that WHERE, reachable by any session
-- that types the table name into PostgREST. One door, and the view is it.
--
-- Standing consequence: never `force row level security` on this table or on profiles.
-- The view runs as the owner and forcing RLS would make it return nothing — for L1 too.
--
-- Migration ...0005 set this posture in one loop over pg_tables at its own migration time,
-- so a table created afterwards inherits none of it. This file is the per-table
-- declaration that does not go stale.

alter table public.product_prices enable row level security;
revoke all on public.product_prices from anon, authenticated;
