-- Card ^ref-40 — thaw_records gets the retry key it never had (PLAN-thaw.md T2, Finding 1).
--
-- A thaw writes three rows in one transaction: the thaw record and two ledger rows (THAW_OUT
-- off FROZEN, THAW_IN onto READY, R14). R4 says a retry returns the original thaw_record_id and
-- writes nothing. ...0004 gave the table no column that could carry a retry, and the two
-- shortcuts that suggest themselves are both broken:
--
--   * RECOVER THE REPLAY FROM stock_ledger.idempotency_key -> source_id. Two concurrent calls
--     with one key both miss that lookup and both insert a thaw_records row. The second
--     session's ledger insert then blocks on the ledger's unique index, hits `on conflict do
--     nothing`, and commits — a thaw record with NO stock movement behind it. A double thaw
--     in the table and a single one in the ledger.
--   * RIDE THE PAYLOAD. Two genuine 3.00 kg thaws of one lot on one afternoon are ordinary,
--     so the payload cannot tell a retry from a second thaw.
--
-- So the key lives ON THE RECORD, unique, and fn_record_thaw inserts the record FIRST with
-- `on conflict (idempotency_key) do nothing`. The unique index serialises the retry before any
-- ledger row is attempted (TDD-thaw.md Seam 1; thaw_concurrency_test.sh TC-34).
--
-- NOT NULL, unlike the three nullable keys the sales range adds. thaw_records has one writer
-- and no rows in any environment, and there is no state in which a thaw legitimately lacks a
-- key, so the constraint costs nothing and replaces a function check. The same holds for the
-- other two statements: a thaw is meat-only and the FIFO sort cannot place it without a
-- smoke-date group (R15, R21), and a blank override reason is no reason at all.
--
-- NUMBERING. ...0019 is lane B's fixed number for the 10 Sep parallel build
-- (v.0.1/PARALLEL-LANES.md); lane C holds ...0017/...0018. The "next free number" rule of the
-- plan is dead for today.

alter table thaw_records add column idempotency_key uuid not null;

create unique index thaw_records_idempotency_key on thaw_records (idempotency_key);

alter table thaw_records alter column smoke_date_group_id set not null;

alter table thaw_records add constraint thaw_records_fifo_reason_not_blank
  check (fifo_override_reason is null or btrim(fifo_override_reason) <> '');

comment on column thaw_records.idempotency_key is
  'R4 / ADR-005 - the caller''s key. fn_record_thaw inserts the record FIRST, on conflict do '
  'nothing, so a concurrent retry is serialised here before any ledger row is attempted. '
  'Never recovered from stock_ledger (PLAN-thaw.md Finding 1).';
