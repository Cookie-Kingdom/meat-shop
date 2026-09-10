-- Card ^ref-47 — what the three F11 tables owe their writers (PLAN-materials.md T1, Findings 1,
-- 2, 11, 13). physical_counts, rice_records and branch_expenses were all created in
-- ...0004_stock_and_branch_daily.sql, with created_by NOT NULL and a unit on every quantity
-- column. So this card is not a create-table card. What is missing is three retry keys, two
-- row-shape rules and one NOT NULL, and each one is a way the writers (^ref-48, ^ref-49,
-- ^ref-51) would fail silently without it.
--
-- EVERY ADDED KEY COLUMN IS NULLABLE. Lane C's sales_schema_test.sql TC-11 and
-- branch_daily_test.sql:296,314 insert physical_counts / rice_records rows as the migration
-- owner with no key. Each writer rejects a null key by name before it writes, the precedent
-- ...0008, ...0010 and ...0013 set. NOT NULL would only turn that named exception into a
-- constraint name.
--
-- NO THIRD CLOCK. ADR-007 was narrowed to stock_ledger at ^ref-19. These are source tables:
-- they carry event_date + created_at, and branch_expenses takes its date from
-- daily_reports.report_date. purchasing_schema_test.sql TC-03 fails the day a second table
-- gains business_date or event_at.
--
-- NO SEED of the 7 packaging_items (v0.2:95, :246). lane C's fn_close_daily_report refuses a
-- close until every active packaging_items row has a count, so seeding them here switches that
-- gate on under every close test lane C has written. The seed belongs to ^ref-61 or the
-- coordinator (PLAN-materials.md, Cross-lane gaps).
--
-- Covered by supabase/tests/materials_schema_test.sql (TC-01 ... TC-09).

------------------------------------------------------------------------ 1. physical_counts
-- R39. One fn_record_physical_count call is ONE BATCH (the 7 materials, chilli and meat on one
-- screen), so the key is per batch and seq is minted inside the function as the array's
-- ordinality: lot_bags' shape from ...0013, and sales_lines' from lane C's ...0018. A key alone
-- would refuse the second line of the batch.
alter table physical_counts add column idempotency_key uuid;
alter table physical_counts add column seq integer check (seq > 0);

alter table physical_counts add constraint physical_counts_batch_key
  unique (idempotency_key, seq);

-- BR21 / the card's acceptance: chilli paste is counted in whole tubes, and a material in whole
-- units. The column stays numeric(12,2) because a SMOKED_MEAT count is kg, the same unit as
-- stock_ledger.qty_delta, and one column has to hold both.
--
-- counted_qty ONLY, NOT system_qty (PLAN-materials.md Finding 11). system_qty is a ledger sum
-- and a reported figure. If the ledger ever held a fractional chilli balance, a CHECK on it would
-- make the count unsavable, hiding the very discrepancy the count exists to report (R19).
alter table physical_counts add constraint physical_counts_whole_units check (
  item_type not in ('CHILLI_PASTE', 'PACKAGING') or counted_qty = trunc(counted_qty));

comment on column physical_counts.counted_qty is
  'What was physically counted, in the item''s own unit: kg for SMOKED_MEAT, 30 g tubes for '
  'CHILLI_PASTE, the packaging_items.unit for PACKAGING. Whole units for CHILLI_PASTE and '
  'PACKAGING (BR21, physical_counts_whole_units). Never written to stock_ledger (R19).';
comment on column physical_counts.system_qty is
  'Ledger balance at count time for the same tuple (location, item, packaging item or smoke '
  'group; IN_TRANSIT excluded), snapshotted without a lock. A reported number, not a posting.';
comment on column physical_counts.idempotency_key is
  'R39 batch key: one fn_record_physical_count call, one key; seq is the row''s position in '
  'the batch. Null on rows no RPC wrote.';

--------------------------------------------------------------------------- 2. rice_records
-- R39, the smoke_daily_logs shape. The row is written TWICE on purpose: BR 03 in the morning
-- (received or cooked weights) and BR 07 in the evening (what is left). The natural key is
-- daily_report_id, so a second write is normal and not a retry. The column holds the key of
-- the MOST RECENT write, which is what makes a plain unique index safe across the two visits.
alter table rice_records add column idempotency_key uuid;

create unique index rice_records_idempotency_key on rice_records (idempotency_key);

-- M7A / M7B (v0.2:90, :236). EXTERNAL_COOKED (มีนบุรี) receives cooked rice and never cooks;
-- SELF_COOK (ศาลาแดง) buys raw rice, cooks it, and receives no cooked rice. A field from the
-- other model on a row is a number that belongs to no process. The fields both models share,
-- carried_in_cooked_kg and cooked_remaining_kg, are unconstrained, which is why
-- branch_daily_test.sql's cooked_remaining_kg-only fixtures still insert.
alter table rice_records add constraint rice_records_model_fields check (
  case model
    when 'EXTERNAL_COOKED' then
      num_nonnulls(raw_purchased_kg, raw_price_thb_per_kg, cooked_today_kg, raw_remaining_kg) = 0
    when 'SELF_COOK' then
      num_nonnulls(cooked_received_kg, cooked_price_thb_per_kg) = 0
  end);

comment on column rice_records.idempotency_key is
  'Key of the MOST RECENT fn_record_rice write (R39). The row is written twice a day, morning '
  '(BR 03) and evening (BR 07), so a replayed key returns the row and a fresh key merges.';

------------------------------------------------------------------------ 3. branch_expenses
-- R39, the waste_records shape: one fn_record_branch_expense call is one row, so the key
-- alone is exact.
alter table branch_expenses add column idempotency_key uuid;

create unique index branch_expenses_idempotency_key on branch_expenses (idempotency_key);

-- ^ref-51's acceptance: "records emergency spend against the person who fronted the cash".
-- v0.2:94 and :204 name ผู้สำรองจ่าย as an input of the close. An expense with nobody behind it
-- cannot be reimbursed and cannot be disputed. No test or function inserts into this table,
-- so NOT NULL costs nothing today.
alter table branch_expenses alter column paid_by_person set not null;
alter table branch_expenses add constraint branch_expenses_paid_by_not_blank
  check (btrim(paid_by_person) <> '');

comment on column branch_expenses.paid_by_person is
  'Who fronted the cash (ผู้สำรองจ่าย, v0.2:94). Required and not blank: an expense nobody '
  'paid for cannot be reimbursed.';
