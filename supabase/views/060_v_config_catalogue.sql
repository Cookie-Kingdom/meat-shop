-- v_config_catalogue — the OW 10 pickers (card ^ref-12).
--
-- NOT IN PLAN-config-screen.md. Found while building T7: v_config_history shows the rows
-- that EXIST, and the screen also has to offer the ones that do not yet. Setting a price
-- needs the product list, a full-stock level needs the packaging-item list, and a
-- branch-scoped row needs the branch list — and products, packaging_items and locations are
-- all deny-all (ADR-004), so an L1 session can read none of them. Without this the Owner
-- can only revise an item somebody already configured, and "the Owner sets full-stock levels
-- without a developer" is not true. Recorded as a deviation in the plan.
--
-- IDS AND NAMES ONLY, and that is the whole reason this is cheap: it carries no rate, no
-- price and no quantity. It is still L1-only, because the shape of the catalogue (which
-- products exist, which branches exist) is not something R20 has any reason to widen here —
-- the card that needs a branch list for an L2 screen can grant its own view.
--
-- SECURITY DEFINER, `where fn_current_role() = 'L1_OWNER'` (R34), same as v_config_history,
-- and the WHERE sits on the wrapper rather than three times inside the union — one place to
-- be wrong is better than three that can drift. Standing consequence, the same one: never
-- `force row level security` on products, packaging_items or locations.
--
-- Only active rows. An inactive product is one the Owner deliberately retired; offering it
-- in a "set a new price from…" picker invites reviving it by accident.
--
-- Covered by supabase/tests/config_screen_test.sql (TC-35 — the tables stay deny-all).

create or replace view public.v_config_catalogue as
select * from (
  select 'PRODUCT'::text as kind, p.id, p.name_th, p.code, p.sale_unit as unit
    from products p
   where p.is_active
  union all
  select 'PACKAGING_ITEM', i.id, i.name_th, i.code, i.unit
    from packaging_items i
   where i.is_active
  union all
  select 'LOCATION', l.id, l.name_th, l.code, l.kind::text
    from locations l
   where l.is_active
) c
where fn_current_role() = 'L1_OWNER';

comment on view public.v_config_catalogue is
  'OW 10 pickers. Ids and names for products, packaging items and locations — no rate, no '
  'price, no quantity. Active rows only. L1 only via the WHERE (R34); the three tables stay '
  'deny-all (ADR-004).';

grant select on public.v_config_catalogue to authenticated;
