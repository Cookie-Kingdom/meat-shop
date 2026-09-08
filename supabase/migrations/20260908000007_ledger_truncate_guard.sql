-- R1 / ADR-003: close the TRUNCATE hole in the append-only guard.
--
-- 20260908000004 installed trg_stock_ledger_append_only as `before update or delete`.
-- A TRUNCATE fires neither event, so the one statement that empties the whole ledger in
-- a single shot went straight past the guard that exists to make that impossible.
-- Postgres requires a separate `before truncate` statement trigger; the raising function
-- is the same one.
--
-- Covered by supabase/tests/ledger_truncate_test.sql.

create trigger trg_stock_ledger_no_truncate
  before truncate on stock_ledger
  for each statement execute function fn_stock_ledger_append_only();
