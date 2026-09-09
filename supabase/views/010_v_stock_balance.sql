-- v_stock_balance — the only stock truth (ADR-003, R31).
--
-- Balance is SUM(qty_delta) over the ledger, grouped by the tuple every fn_record_* moves
-- stock on. There is no balance column anywhere in the schema and there never will be: a
-- cached balance and its ledger diverge the first time a trigger fails, and after that
-- nobody can say which one is right.
--
-- The grouping here and the advisory-lock key in fn_post_ledger are the same tuple. If one
-- moves, the other has to move with it, or the non-negative check starts guarding a
-- different quantity from the one the Owner reads.
--
-- Access. There is one database role for application users — `authenticated` — and
-- L1/L2/L3 lives on `profiles`, so R20's "L3 has no grant" cannot be a GRANT statement.
-- The role test is in the WHERE clause instead, resolved through R31's helpers, and an L3
-- session gets zero rows. Still the database deciding; the UI cannot undo it (PLAN D3).
--
-- The view is SECURITY DEFINER (the Postgres default), not security_invoker: stock_ledger
-- has RLS on with no policies, so an invoker view would return nothing for every role
-- including L1. Standing consequence, same as R31's — never `force row level security` on
-- stock_ledger.

create or replace view public.v_stock_balance as
select
  l.item_type,
  l.product_id,
  l.packaging_item_id,
  l.lot_id,
  l.smoke_date_group_id,
  l.location_id,
  l.stock_state,
  sum(l.qty_delta)   as balance_qty,
  max(l.event_at)    as last_movement_at
from stock_ledger l
where fn_current_role() = 'L1_OWNER'
   or (fn_current_role() = 'L2_BRANCH_ADMIN' and l.location_id = any (fn_current_locations()))
group by l.item_type, l.product_id, l.packaging_item_id, l.lot_id, l.smoke_date_group_id,
         l.location_id, l.stock_state;

grant select on public.v_stock_balance to authenticated;
