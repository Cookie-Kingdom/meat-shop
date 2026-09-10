-- v_supplier_options — the OW 01 supplier picker (card ^ref-20, lane F).
--
-- WHY A VIEW AND NOT A SELECT ON suppliers. suppliers is deny-all (ADR-004) — RLS on, no
-- policy, no table grant — so an L1 session reads nothing from it directly, and granting
-- it would widen every column to every role at once (R34: there is one database role for
-- application users). fn_create_po needs a supplier id; this is the smallest read that
-- lets the Owner pick one.
--
-- IDS AND NAMES ONLY. `contact` is left out: the picker does not need it, and a column this
-- view does not carry is one no later screen can leak. Active rows only — an inactive
-- supplier is one fn_create_po refuses with SUPPLIER_INACTIVE, so offering it would be
-- offering a refusal.
--
-- L1 ONLY, IN THE WHERE, the same pattern as v_po_outstanding and v_config_catalogue: an
-- L2 or L3 session gets zero rows from the database rather than a hidden nav item. The
-- supplier list is part of "Supplier และ Purchase Batch", which v0.2's permission table
-- gives the branch admin no access to at all.
--
-- SECURITY DEFINER (the Postgres default), never security_invoker: suppliers has RLS on
-- with no policies, so an invoker view returns nothing for every role including L1.
-- Standing consequence, the same one v_po_outstanding carries — never `force row level
-- security` on suppliers.
--
-- Covered by supabase/tests/purchasing_screen_test.sql (TC-S01, TC-S02, TC-S04, TC-S08).

create or replace view public.v_supplier_options as
select
  s.id,
  s.name
from suppliers s
where s.is_active
  and fn_current_role() = 'L1_OWNER';

comment on view public.v_supplier_options is
  'OW 01 supplier picker. Active suppliers, id and name only. L1 only via the WHERE (R34); '
  'suppliers stays deny-all (ADR-004).';

revoke all    on public.v_supplier_options from anon, authenticated;
grant  select on public.v_supplier_options to   authenticated;
