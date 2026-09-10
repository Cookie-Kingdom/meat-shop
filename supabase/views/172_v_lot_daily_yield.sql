-- v_lot_daily_yield — one row per smoke day, for OW 03's yield trend while a lot is still
-- running (PRODUCT F7, v0.2 OW 03 "รวม Daily Log ยอดรอทำ Yield และสถานะ", card ^ref-33).
--
--   day_yield_pct = packed_weight_kg (that day's smoke-date group) / input_weight_kg (that log) × 100
--
-- NOT smoke_yield_pct, AND NOT LOSS. Its base is the day's input, not the lot's pre-smoke
-- weight (smoke_yield_pct, v_lot_yield) and not the Foodiva dispatch (loss_pct). Three bases
-- under one word is exactly the failure ADR-011's naming rule exists to stop, so this figure has
-- a name of its own. R17 holds: nothing here divides partial output by the full dispatch.
--
-- OUTPUT IS THE SMOKE-DATE GROUP, NOT THE LOG (PLAN-lots Finding 7). The bags for a day land on
-- the group (lot, smoke_date) the log is filed under; smoke_daily_logs.packed_weight_kg and
-- .bag_count are a third copy that nothing writes. A day with no bags yet has no group row, and
-- day_yield_pct is NULL — "not packed yet", not 0% (the v_lot_progress precedent).
--
-- ON A CROSS-LOT DAY (D05) the log's input is every source's kilograms and the output lands on
-- the lot the log is filed under — the same pairing fn_close_lot's output uses, so the trend
-- reads the day as the operator filed it.
--
-- L1 ONLY, AS A WHERE (R34, R20). Yield-bearing: BR15 and UAT-15 keep yield from the chef house
-- that produced it. SECURITY DEFINER (the Postgres default), never security_invoker. Opening lots
-- have no logs, so they have no rows without a filter.
--
-- Covered by supabase/tests/cost_yield_test.sql (TC-09).

create or replace view public.v_lot_daily_yield as
select
  l.id                                                             as lot_id,
  l.lot_code,
  l.state,
  d.id                                                             as smoke_daily_log_id,
  d.event_date,
  d.input_weight_kg,
  d.smoked_weight_kg,
  d.brine_used_kg,
  g.packed_weight_kg,
  g.bag_count,
  round(g.packed_weight_kg / nullif(d.input_weight_kg, 0) * 100, 2) as day_yield_pct
from smoke_daily_logs d
join lots l on l.id = d.lot_id
left join smoke_date_groups g
  on g.lot_id = d.lot_id
 and g.smoke_date = d.event_date
where fn_current_role() = 'L1_OWNER';

comment on view public.v_lot_daily_yield is
  'F7 OW 03 — per smoke day: input, smoked, brine, packed output (the smoke-date group) and '
  'day_yield_pct = packed / that day''s input. Not Loss (R17) and not smoke_yield_pct — a '
  'different base under a different name (ADR-011). Null when the day has no bags yet. L1 only, '
  'in the WHERE (R34, R20).';

revoke all    on public.v_lot_daily_yield from anon, authenticated;
grant  select on public.v_lot_daily_yield to   authenticated;
