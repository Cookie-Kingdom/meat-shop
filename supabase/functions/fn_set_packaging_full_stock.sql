-- Card ^ref-11 — fn_set_packaging_full_stock. A new dated full-stock level (R9, R11).
--
-- TWO THINGS THIS FUNCTION GUARDS THAT THE SCHEMA DOES NOT.
--
-- 1. The unique key is (packaging_item_id, location_id, effective_from) with a NULLABLE
--    location_id, and Postgres treats NULLs as distinct in a unique index. Two GLOBAL rows
--    for one item on one date are therefore storable, and resolution would then turn on
--    physical row order. config_settings closes the identical hole with a coalesce inside
--    its index; this table does not, and fixing the index is a migration this card does not
--    carry. So the second global row is refused here instead, under an advisory lock so two
--    concurrent calls cannot both find nothing and both insert.
--    supabase/tests/config_schema_test.sql asserts the hole is still open — the day someone
--    coalesces the index, that test fails and points at this guard as dead code.
--
-- 2. R9 says "zero or missing means not configured yet", and …0004:37 repeats it, but the
--    CHECK is full_stock_qty > 0 — zero is unstorable. The rule is right and the sentence
--    describes a state the schema cannot hold: "not configured" is the ABSENCE OF A ROW.
--    A zero is refused by name here rather than by the CHECK, and v_material_alerts
--    (^ref-50) must LEFT JOIN and return null, never 0 — a zero divisor is how a low-stock
--    alert either never fires or always does.
--
-- R11: nothing on this card writes full_stock_qty from an intake path. Receiving material
-- stock moves the ledger balance; the full level is an Owner-set target and only this
-- function writes it.
--
-- Covered by supabase/tests/config_writers_test.sql (TC-26, TC-31).

create or replace function public.fn_set_packaging_full_stock(
  p_idempotency_key   uuid,
  p_packaging_item_id uuid,
  p_effective_from    date,
  p_full_stock_qty    numeric,
  p_location_id       uuid default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_row   packaging_full_stock;
  v_id    uuid;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- ^fix-numeric-scale: a third decimal is refused by name, not rounded by the column.
  perform fn_require_two_decimals('p_full_stock_qty', p_full_stock_qty);

  v_actor := fn_require_owner();

  if p_packaging_item_id is null then
    raise exception 'PACKAGING_ITEM_REQUIRED: a full-stock level with no item measures nothing';
  end if;
  if p_effective_from is null then
    raise exception 'CONFIG_EFFECTIVE_FROM_REQUIRED: an undated level cannot be resolved by event date (R12)';
  end if;
  if p_full_stock_qty is null or p_full_stock_qty <= 0 then
    raise exception 'FULL_STOCK_NOT_POSITIVE: got % — "not configured" is the absence of a row, not a zero row (R9)',
      coalesce(p_full_stock_qty::text, 'null');
  end if;

  -- The index does not serialise the global (location_id null) case, so do it here. Xact
  -- scope, never session scope: pg_advisory_lock would leak the lock into whatever request
  -- next borrows the pooled connection.
  perform pg_advisory_xact_lock(hashtextextended(
    p_packaging_item_id::text || '|' ||
    coalesce(p_location_id::text, '') || '|' ||
    p_effective_from::text, 0));

  select * into v_row
    from packaging_full_stock
   where packaging_item_id = p_packaging_item_id
     and location_id is not distinct from p_location_id
     and effective_from = p_effective_from;

  if v_row.id is not null then
    if v_row.full_stock_qty = p_full_stock_qty then
      return v_row.id;   -- a retry, not a second row
    end if;
    raise exception 'CONFIG_DUPLICATE_DATE: item % already has a different full-stock level at % — append-only has no same-day correction (BR23)',
      p_packaging_item_id, p_effective_from;
  end if;

  insert into packaging_full_stock (packaging_item_id, location_id, full_stock_qty,
                                    effective_from, created_by)
  values (p_packaging_item_id, p_location_id, p_full_stock_qty, p_effective_from, v_actor)
  returning id into v_id;

  return v_id;
end $$;

revoke execute on function public.fn_set_packaging_full_stock(uuid, uuid, date, numeric, uuid) from public, anon, authenticated;
grant  execute on function public.fn_set_packaging_full_stock(uuid, uuid, date, numeric, uuid) to authenticated;
