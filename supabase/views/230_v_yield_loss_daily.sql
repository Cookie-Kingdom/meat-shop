-- v_yield_loss_daily — M12's "Yield Loss รายวัน": the Loss of the lots that closed each day
-- (ADR-011, R16a, R17, card ^ref-58; PLAN-reporting.md K15).
--
-- LOSS IS ON THE FOODIVA DISPATCH BASE AND NOTHING ELSE (ADR-011). It is 170's stored
-- loss_weight_kg over its foodiva_sent_weight_kg. The CM received and pre-smoke weights are
-- cross-check and smoke-yield figures and never appear here; the only columns that say "loss"
-- are loss_weight_kg and loss_pct (TC-S05).
--
-- WEIGHTED, NEVER A MEAN OF PERCENTAGES (TC-37). loss_pct = Σ loss / Σ dispatch × 100 over the
-- day's lots: (25 + 5) / (100 + 50) = 20.00, not (25.00 + 10.00) / 2 = 17.50.
--
-- THE DAY IS BANGKOK'S (ADR-010). close_date = (closed_at at time zone 'Asia/Bangkok')::date,
-- so a lot closed at 01:30 local time lands on that local date (TC-38).
--
-- yield_alert_lot_count READS 170's yield_alert — the YIELD_ALERT fn_close_lot raised through
-- fn_check_variance in ALERT mode (ADR-019). No threshold is re-derived here or on the screen.
--
-- L1 ONLY, AS A WHERE (R34, R20, BR15: no yield for the chef house). SECURITY DEFINER.
--
-- Covered by supabase/tests/reports_dashboard_test.sql (TC-36 ... TC-38).

create or replace view public.v_yield_loss_daily as
select (y.closed_at at time zone 'Asia/Bangkok')::date                           as close_date,
       count(*)                                                                  as lots_closed,
       sum(y.foodiva_sent_weight_kg)::numeric(12,2)                              as foodiva_sent_weight_kg,
       sum(y.loss_weight_kg)::numeric(12,2)                                      as loss_weight_kg,
       round(sum(y.loss_weight_kg) / nullif(sum(y.foodiva_sent_weight_kg), 0) * 100, 2)::numeric(6,2)
                                                                                 as loss_pct,
       count(*) filter (where y.yield_alert)                                     as yield_alert_lot_count
  from v_lot_yield y
 where fn_current_role() = 'L1_OWNER'
 group by (y.closed_at at time zone 'Asia/Bangkok')::date;

comment on view public.v_yield_loss_daily is
  'ADR-011 / M12 — Loss of the lots closed on each Bangkok date, on the Foodiva dispatch base, '
  'weighted (Σ loss / Σ dispatch). yield_alert_lot_count counts the YIELD_ALERTs fn_close_lot '
  'raised. L1 only (R34, R20).';

revoke all    on public.v_yield_loss_daily from anon, authenticated;
grant  select on public.v_yield_loss_daily to   authenticated;
