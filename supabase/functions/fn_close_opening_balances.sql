-- Card ^ref-62, T7 — fn_close_opening_balances. One-way, permanently, for everyone.
--
-- THE COMPLETENESS CHECK AND THE CLOSE ARE THE SAME OPERATION (TDD Seam 1). There is no
-- "are all the costs entered?" screen that could drift from the close's own answer, because
-- the close computes it. Split into a check and a close, the failure is concrete: the check
-- passes, somebody enters one more opening row, the close succeeds, and there is a costless
-- lot in the ledger for ever with no path to fix it — the ledger refuses UPDATE and no
-- OPENING row can be written again.
--
-- R28 RE-ARMS BY CONSEQUENCE, NOT BY A SECOND STATEMENT. fn_backdating_allowed reads
-- opening_balance_close, and after this function the table has its row. Nothing here
-- re-enables the unlock window; there is one switch and one audit line. Writing a "re-arm"
-- step would be a second mechanism that can disagree with the first, and the day they
-- disagree nobody can say which one the system is actually obeying (ADR-021, TDD Seam 4).
--
-- THE IDEMPOTENCY KEY IS LOAD-BEARING HERE, unlike in fn_set_opening_cost. R4 wants a retry
-- to return the original result; TC-29 wants a second close refused. Those are the same
-- statement arriving twice and only the key tells them apart: the same key returns the
-- committed closed_at, a different key raises OPENING_ALREADY_CLOSED. Catching
-- unique_violation and re-raising it unconditionally — which is what the plan drafted —
-- would turn every dropped connection into a permanent-looking refusal on an operation the
-- Owner cannot retry and cannot undo.
--
-- The audit row is ^ref-06's generic trigger, in this same transaction (R32). Not written
-- here; that would audit the close twice.
--
-- Covered by supabase/tests/opening_close_test.sql (TC-25 ... TC-30, TC-40).

create or replace function public.fn_close_opening_balances(p_idempotency_key uuid)
  returns timestamptz
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor  uuid;
  v_when   timestamptz;
  v_n      bigint;
  v_lots   text;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  v_actor := fn_require_owner();

  -- R4 first: a replay is not a second close and must not be reported as one.
  select closed_at into v_when from opening_balance_close
   where closed_idempotency_key = p_idempotency_key;
  if v_when is not null then
    return v_when;
  end if;

  if exists (select 1 from opening_balance_close) then
    raise exception 'OPENING_ALREADY_CLOSED: opening balances were closed at % by % (ADR-021)',
      (select closed_at from opening_balance_close),
      (select closed_by from opening_balance_close);
  end if;

  -- A LEFT JOIN, not a null-column test: the cost is a row in another table because the
  -- ledger refuses UPDATE (PLAN Finding 2b). Same completeness check, one join along.
  select count(*),
         string_agg(distinct coalesce(lo.lot_code, sl.item_type::text), ', ' order by
                    coalesce(lo.lot_code, sl.item_type::text))
    into v_n, v_lots
    from stock_ledger sl
    left join opening_costs oc on oc.ledger_id = sl.id
    left join lots         lo on lo.id         = sl.lot_id
   where sl.movement_type = 'OPENING'
     and oc.ledger_id is null;

  if v_n > 0 then
    -- Naming the count AND the lots, because the Owner reading this has to go and find them,
    -- and "some rows have no cost" is not something anyone can act on.
    raise exception 'OPENING_COST_MISSING: % opening row(s) still have no cost: % (R46/ADR-021)',
      v_n, left(v_lots, 200);
  end if;

  insert into opening_balance_close (closed_by, closed_idempotency_key)
    values (v_actor, p_idempotency_key)
    returning closed_at into v_when;

  return v_when;
end $$;

revoke execute on function public.fn_close_opening_balances(uuid) from public, anon, authenticated;
grant  execute on function public.fn_close_opening_balances(uuid) to   authenticated;
