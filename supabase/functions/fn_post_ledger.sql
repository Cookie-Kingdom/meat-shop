-- fn_post_ledger() — the ONLY thing in the system that inserts into stock_ledger.
--
-- Every fn_record_* in API_DATA_MODEL.md calls this; none of them writes the table. Five
-- call sites each re-implementing the idempotency branch and the balance lock is five
-- chances to get one wrong (ADR-002, ADR-005, TDD-ledger-core.md §1).
--
-- Three things this function is responsible for, and one it deliberately is not:
--
--   1. Idempotency is a RETURN, not a raise (R4). A retry from a dropped Chiang Mai
--      connection must look to the client exactly like the first call succeeded — raising
--      a unique violation would make the client retry forever. The key wins and the
--      payload is ignored: a replay can never move a figure that is already committed.
--
--   2. No tuple ever goes negative (R3, BR24, UAT-05). Balance is SUM(qty_delta), not a
--      row, so there is nothing to SELECT … FOR UPDATE. Serialisation comes from a
--      TRANSACTION-scoped advisory lock on the tuple, taken before the SUM and released by
--      the commit. It must stay the xact form: pg_advisory_lock is session-scoped and
--      would leak the lock into whatever request next borrows the pooled connection.
--      Without the lock, two concurrent draws both read the same balance and both commit —
--      the single most likely way this function fails silently. supabase/tests/
--      ledger_concurrency_test.sh is what proves it, and it is the only test that can.
--
--   3. Every meat movement names its source lot (R21, ADR-017). fn_require_lot_for_meat
--      guards sales_lines and waste_records; nothing guarded stock_ledger until now.
--
-- NOT its responsibility: the audit row. ^ref-06's generic trigger already fires on
-- stock_ledger inserts, inside this same transaction. Writing one here as well would audit
-- every movement in the system twice (R32).
--
-- SECURITY DEFINER, and EXECUTE is granted to nobody. `authenticated` calling this
-- directly would post arbitrary ledger rows past every business rule the fn_record_*
-- layer exists to enforce. Definer functions run as the owner, so they can call it; a
-- session cannot.

create or replace function public.fn_post_ledger(
  p_idempotency_key     uuid,
  p_item_type           item_type,
  p_location_id         uuid,
  p_stock_state         stock_state,
  p_movement_type       movement_type,
  p_qty_delta           numeric,
  p_business_date       date,
  p_event_at            timestamptz default now(),
  p_product_id          uuid default null,
  p_packaging_item_id   uuid default null,
  p_lot_id              uuid default null,
  p_smoke_date_group_id uuid default null,
  p_source_table        text default null,
  p_source_id           uuid default null,
  p_reason              text default null,
  p_reversal_of         uuid default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor   uuid;
  v_id      uuid;
  v_balance numeric;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- created_by is NOT NULL references profiles(id). Resolve it here so a claimless or
  -- deactivated session is refused by name, rather than by an opaque FK violation.
  select id into v_actor from profiles where id = auth.uid() and is_active;
  if v_actor is null then
    raise exception 'NO_ACTOR: the caller has no active profile (R31)';
  end if;

  -- R21 / ADR-017.
  if p_item_type = 'SMOKED_MEAT' and p_lot_id is null then
    raise exception 'LOT_REQUIRED: a SMOKED_MEAT movement must name its lot (R21/D01)';
  end if;

  if p_qty_delta < 0 then
    -- The tuple is exactly the grouping v_stock_balance uses. Lock it, then sum it: any
    -- other order re-introduces the race the lock is here to remove.
    perform pg_advisory_xact_lock(hashtextextended(
      coalesce(p_item_type::text, '')           || '|' ||
      coalesce(p_product_id::text, '')          || '|' ||
      coalesce(p_packaging_item_id::text, '')   || '|' ||
      coalesce(p_lot_id::text, '')              || '|' ||
      coalesce(p_smoke_date_group_id::text, '') || '|' ||
      coalesce(p_location_id::text, '')         || '|' ||
      coalesce(p_stock_state::text, ''), 0));

    -- coalesce, because SUM over no rows is null. Treating that as "unlimited" is how an
    -- empty tuple would quietly fund a sale.
    select coalesce(sum(qty_delta), 0) into v_balance
      from stock_ledger
     where item_type           =              p_item_type
       and location_id         =              p_location_id
       and stock_state         =              p_stock_state
       and product_id          is not distinct from p_product_id
       and packaging_item_id   is not distinct from p_packaging_item_id
       and lot_id              is not distinct from p_lot_id
       and smoke_date_group_id is not distinct from p_smoke_date_group_id;

    if v_balance + p_qty_delta < 0 then
      raise exception 'INSUFFICIENT_STOCK: balance % cannot absorb % (BR24/R3)',
        v_balance, p_qty_delta;
    end if;
  end if;

  insert into stock_ledger (
    idempotency_key, item_type, product_id, packaging_item_id, lot_id, smoke_date_group_id,
    location_id, stock_state, movement_type, qty_delta, business_date, event_at,
    source_table, source_id, reason, reversal_of, created_by)
  values (
    p_idempotency_key, p_item_type, p_product_id, p_packaging_item_id, p_lot_id,
    p_smoke_date_group_id, p_location_id, p_stock_state, p_movement_type, p_qty_delta,
    p_business_date, p_event_at, p_source_table, p_source_id, p_reason, p_reversal_of,
    v_actor)
  on conflict (idempotency_key) do nothing
  returning id into v_id;

  if v_id is null then
    -- The key has been seen. Return the original result: same id, no second write, no error.
    select id into v_id from stock_ledger where idempotency_key = p_idempotency_key;
  end if;

  return v_id;
end $$;

revoke execute on function public.fn_post_ledger(
  uuid, item_type, uuid, stock_state, movement_type, numeric, date, timestamptz,
  uuid, uuid, uuid, uuid, text, uuid, text, uuid) from public;
