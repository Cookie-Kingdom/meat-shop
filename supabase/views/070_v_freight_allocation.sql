-- v_freight_allocation — per-line share, the method that produced it, and the
-- reconciliation back to the fare (R24, ADR-012, card ^ref-23).
--
-- L1 ONLY, WHICH CLOSES OPEN QUESTION 1 OF TDD-transport.md. That question read
-- API_DATA_MODEL.md's "all | — | —" as possibly under-specified and had the plan nulling
-- the money columns for L2 and L3 instead. It is not under-specified: an em dash in that
-- table means the role gets nothing, exactly as it does on the v_po_outstanding,
-- v_lot_yield and v_lot_cost rows either side of it, and every one of those is implemented
-- as a WHERE that returns zero rows. run_cost_thb and freight_share_thb are money, R20
-- keeps an L3 session out of a price column, and the simplest honest reading of the doc and
-- the rule agree. A nulled-money variant would have been a third access shape invented here
-- and sourced nowhere.
--
-- The role test is a WHERE and cannot be a GRANT: there is one database role for
-- application users, `authenticated`, and L1/L2/L3 is a column on profiles, so a grant
-- reaches all three or none (R34). An L2 or L3 session gets zero rows from the database
-- rather than a hidden nav item, and that is the enforcement (ADR-004).
--
-- SECURITY DEFINER (the Postgres default), never security_invoker: transport_runs and
-- transport_lines have RLS on with no policies, so an invoker view returns nothing for every
-- role including L1. Standing consequence, the same one v_stock_balance carries — never
-- `force row level security` on these tables.
--
-- fare_reconciles_to_satang IS THE VIEW'S REASON FOR EXISTING. R24's rule is asserted inside
-- fn_allocate_freight, where it can refuse to commit; this column is how an Owner sees that
-- it held on a run allocated before that assert was written, or on one whose lines changed
-- after allocation and has not been re-run. It reads false, not null, when a run has lines
-- and no shares yet.
--
-- Covered by supabase/tests/transport_test.sql (TC-29 ... TC-36) and, for the grant shape,
-- transport_schema_test.sql (TC-38).

create or replace view public.v_freight_allocation as
select
  tl.id                     as line_id,
  tr.id                     as run_id,
  tr.route,
  tr.event_date,
  tr.vehicle_type,
  tr.is_round_trip,
  tr.alloc_method,
  tr.run_cost_thb,
  l.lot_code,
  tl.lot_id,
  tl.dispatched_weight_kg,
  tl.freight_share_thb,
  sum(coalesce(tl.freight_share_thb, 0)) over (partition by tr.id)::numeric(12,2)
                            as run_allocated_thb,
  (sum(coalesce(tl.freight_share_thb, 0)) over (partition by tr.id) = tr.run_cost_thb)
                            as fare_reconciles_to_satang
from transport_lines tl
join transport_runs tr on tr.id = tl.run_id
join lots l            on l.id  = tl.lot_id
where fn_current_role() = 'L1_OWNER';

comment on view public.v_freight_allocation is
  'R24 — per-line freight share, the snapshotted method (R29), and whether the run''s shares '
  'still sum back to its fare. L1 only, enforced in the WHERE (R34, R20).';

revoke all    on public.v_freight_allocation from anon, authenticated;
grant  select on public.v_freight_allocation to   authenticated;
