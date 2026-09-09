-- Card ^ref-11 — fn_set_product_price. A new dated price for one SKU (BR23, D03.1).
--
-- The box and the sealed-meat add-on are two products with two prices, never one row with
-- two columns: they are separate sale lines on the receipt, and a card that folds them
-- together makes the 350/320 split unrecoverable from the data (D03.1).
--
-- cost_thb is nullable on purpose — for meat it comes from the lot, not from a price list
-- (R30). Passing null here is "the lot decides", not "free".
--
-- Idempotency, insert-only and the L1 check are the same as fn_set_config; the natural key
-- is (product_id, effective_from).
--
-- Covered by supabase/tests/config_writers_test.sql (TC-25).

create or replace function public.fn_set_product_price(
  p_idempotency_key uuid,
  p_product_id      uuid,
  p_effective_from  date,
  p_price_thb       numeric,
  p_cost_thb        numeric default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_id    uuid;
  v_row   product_prices;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  v_actor := fn_require_owner();

  if p_product_id is null then
    raise exception 'PRODUCT_REQUIRED: a price with no product prices nothing';
  end if;
  if p_effective_from is null then
    raise exception 'CONFIG_EFFECTIVE_FROM_REQUIRED: an undated price cannot be resolved by event date (R12)';
  end if;
  if p_price_thb is null or p_price_thb < 0 then
    raise exception 'PRICE_INVALID: price_thb is %', coalesce(p_price_thb::text, 'null');
  end if;

  insert into product_prices (product_id, price_thb, cost_thb, effective_from, created_by)
  values (p_product_id, p_price_thb, p_cost_thb, p_effective_from, v_actor)
  on conflict (product_id, effective_from) do nothing
  returning id into v_id;

  if v_id is not null then
    return v_id;
  end if;

  select * into v_row
    from product_prices
   where product_id = p_product_id and effective_from = p_effective_from;

  if v_row.price_thb = p_price_thb and v_row.cost_thb is not distinct from p_cost_thb then
    return v_row.id;   -- a retry, not a second price
  end if;

  raise exception 'CONFIG_DUPLICATE_DATE: product % already has a different price at % — append-only has no same-day correction (BR23)',
    p_product_id, p_effective_from;
end $$;

revoke execute on function public.fn_set_product_price(uuid, uuid, date, numeric, numeric) from public;
grant  execute on function public.fn_set_product_price(uuid, uuid, date, numeric, numeric) to authenticated;
