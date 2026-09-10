-- Card ^ref-08 — unlock_requests gains what fn_request_unlock and fn_decide_unlock need.
-- The table itself is ...0002's and its column names do not move: fn_guard_lot_closed
-- (...0013) and lane C's fn_guard_report_closed (...0018) both read
-- (target_type, target_id, status, expires_at), and that shape is the contract.
--
-- 1. idempotency_key (R4, ADR-005). Every write RPC takes a client-generated key, and a
--    request row is the thing a dropped connection would otherwise duplicate. Nullable on
--    purpose: fixtures in lot_close_test.sql and receipt_state_floor_test.sql insert rows
--    directly, and a unique index treats nulls as distinct.
--
-- 2. decision_impact (D07, R28). "Every decision shows the impact on sales, stock and profit
--    before it is written." The impact the Owner was shown is stored with the decision, so
--    an R4 replay of the decision returns exactly what was approved, and the audit row
--    carries it. Null for a PENDING row, whose impact is computed live, and for an L2
--    auto-approval, which no Owner decided.
--
-- 3. unlock_requests_one_pending. One open question per day or lot. The target row lock in
--    fn_request_unlock serialises requests per target, and this index is what still holds
--    against a writer added in 2027.
--
-- 4. unlock_requests_expiry_required (R42). "expires_at is NOT NULL and every unlock closes
--    itself." It cannot be a column NOT NULL, because a PENDING or REJECTED row has no
--    expiry. So: an APPROVED row, and the EXPIRED row it becomes, must carry one.
--
-- Covered by supabase/tests/unlock_test.sql (UL-40 ... UL-42).

alter table unlock_requests add column idempotency_key uuid;
create unique index unlock_requests_idempotency_key on unlock_requests (idempotency_key);

alter table unlock_requests add column decision_impact jsonb;

create unique index unlock_requests_one_pending
  on unlock_requests (target_type, target_id) where status = 'PENDING';

alter table unlock_requests add constraint unlock_requests_expiry_required
  check (status not in ('APPROVED', 'EXPIRED') or expires_at is not null);

comment on column unlock_requests.idempotency_key is
  'R4: the key of the fn_request_unlock call that created the row. A repeat returns this row.';
comment on column unlock_requests.decision_impact is
  'D07: fn_unlock_impact as the deciding Owner saw it, stored with the decision. Null while '
  'PENDING (computed live) and on an L2 auto-approval inside R28''s window.';
