-- Card ^ref-53 — fn_record_owner_expense. OW 09 (M11): an investment or a monthly fixed cost,
-- with a detail written for cross-checking the bank transfer. L1 only.
--
-- M11 AC (v0.2:285–286): the Owner records Investment, monthly costs and transfer-check
-- detail "โดยไม่กระทบสูตรกำไรรอบแรก", and "L2/L3 ไม่เข้าถึงข้อมูลบัญชี Owner". This function is
-- the first half — fn_require_owner refuses everyone else by name — and v_owner_expenses's
-- WHERE is the read half (R34).
--
-- THE หมวด IS `kind` (PLAN Finding 8). OW 09 in v0.2:110 reads "รายเดือนหรือมี Investment |
-- หมวด จำนวนเงิน รายละเอียด และวันที่": the category is monthly-or-investment, and source/ names
-- no other vocabulary. OTHER is anything that is neither.
--
-- ORDER, AND WHY. Key → actor → shape → the insert. The shape checks come before the
-- idempotency comparison so a malformed replay fails for the reason it is malformed, not as a
-- conflict with a row it could never have written.
--
-- IDEMPOTENCY (R39, R4). owner_expenses.idempotency_key is unique (…0025). The insert goes
-- first with `on conflict (idempotency_key) do nothing`: a fresh key writes, a used key writes
-- nothing, and a concurrent twin loses the race to the unique index rather than to a
-- select-then-insert gap. Then the stored row is compared with the payload — the same payload
-- is a dropped connection and returns the original id; a different one is
-- EXPENSE_IDEMPOTENCY_CONFLICT, because the key wins and the payload may not quietly move.
-- The amount used to be rounded to numeric(12,2) before the comparison, so that a retry of
-- 100.005 matched the 100.01 the column stored. ^fix-numeric-scale refuses a third decimal
-- before that point (fn_require_two_decimals), so the round() below is now a no-op.
--
-- MONTH (PLAN Finding 3, …0025): MONTHLY_FIXED must name the month it covers; every other kind
-- must not, and lands in the month of its event_date (ADR-020 — an investment is expensed in
-- full in the month bought). The constraints refuse the same rows; these raises say which rule
-- in words a Thai sentence can attach to.
--
-- created_by comes from fn_require_owner() and is never a parameter. The audit row is written
-- by ^ref-06's generic trigger in the same transaction (R32). No stock_ledger row: an expense
-- is money, not a movement.
--
-- Covered by supabase/tests/expenses_test.sql (TC-05 … TC-20).

create or replace function public.fn_record_owner_expense(
  p_idempotency_key uuid,
  p_kind            expense_kind,
  p_event_date      date,
  p_amount_thb      numeric,
  p_detail          text,
  p_expense_month   text default null,
  p_location_id     uuid default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor  uuid;
  v_amount numeric(12,2);
  v_detail text;
  v_month  text;
  v_id     uuid;
  v_row    owner_expenses;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- ^fix-numeric-scale: a third decimal is refused by name, not rounded by the column.
  perform fn_require_two_decimals('p_amount_thb', p_amount_thb);

  v_actor := fn_require_owner();

  if p_kind is null then
    raise exception 'EXPENSE_KIND_REQUIRED: an expense is an INVESTMENT, a MONTHLY_FIXED cost or OTHER (M11)';
  end if;
  if p_event_date is null then
    raise exception 'EXPENSE_DATE_REQUIRED: an expense carries the date it was paid';
  end if;

  v_amount := round(p_amount_thb, 2);
  if v_amount is null or v_amount <= 0 then
    raise exception 'EXPENSE_AMOUNT_INVALID: an expense is a positive amount in THB, got %', p_amount_thb;
  end if;

  v_detail := nullif(btrim(p_detail), '');
  if v_detail is null then
    raise exception 'EXPENSE_DETAIL_REQUIRED: the detail is what matches this row to a bank transfer (M11)';
  end if;

  v_month := nullif(btrim(p_expense_month), '');
  if p_kind = 'MONTHLY_FIXED' and v_month is null then
    raise exception 'EXPENSE_MONTH_REQUIRED: a monthly fixed cost names the month it covers (YYYY-MM)';
  end if;
  if p_kind <> 'MONTHLY_FIXED' and v_month is not null then
    raise exception 'EXPENSE_MONTH_NOT_ALLOWED: a % lands in the month of its date, not in %', p_kind, v_month;
  end if;
  if v_month is not null and v_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then
    raise exception 'EXPENSE_MONTH_INVALID: % is not a YYYY-MM month', v_month;
  end if;

  if p_location_id is not null
     and not exists (select 1 from locations where id = p_location_id) then
    raise exception 'LOCATION_NOT_FOUND: no location %', p_location_id;
  end if;

  insert into owner_expenses (
    kind, event_date, expense_month, location_id, amount_thb, detail,
    created_by, idempotency_key)
  values (
    p_kind, p_event_date, v_month, p_location_id, v_amount, v_detail,
    v_actor, p_idempotency_key)
  on conflict (idempotency_key) do nothing
  returning id into v_id;

  if v_id is not null then
    return v_id;
  end if;

  -- The key is taken. Same payload → the retry of a dropped connection (R4).
  select * into v_row from owner_expenses where idempotency_key = p_idempotency_key;

  if v_row.kind = p_kind
     and v_row.event_date = p_event_date
     and v_row.amount_thb = v_amount
     and v_row.detail = v_detail
     and v_row.expense_month is not distinct from v_month
     and v_row.location_id   is not distinct from p_location_id then
    return v_row.id;
  end if;

  raise exception 'EXPENSE_IDEMPOTENCY_CONFLICT: key % was used for a different expense (R39)',
    p_idempotency_key;
end $$;

revoke execute on function public.fn_record_owner_expense(uuid, expense_kind, date, numeric, text, text, uuid)
  from public, anon, authenticated;
grant  execute on function public.fn_record_owner_expense(uuid, expense_kind, date, numeric, text, text, uuid)
  to authenticated;
