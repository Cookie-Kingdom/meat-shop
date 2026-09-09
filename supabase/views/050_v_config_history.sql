-- v_config_history — the OW 10 config reader (card ^ref-12). Writers are the four
-- fn_set_* setters (^ref-11), which granted a read path to nobody on purpose.
--
-- ONE VIEW OVER FOUR SHAPES. The Owner sees "config" as one list; the database holds it as
-- config_settings (key + scope), product_prices (two numbers per product), packaging_full_stock
-- (item + location) and smoke_fee_tiers (a whole band SET at one date). All four are dated,
-- none is mutable, and the screen's contract is identical for all four — current value, a
-- revision line, a history action, a create action. So the union is the view, and the screen's
-- list is `where is_current`. A second `v_config_current` would be a `distinct on` of this one
-- and a second definition of the word "current".
--
-- is_current IS PER (source, item_key, scope_location_id), NOT PER SOURCE. A branch price and
-- a global price are both current, for different scopes. One flag per source picks one of them
-- and hides the other, and the one it hides is the deliberate per-branch override.
--
-- AND IT ORDERS THE WAY fn_config_value ORDERS. The resolver is
-- `(scope_location_id is not null) desc, effective_from desc` and this view has to agree with
-- it about which row is current, or the screen shows a rate the engine is not using — which is
-- worse than showing no rate at all. The one difference is deliberate: the resolver takes an
-- event date and collapses scope (a branch caller resolves to ONE row); the screen shows the
-- catalogue, so scope is part of the key here and both rows survive. Same ordering, one row
-- per scope instead of one row overall.
--
-- A FUTURE ROW IS NEVER CURRENT. `effective_from <= current_date` gates is_current and
-- is_future flags the rest. The Owner enters next month's price today; rendering it as the
-- effective one makes the number on the screen stop being the number in the ledger.
--
-- THE TIER SET IS ONE ITEM, keyed by effective_from. A gap is a property of the set (R37,
-- D02) and fn_set_smoke_fee_tier refuses a partial write, so listing five bands as five items
-- invites an edit the writer will not accept. `item_key` is the literal 'smoke_fee_tiers' for
-- every set; the sets are told apart by effective_from, exactly as the setter keys them.
--
-- L1 ONLY, AND IT CANNOT BE A GRANT. One database role carries every application user
-- (`authenticated`) and L1/L2/L3 lives on profiles, so "L1 all, L2 —, L3 —" has to be a WHERE
-- clause (R34) — the same pattern as v_stock_balance, v_po_outstanding and v_audit_trail. R20
-- is the rule being enforced: an L3 session never reads a price, and it reads zero rows from
-- the database rather than being shown a hidden menu (ADR-004).
--
-- SECURITY DEFINER (the Postgres default), not security_invoker: all four tables are deny-all
-- with RLS on, so an invoker view returns nothing for every role including L1. Standing
-- consequence — never `force row level security` on these four tables or on profiles, or the
-- view returns nothing for everyone.
--
-- LEFT JOIN profiles for created_by_name, the same reason v_audit_trail does it: a JWT with no
-- profile row must not drop the row that names the change.
--
-- ponytail: no index anywhere for this view. The config surface is ~24 rows on day one and the
-- sequential scan is free. Ceiling: add one when config_settings passes ~10k rows, which is a
-- migration and its own card.
--
-- Covered by supabase/tests/config_screen_test.sql (TC-32 … TC-42).

create or replace view public.v_config_history as
with unioned as (
  ------------------------------------------------------------------- config_settings
  select
    'CONFIG'::text                as source,
    c.key                         as item_key,
    c.key                         as item_label_th,   -- the Thai label is the catalogue's
    c.scope_location_id,
    c.effective_from,
    c.value_numeric,
    c.value_text,
    c.value_json,
    coalesce(
      to_char(c.value_numeric, 'FM999999999990.00'),
      c.value_text,
      c.value_json #>> '{}'
    )                             as value_display,
    c.note,
    c.created_at,
    c.created_by,
    c.id                          as row_id
  from config_settings c

  union all
  --------------------------------------------------------------------- product_prices
  -- Two numbers on one row (R30 — cost_thb may be null on purpose, the cost coming from the
  -- lot). value_numeric carries the price, which is the one the screen sorts and compares on;
  -- value_json carries both, so the history sheet can show a cost that changed alone.
  select
    'PRODUCT_PRICE',
    p.product_id::text,
    pr.name_th,
    null::uuid,
    p.effective_from,
    p.price_thb,
    null::text,
    jsonb_build_object('price_thb', p.price_thb, 'cost_thb', p.cost_thb),
    to_char(p.price_thb, 'FM999999999990.00')
      || case when p.cost_thb is null then ''
              else ' / ทุน ' || to_char(p.cost_thb, 'FM999999999990.00') end,
    null::text,
    p.created_at,
    p.created_by,
    p.id
  from product_prices p
  join products pr on pr.id = p.product_id

  union all
  --------------------------------------------------------------- packaging_full_stock
  select
    'FULL_STOCK',
    f.packaging_item_id::text,
    pi.name_th,
    f.location_id,
    f.effective_from,
    f.full_stock_qty,
    null::text,
    null::jsonb,
    to_char(f.full_stock_qty, 'FM999999999990.00') || ' ' || pi.unit,
    null::text,
    f.created_at,
    f.created_by,
    f.id
  from packaging_full_stock f
  join packaging_items pi on pi.id = f.packaging_item_id

  union all
  ------------------------------------------------------------------- smoke_fee_tiers
  -- One row per SET. The bands are aggregated in min_weight_kg order — the order the gap and
  -- overlap validators walk them in, so the screen reads the set the same way the setter
  -- validated it. created_at / created_by / row_id come from the first band; the setter writes
  -- every band of a set in one transaction, so "the first band's author" is the set's author.
  select
    'SMOKE_FEE_TIER',
    'smoke_fee_tiers',
    'ค่ารมควันตามน้ำหนัก',
    null::uuid,
    t.effective_from,
    null::numeric,
    null::text,
    t.bands,
    t.band_display,
    null::text,
    t.created_at,
    t.created_by,
    t.row_id
  from (
    select
      s.effective_from,
      jsonb_agg(
        jsonb_build_object(
          'min_weight_kg', s.min_weight_kg,
          'max_weight_kg', s.max_weight_kg,
          'rate_thb',      s.rate_thb,
          'rate_basis',    s.rate_basis
        ) order by s.min_weight_kg
      ) as bands,
      string_agg(
        to_char(s.min_weight_kg, 'FM999999999990.00') || '–'
          || coalesce(to_char(s.max_weight_kg, 'FM999999999990.00'), '∞') || ' กก. · '
          || to_char(s.rate_thb, 'FM999999999990.00')
          || case s.rate_basis when 'PER_KG' then ' บาท/กก.' else ' บาท' end,
        ' | ' order by s.min_weight_kg
      ) as band_display,
      min(s.created_at) as created_at,
      (array_agg(s.created_by order by s.min_weight_kg))[1] as created_by,
      (array_agg(s.id         order by s.min_weight_kg))[1] as row_id
    from smoke_fee_tiers s
    group by s.effective_from
  ) t
)
select
  u.source,
  u.item_key,
  u.item_label_th,
  u.scope_location_id,
  l.name_th as scope_name_th,
  u.effective_from,
  u.value_numeric,
  u.value_text,
  u.value_json,
  u.value_display,
  u.note,
  u.created_at,
  u.created_by,
  p.display_name as created_by_name,
  -- The newest row at or before today, WITHIN its own (source, item_key, scope). Ordered the
  -- way fn_config_value orders so the screen and the resolver cannot disagree.
  u.effective_from <= current_date
    and u.effective_from = max(u.effective_from) filter (where u.effective_from <= current_date)
          over (partition by u.source, u.item_key, u.scope_location_id)
    as is_current,
  u.effective_from > current_date as is_future,
  u.row_id
from unioned u
left join locations l on l.id = u.scope_location_id
left join profiles  p on p.id = u.created_by
where fn_current_role() = 'L1_OWNER';

comment on view public.v_config_history is
  'OW 10. Every dated config row from config_settings, product_prices, packaging_full_stock '
  'and smoke_fee_tiers in one shape. is_current is per (source, item_key, scope_location_id) '
  'and orders the way fn_config_value orders (ADR-006, R12); a future row is is_future, never '
  'current. A smoke-fee band set is ONE row (D02, R37). L1 only, enforced in the WHERE (R34) — '
  'the four tables stay deny-all.';

grant select on public.v_config_history to authenticated;
