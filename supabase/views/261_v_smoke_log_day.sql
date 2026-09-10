-- v_smoke_log_day — one smoke log as CM 04 has to re-open it: the day's weights, the source
-- lots it drew from, and the bags packed under that date (D05, R6a, R34, BR15, card ^ref-30).
--
-- WHY IT EXISTS. fn_upsert_smoke_daily_log REPLACES the sources array on every call
-- (PLAN-lots Finding 3): the morning visit records the inputs, and the 18:00 visit that adds
-- the output weight must send those same sources again or it deletes them. The screen can
-- only do that if it can read what the morning saved, and nothing exposes a day's log —
-- smoke_daily_logs and smoke_daily_log_sources are deny-all, and v_lot_progress is summed
-- over the whole lot. CM 05 reads the same rows for its per-day summary.
--
-- SOURCES ARE A jsonb ARRAY, ONE ELEMENT PER SOURCE ROW, each naming its lot (D05, ADR-017).
-- A cross-lot day is one log with two sources, never two logs, and the screen pre-fills
-- LotSourceList from exactly these elements. A source lot may be another operator's lot at
-- the same chef house; its code is shown, nothing else about it is.
--
-- THE BAGS ARE THE GROUP FOR THIS DATE, NOT THE LOG'S OWN COLUMNS (Finding 7).
-- smoke_daily_logs.packed_weight_kg and .bag_count are never written by anything; the pack
-- lines hang off smoke_date_groups, and fn_record_lot_bags refuses a smoke date with no log
-- (SMOKE_LOG_MISSING), so every group has a log row here to sit on.
--
-- NO PERCENTAGE AND NO PRICE, for the same reason as v_lot_progress (R17, BR15): every
-- ingredient of a yield figure may appear on a CM screen and the division may not.
--
-- SCOPE (R34): the lot the log is FILED under decides, L1 all, L3 their own assigned lots,
-- L2 nothing. SECURITY DEFINER view, role test in the WHERE, as v_lot_pending_work.
--
-- Depends on no other view. Covered by supabase/tests/cm_screens_test.sql (TC-56).

create or replace view public.v_smoke_log_day as
select
  d.id                            as smoke_daily_log_id,
  d.lot_id,
  l.lot_code,
  d.event_date,
  d.input_weight_kg,
  d.smoked_weight_kg,
  d.brine_used_kg,
  d.post_freeze_weight_kg,
  coalesce((
    select jsonb_agg(jsonb_build_object(
             'lot_id',          s.lot_id,
             'lot_code',        sl.lot_code,
             'input_weight_kg', s.input_weight_kg) order by sl.lot_code)
      from smoke_daily_log_sources s
      join lots sl on sl.id = s.lot_id
     where s.smoke_daily_log_id = d.id), '[]'::jsonb) as sources,
  coalesce(g.packed_weight_kg, 0) as packed_weight_kg,
  coalesce(g.bag_count, 0)        as bag_count
from smoke_daily_logs d
join lots l on l.id = d.lot_id
left join smoke_date_groups g on g.lot_id = d.lot_id and g.smoke_date = d.event_date
where fn_current_role() = 'L1_OWNER'
   or (fn_current_role() = 'L3_CM_OPERATOR' and l.assigned_operator_id = auth.uid());

comment on view public.v_smoke_log_day is
  'CM 04 / CM 05 — one smoke log per (lot, event_date) with its sources as a jsonb array '
  '(D05) and the bags packed under that smoke date (the group roll-up, Finding 7). Exists so '
  'the evening visit can re-send the morning''s sources, which the upsert replaces. No '
  'percentage and no price column (R17, BR15). L1 all, L3 own assigned lots, L2 nothing.';

revoke all    on public.v_smoke_log_day from anon, authenticated;
grant  select on public.v_smoke_log_day to   authenticated;
