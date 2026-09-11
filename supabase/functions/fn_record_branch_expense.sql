-- Card ^ref-51 — fn_record_branch_expense. Emergency spend at a branch, recorded against the
-- person who fronted the cash (PLAN-materials.md T7, Findings 3, 4, 12).
--
-- The card's acceptance: "records emergency spend against the person who fronted the cash."
-- v0.2:94 lists ผู้สำรองจ่าย among BR 07's close inputs, and v0.2:220 repeats it under M5. An
-- expense with nobody behind it cannot be reimbursed and cannot be disputed. So p_paid_by_person
-- is required and not blank, by name here (PAID_BY_REQUIRED), and by NOT NULL + CHECK in
-- ...0020 as the backstop.
--
-- ONE CALL, ONE ROW, ONE KEY (R39, waste_records' shape). Several expenses in a day are several
-- calls, each on its own key, and the screen loops. A batch would make one key cover rows whose
-- payers differ, and a partial retry would be ambiguous. The key is looked up first (R4: a replay
-- returns the original id, whatever its payload says); `on conflict (idempotency_key) do nothing`
-- then re-select covers a concurrent replay that passed the lookup.
--
-- AMOUNT > 0, although the column allows 0. A zero "emergency spend" is no spend, and the P&L
-- (F13) would count it as a row. CATEGORY IS FREE TEXT, trimmed and otherwise untouched: v0.2
-- names no category list (v0.2:204, "ค่าใช้จ่ายอื่น"), and an enum here would be a decision
-- nobody made. One convention does exist, relayed from lane K's cost report: buying any of the 7
-- packaging materials is sent as the exact code `PACKAGING` (PLAN, ^ref-52 stub). It is not
-- enforced, and the case is not changed.
--
-- MONEY, AND NO LEDGER ROW. This is an operating cost, not stock: nothing here posts to
-- stock_ledger, including when the category is PACKAGING (PLAN Cross-lane gaps: packaging
-- receipts have no writer). Branch expenses are L2's to enter (v0.2:59, "กรอกค่าใช้จ่ายสาขา"),
-- and the Owner reads them in F13.
--
-- L2 ONLY, fn_require_branch (v0.2:59: the Owner has ดูต้นทุนทั้งหมด, view). No CLOSED check:
-- lane C's fn_guard_report_closed (...0018) raises REPORT_CLOSED on the insert. R28's window is
-- checked, after the replay (Finding 12), for an OPEN report only: a CLOSED day under an
-- approved, unexpired unlock is lane C's trigger to admit (Finding 4 amended; lane H
-- PLAN-unlock.md Finding 1).
--
-- Covered by supabase/tests/materials_expense_test.sql (TC-74 ... TC-86).

create or replace function public.fn_record_branch_expense(
  p_idempotency_key uuid,
  p_daily_report_id uuid,
  p_category        text,
  p_amount_thb      numeric,
  p_paid_by_person  text,
  p_detail          text default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor  uuid;
  v_report daily_reports;
  v_id     uuid;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- ^fix-numeric-scale: a third decimal is refused by name, not rounded by the column.
  perform fn_require_two_decimals('p_amount_thb', p_amount_thb);

  select * into v_report from daily_reports where id = p_daily_report_id;
  if not found then
    raise exception 'REPORT_NOT_FOUND: no daily report % — open the day first (BR 01)', p_daily_report_id;
  end if;

  v_actor := fn_require_branch(v_report.location_id);

  ------------------------------------------------------------------------ the replay (R4)
  select id into v_id from branch_expenses where idempotency_key = p_idempotency_key;
  if found then
    return v_id;
  end if;

  ------------------------------------------------------------------------ the window (R28)
  -- OPEN days only. An approved unlock leaves the day CLOSED and writes an APPROVED, unexpired
  -- DAILY_REPORT unlock_requests row (lane H, PLAN-unlock.md Finding 1). Lane C's trigger alone
  -- decides a CLOSED day: it admits the write under a live unlock, whatever the day's age, and
  -- refuses it with REPORT_CLOSED once expires_at has passed (R42). So the window is the
  -- ordinary path's rule and never the escalation's (v0.2:401 D07). Nested, so
  -- fn_backdating_allowed is not even asked about a non-OPEN day.
  if v_report.status = 'OPEN' then
    if not fn_backdating_allowed(v_report.report_date) then
      raise exception 'BACKDATE_NOT_ALLOWED: % is outside the back-dating window — an expense that old goes through the unlock path (R28)',
        v_report.report_date;
    end if;
  end if;

  --------------------------------------------------------------------------- the arguments
  if p_category is null or btrim(p_category) = '' then
    raise exception 'EXPENSE_CATEGORY_REQUIRED: say what the money was for (BR 07)';
  end if;

  if p_amount_thb is null or p_amount_thb <= 0 then
    raise exception 'EXPENSE_AMOUNT_INVALID: an expense is a positive amount in baht, got %',
      coalesce(p_amount_thb::text, 'null');
  end if;

  if p_paid_by_person is null or btrim(p_paid_by_person) = '' then
    raise exception 'PAID_BY_REQUIRED: name the person who fronted the cash — an expense nobody paid cannot be reimbursed (v0.2:94)';
  end if;

  ------------------------------------------------------------------------------ the write
  insert into branch_expenses (daily_report_id, category, amount_thb, paid_by_person, detail,
                               created_by, idempotency_key)
       values (v_report.id, btrim(p_category), p_amount_thb, btrim(p_paid_by_person),
               nullif(btrim(p_detail), ''), v_actor, p_idempotency_key)
  on conflict (idempotency_key) do nothing
  returning id into v_id;

  if v_id is null then
    -- A concurrent replay of this key committed first. Answer with its row (R4).
    select id into v_id from branch_expenses where idempotency_key = p_idempotency_key;
  end if;

  return v_id;
end $$;

revoke execute on function public.fn_record_branch_expense(uuid, uuid, text, numeric, text, text) from public, anon, authenticated;
grant  execute on function public.fn_record_branch_expense(uuid, uuid, text, numeric, text, text) to authenticated;
