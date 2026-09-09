-- Card ^ref-19 — the one thing ^ref-18's tables cannot do without a migration.
--
-- R4 and ADR-005 require every write to be one transaction carrying a client-generated
-- idempotency key. TDD-config-layer.md satisfied that with no migration by riding each
-- config table's natural unique key, which already includes the date. That does not work
-- here, and the reason is worth writing down before somebody tries it again:
--
--   * purchase_orders.po_number is unique, but it is GENERATED INSIDE fn_create_po. A
--     replayed call mints a second number and a second PO, and the unique index never fires.
--   * po_deliveries is unique on (po_id, seq), and seq is DERIVED as max(seq)+1. A replayed
--     call computes the next seq and books the round a second time. A dropped connection on
--     OW 01 silently turns one 30 kg dispatch into two, and every lot, freight share and
--     yield figure downstream inherits it.
--   * Riding a payload key instead — (po_id, event_date, foodiva_sent_weight_kg) — is worse
--     than no key: two genuine 40 kg rounds on the same day are an ordinary thing, and that
--     key refuses the second one as a duplicate (TC-24).
--
-- So the key gets a column. stock_ledger already stores its own the same way, so this is
-- that precedent rather than a new mechanism. R4's rpc_calls table is still not built and
-- still creates no table here: two columns, two unique indexes.
--
-- Nullable, because this is a column add on tables with no rows to backfill. Both functions
-- reject a null key before they write anything, so nothing can reach these tables without
-- one; making the column NOT NULL would only move that error from a named exception to a
-- constraint name.

alter table purchase_orders add column idempotency_key uuid;
alter table po_deliveries   add column idempotency_key uuid;

create unique index purchase_orders_idempotency_key on purchase_orders (idempotency_key);
create unique index po_deliveries_idempotency_key   on po_deliveries   (idempotency_key);
