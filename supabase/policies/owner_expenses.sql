-- owner_expenses — RLS posture.
--
-- Deny-all, and that is the FINAL posture (card ^ref-53): writes arrive only through
-- fn_record_owner_expense (SECURITY DEFINER, L1 only), reads only through v_owner_expenses,
-- whose WHERE returns zero rows to anyone but L1 (ADR-002, ADR-004, R34; M11 AC "L2/L3 ไม่
-- เข้าถึงข้อมูลบัญชี Owner"). No SELECT policy lands here, so nobody should go looking for one.
--
-- Standing consequence: never `force row level security` on this table — the view runs as its
-- owner and would return nothing for everyone.
--
-- Migration ...0005 set this posture in one loop over pg_tables at its own migration time,
-- so a table created afterwards inherits none of it. This file is the per-table
-- declaration that does not go stale.

alter table public.owner_expenses enable row level security;
revoke all on public.owner_expenses from anon, authenticated;
