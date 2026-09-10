-- Card ^ref-53 — the write half owner_expenses has lacked since …0005.
--
-- …0005 created the table (kind, event_date, expense_month, location_id, amount_thb, detail,
-- created_by, created_at) and nothing ever wrote it. Two things it cannot do without a
-- migration, both recorded in v.0.1/ref-53-54-owner-expenses/PLAN-owner-expenses.md:
--
-- 1. THE RETRY NEEDS A COLUMN (R39, not R38). Two identical expenses on one day are ordinary —
--    two ฿1,200 gas refills — so a payload key would refuse the second as a duplicate, which
--    is …0008's TC-24 argument word for word. The key gets a column and a unique index, the
--    same as purchase_orders and po_deliveries. Nullable for …0008's reason: the function
--    refuses a null key before it writes, and NOT NULL would only turn a named error into a
--    constraint name.
--
-- 2. ONE MONTH SOURCE PER KIND. expense_month was free next to event_date, so an investment
--    could carry a month different from the one it was bought in — and ADR-020 books an
--    investment in full in the month it was bought. So:
--      MONTHLY_FIXED  names the month it covers (rent for October, paid 28 Sep)
--      anything else  takes the month of its event_date, and carries no expense_month
--    A biconditional, so the P&L reads one expression — coalesce(expense_month,
--    to_char(event_date, 'YYYY-MM')) — with no third case to decide. The …0005 regex also
--    accepted '2026-13'; the second check closes that.
--
-- ADR-020 CLOSED 9 Sep with no depreciation, no asset life and no asset register: nothing here
-- adds an asset-life column, and expenses_test.sql TC-02 fails the day one appears.

alter table public.owner_expenses add column idempotency_key uuid;

create unique index owner_expenses_idempotency_key
  on public.owner_expenses (idempotency_key);

alter table public.owner_expenses
  add constraint owner_expenses_month_iff_monthly
  check ((kind = 'MONTHLY_FIXED') = (expense_month is not null));

alter table public.owner_expenses
  add constraint owner_expenses_month_valid
  check (expense_month ~ '^\d{4}-(0[1-9]|1[0-2])$');
