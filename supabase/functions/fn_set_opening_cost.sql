-- Card ^ref-62, T6 — fn_set_opening_cost. The price half of the two-step, and L1 only.
--
-- BR15 keeps the price away from whoever counted the meat, so the quantity and the cost are
-- entered by different people at different times. This is a SEPARATE FUNCTION rather than a
-- cost parameter on fn_record_opening_balance precisely so that "who may enter a price" is
-- answered by which function you may call, not by a branch inside one that a later edit can
-- weaken without anyone noticing.
--
-- IT WRITES A DIFFERENT TABLE, AND THAT IS ADR-003 DECIDING (PLAN Finding 2). Filling a cost
-- in after the count is an UPDATE, and trg_stock_ledger_append_only refuses every UPDATE on
-- stock_ledger at the statement level. The alternative was relaxing that trigger for one
-- column while the window is open — a hole in ADR-003 that stays open exactly as long as
-- somebody remembers to close it. So the cost lives in opening_costs, keyed on the ledger
-- row, and the ledger row never moves. TC-24 asserts that: set 200, then 220, and
-- stock_ledger is untouched both times.
--
-- NO IDEMPOTENCY KEY PARAMETER, DELIBERATELY (TDD Open Question 4, settled here). R4 wants
-- every write RPC to carry one; R38 and R39 say what that actually means — where a NATURAL
-- unique key carries the retry, no key column is added, and only where it cannot does the
-- key get one. Here the primary key IS the payload target: the ledger id. A replay upserts
-- the same value onto the same row and changes nothing. A deliberate second correction
-- carries a different value, and ^ref-06's audit trigger records it as its own UPDATE row,
-- so the audit trail already distinguishes the two cases a key would have been added to
-- distinguish. Same reasoning fn_open_daily_report used under R5. Adding a key here would be
-- a parameter that looks load-bearing and is not, which is the kind of thing that lies.
--
-- AN UPSERT RATHER THAN AN INSERT because the Owner correcting a figure BEFORE the close is
-- ordinary. After the close there is nothing to correct, because nothing more can be
-- entered — and a costless row cannot survive the close by construction
-- (fn_close_opening_balances is the completeness check).
--
-- Covered by supabase/tests/opening_balance_test.sql (TC-22, TC-23, TC-24).

create or replace function public.fn_set_opening_cost(
  p_ledger_id       uuid,
  p_cost_thb_per_kg numeric
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_type  movement_type;
begin
  v_actor := fn_require_owner();

  if p_cost_thb_per_kg is null then
    raise exception 'OPENING_COST_REQUIRED: a cost is a number the Owner states, never a null (BR23)';
  end if;

  select movement_type into v_type from stock_ledger where id = p_ledger_id;
  if v_type is null then
    raise exception 'LEDGER_ROW_NOT_FOUND: no stock_ledger row %', p_ledger_id;
  end if;

  -- Scoped to one movement type, which is the third reason OPENING is its own enum value
  -- rather than an ADJUSTMENT carrying a reason string: a completeness rule that applied to
  -- ADJUSTMENT would demand a cost on every correction the system ever writes.
  if v_type <> 'OPENING' then
    raise exception 'NOT_AN_OPENING_ROW: ledger row % is a % (R46)', p_ledger_id, v_type;
  end if;

  insert into opening_costs (ledger_id, cost_thb_per_kg, set_by)
    values (p_ledger_id, p_cost_thb_per_kg, v_actor)
  on conflict (ledger_id) do update
    set cost_thb_per_kg = excluded.cost_thb_per_kg,
        set_by          = excluded.set_by,
        set_at          = now();

  return p_ledger_id;
end $$;

revoke execute on function public.fn_set_opening_cost(uuid, numeric) from public, anon, authenticated;
grant  execute on function public.fn_set_opening_cost(uuid, numeric) to   authenticated;
