-- unlock_requests — RLS posture.
--
-- Deny-all, and that is the final posture (^ref-08). Reads arrive through
-- v_unlock_requests, which is SECURITY DEFINER and carries the role test in its own WHERE
-- (R34). Writes go only through fn_request_unlock and fn_decide_unlock (ADR-002, ADR-004).
-- No SELECT policy lands here: a policy would open a second read path around the view's
-- WHERE, and it would hand L3 the decision_impact column, which carries money (R20). This
-- is the same answer ^ref-09 gave for audit_log.
--
-- Migration ...0005 set this posture in one loop over pg_tables at its own migration time,
-- so a table created afterwards inherits none of it. This file is the per-table
-- declaration that does not go stale.

alter table public.unlock_requests enable row level security;
revoke all on public.unlock_requests from anon, authenticated;
