-- Card ^ref-42 — item_type gains BEVERAGE, and nothing else happens in this file
-- (PLAN-sales.md Finding 7).
--
-- WATER_BOTTLE is one of the five SKUs fn_record_sales resolves (BR08: every branch carries a
-- water item for the POS open-store condition), and products.item_type is NOT NULL. None of
-- the five existing values fits it. Filed under PACKAGING it would join v_material_alerts'
-- population and every packaging count. Filed under a meat or rice value it would be worse.
--
-- ALONE IN ITS FILE, per the rule ^ref-62 set and migrations_apply_test.sh asserts. An enum
-- value cannot be rolled back, and it cannot be USED in the transaction that adds it.
-- `supabase db push` wraps each file in one transaction, so the seed row that needs BEVERAGE
-- lives in ...0018, not here.
--
-- `if not exists` makes a hand re-apply a no-op rather than an error. It is still one
-- statement.

alter type item_type add value if not exists 'BEVERAGE';
