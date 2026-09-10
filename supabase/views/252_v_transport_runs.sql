-- v_transport_runs — one row per run, including a run with no lines yet (card ^ref-24,
-- lane F, PLAN-transport.md T9.1).
--
-- WHY IT EXISTS. Every transport view built so far is per LINE: v_freight_allocation,
-- v_transport_variance and v_outstanding_receipts all start from transport_lines. A run
-- that fn_create_transport_run wrote and whose first fn_dispatch_transport_line failed has
-- no line, and so it appears nowhere. That is a vehicle with a fare and nothing on it. It
-- is exactly the run the Owner needs to see, to add the lots or to know the fare is
-- unallocated. The LEFT JOIN is the whole point: line_count reads 0, never an absent row.
--
-- fare_reconciles_to_satang HAS v_freight_allocation's MEANING, at run level (R24). It is
-- false, not null, when the run has a fare and no shares yet, which includes a run with
-- no lines. That is the state OW 02's "แบ่งค่าขนส่งใหม่" button exists for. On the branch leg
-- (fare 0, R25) it reads true, because 0 = 0 and fn_allocate_freight leaves those shares
-- null on purpose.
--
-- alloc_method is the run's own snapshot (R29), never config at read time. A run allocated
-- in March shows March's method after the Owner changes the key in July.
--
-- L1 ONLY, IN THE WHERE (R34, R20). run_cost_thb and allocated_thb are money, and
-- API_DATA_MODEL.md's em dash on v_freight_allocation's L2/L3 columns is the precedent this
-- follows.
--
-- SECURITY DEFINER (the Postgres default), never security_invoker — transport_runs and
-- transport_lines have RLS on with no policies.
--
-- Covered by supabase/tests/transport_screen_test.sql (TC-S10 ... TC-S12).

create or replace view public.v_transport_runs as
select
  tr.id                                                     as run_id,
  tr.route,
  tr.event_date,
  tr.vehicle_type,
  tr.is_round_trip,
  tr.alloc_method,
  tr.run_cost_thb,
  tr.note,
  tr.created_at,
  count(tl.id)                                              as line_count,
  coalesce(sum(tl.dispatched_weight_kg), 0)::numeric(12,2)  as dispatched_weight_kg,
  count(tl.received_at)                                     as received_line_count,
  coalesce(sum(tl.freight_share_thb), 0)::numeric(12,2)     as allocated_thb,
  (coalesce(sum(tl.freight_share_thb), 0) = tr.run_cost_thb) as fare_reconciles_to_satang
from transport_runs tr
left join transport_lines tl on tl.run_id = tr.id
where fn_current_role() = 'L1_OWNER'
group by tr.id;

comment on view public.v_transport_runs is
  'OW 02 run list. One row per run, line_count 0 included; fare_reconciles_to_satang is '
  'v_freight_allocation''s R24 check at run level (false while a fare is unallocated). '
  'alloc_method is the run''s snapshot (R29). L1 only via the WHERE (R34, R20).';

revoke all    on public.v_transport_runs from anon, authenticated;
grant  select on public.v_transport_runs to   authenticated;
