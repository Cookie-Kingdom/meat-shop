-- Card ^ref-21 — the one thing F5's tables cannot do without a migration.
--
-- transport_runs and transport_lines were both created in ...0003_purchasing_production.sql
-- with everything the card's acceptance line names: dispatched and received weight as
-- separate columns, and variance_reason. This card is therefore the fifth stale-in-Backlog
-- one of the same shape as ^ref-04, ^ref-10, ^ref-13 and ^ref-18, and what it actually owes
-- is the three things Findings 2-4 of PLAN-transport.md found missing.
--
-- 1. THE RETRY. R4 and ADR-005: every write is one transaction carrying a client-generated
--    key. Neither table has one, and neither has a natural key that could stand in:
--
--      * A run has no unique business key at all. Two FOODIVA_TO_CM runs on the same date
--        with the same vehicle type is an ordinary Tuesday.
--      * A line is unique on nothing. (run_id, lot_id) looks like a key and is not: one lot
--        may legitimately ride a run twice when it is split across two smoke date groups,
--        and smoke_date_group_id is null on the outbound leg, so (run_id, lot_id,
--        smoke_date_group_id) collapses back to the first pair exactly where the outbound
--        leg lives.
--
--    Worse here than for purchasing, where ...0008 set this precedent: a replayed
--    fn_dispatch_transport_line posts a SECOND TRANSFER_OUT. fn_post_ledger is idempotent on
--    its own key, but a caller that mints a fresh one per call defeats that — a dropped
--    Chiang Mai connection turns one 40 kg dispatch into 80 kg sitting in IN_TRANSIT against
--    a lot that can then never balance.
--
-- 2. A LINE IS WRITTEN TWICE, SO IT NEEDS TWO KEYS. This is the one place this migration
--    departs from PLAN-transport.md, which asked for three columns. Finding 2 of that plan
--    says it in its own words — "a line is written twice: once at dispatch, once at
--    receipt" — and one key column cannot serialise two distinct writes by two distinct
--    callers. idempotency_key belongs to fn_dispatch_transport_line;
--    receipt_idempotency_key belongs to fn_confirm_transport_receipt. Sharing one column
--    would make the receipt look like a replayed dispatch.
--
--    It is also what makes TC-41 deterministic. Two sessions confirming one line take
--    `select ... for update` on it; the loser sees receipt_idempotency_key already set and
--    raises LINE_ALREADY_RECEIVED instead of posting a second TRANSFER_IN.
--
-- 3. WHEN WAS THIS LINE WRITTEN. ^ref-18 established that ADR-007's "every operational table
--    carries all three clocks" is over-broad: a source row carries event_date + created_at,
--    and only stock_ledger carries business_date and event_at. That correction stands. But
--    transport_lines carries NEITHER — it has received_at and nothing else temporal. The
--    line inherits its dispatch date from the run through run_id, which is right, since a
--    line does not have a date of its own. "When was this row written" has no answer at all,
--    and that is what v_outstanding_receipts needs to age a line and what BR12's alert needs
--    a clock to fire against.
--
-- Nullable, because these are column adds on tables with no rows to backfill. All three
-- functions reject a null key before they write anything, so nothing reaches these tables
-- without one; NOT NULL would only move a named exception to a constraint name.

alter table transport_runs  add column idempotency_key         uuid;
alter table transport_lines add column idempotency_key         uuid;
alter table transport_lines add column receipt_idempotency_key uuid;
alter table transport_lines add column created_at              timestamptz not null default now();

create unique index transport_runs_idempotency_key
  on transport_runs (idempotency_key);
create unique index transport_lines_idempotency_key
  on transport_lines (idempotency_key);
create unique index transport_lines_receipt_idempotency_key
  on transport_lines (receipt_idempotency_key);

-- Finding 4. variance_pct is a SECOND implementation of fn_check_variance and they already
-- disagree: this column rounds to 4 decimals and never rounds before comparing, while
-- fn_check_variance rounds to 2 first and then compares, so 20.004% is inside a 20% band for
-- the function and outside it for the column. Two answers for one line, one on the row and
-- one in the verdict beside it, is the exact failure ADR-019 exists to remove.
--
-- The column stays because it is a cheap sort key and dropping a generated column from an
-- applied table is a rewrite for no gain. The comment is here because the next person to
-- read this DDL will otherwise reach for it.
comment on column transport_lines.variance_pct is
  'Sort key only. The BR12/R22 verdict comes from fn_check_variance (ADR-019), which rounds '
  'before it compares; this column does not. Reading it for a threshold decision '
  'reproduces the disagreement ADR-019 exists to remove. TC-21 asserts they differ.';

comment on column transport_lines.receipt_idempotency_key is
  'The receipt half of R4. A line is written twice by two different callers, so it carries '
  'two keys: idempotency_key is the dispatch, this is the receipt.';
