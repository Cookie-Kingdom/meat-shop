-- v_owner_exceptions — OW 08's first tile: everything that needs the Owner, one row per
-- exception (M12, F13, ADR-019, card ^ref-58; PLAN-reporting.md K16, Finding 14).
--
-- A UNION OVER THE VIEWS THAT ALREADY HOLD EACH VERDICT, NOT OVER notifications. Only
-- fn_close_lot writes a notification (YIELD_ALERT); the other kinds are never written, so each
-- is read where its verdict lives. Nothing is recomputed here — the Diff is C's, the material
-- alert D's, the receipt variance fn_check_variance's (ADR-019, ALERT mode):
--
--   YIELD_ALERT          notifications, kind = YIELD_ALERT
--   DIFF_OVER_THRESHOLD  150_v_branch_diff, verdict <> 'WITHIN' (over, or a zero base that needs
--                        a reason)
--   MATERIAL_LOW         161_v_material_alerts, is_low (strict <, R10; null = unconfigured, R9,
--                        is not an exception)
--   COUNT_VARIANCE_OPEN  160_v_count_variance, status = 'OPEN'
--   RECEIPT_VARIANCE     080_v_transport_variance, variance_reason is not null: the receiver had
--                        to explain it. 080 has no verdict column (a dated threshold would need
--                        fn_config_numeric), and the reason is the recorded fact.
--   RECEIPT_OUTSTANDING  090_v_outstanding_receipts, every row (D06)
--   LOT_COST_INCOMPLETE  171_v_lot_cost, not is_complete once the lot is back at central or
--                        beyond (state >= CENTRAL_STOCK): the return leg has landed and the cost
--                        is still not final (R30)
--
-- detail carries the numbers the Thai message needs, so the screen formats and never computes.
-- occurred_on is the source's own business or event date, in Bangkok where it is a timestamp.
--
-- L1 ONLY, AS A WHERE on the outer select (R34). The sources scope L2 to their own branch; this
-- tile is the Owner's. SECURITY DEFINER (the default).
--
-- Covered by supabase/tests/reports_dashboard_test.sql (TC-39, TC-40).

create or replace view public.v_owner_exceptions as
select u.*
  from (
    select 'YIELD_ALERT'::text                                    as exception_kind,
           (n.created_at at time zone 'Asia/Bangkok')::date       as occurred_on,
           n.location_id,
           n.lot_id,
           'notifications'::text                                  as ref_table,
           n.id                                                   as ref_id,
           coalesce(n.payload, '{}'::jsonb)
             || jsonb_build_object('lot_code', l.lot_code)        as detail
      from notifications n
      left join lots l on l.id = n.lot_id
     where n.kind = 'YIELD_ALERT'
    union all
    select 'DIFF_OVER_THRESHOLD',
           d.business_date,
           d.location_id,
           null::uuid,
           'daily_reports',
           r.id,
           jsonb_build_object('ready_in_kg', d.ready_in_kg, 'sold_kg', d.sold_kg,
                              'wasted_kg', d.wasted_kg, 'diff_kg', d.diff_kg,
                              'variance_pct', d.variance_pct, 'verdict', d.verdict)
      from v_branch_diff d
      left join daily_reports r on r.location_id = d.location_id and r.report_date = d.business_date
     where d.verdict <> 'WITHIN'
    union all
    select 'MATERIAL_LOW',
           m.counted_on,
           m.location_id,
           null::uuid,
           'packaging_items',
           m.packaging_item_id,
           jsonb_build_object('packaging_code', m.packaging_code, 'name_th', m.name_th,
                              'unit', m.unit, 'remaining_qty', m.remaining_qty,
                              'full_stock_qty', m.full_stock_qty,
                              'alert_threshold_qty', m.alert_threshold_qty)
      from v_material_alerts m
     where m.is_low
    union all
    select 'COUNT_VARIANCE_OPEN',
           c.event_date,
           c.location_id,
           c.lot_id,
           'physical_counts',
           c.physical_count_id,
           jsonb_build_object('item_type', c.item_type, 'counted_qty', c.counted_qty,
                              'system_qty', c.system_qty, 'variance_qty', c.variance_qty,
                              'reason', c.reason)
      from v_count_variance c
     where c.status = 'OPEN'
    union all
    select 'RECEIPT_VARIANCE',
           coalesce((t.received_at at time zone 'Asia/Bangkok')::date, t.dispatch_date),
           t.to_location_id,
           t.lot_id,
           'transport_lines',
           t.line_id,
           jsonb_build_object('lot_code', t.lot_code, 'route', t.route,
                              'dispatched_weight_kg', t.dispatched_weight_kg,
                              'received_weight_kg', t.received_weight_kg,
                              'variance_pct', t.variance_pct,
                              'variance_reason', t.variance_reason)
      from v_transport_variance t
     where t.variance_reason is not null
    union all
    select 'RECEIPT_OUTSTANDING',
           o.dispatch_date,
           o.to_location_id,
           o.lot_id,
           'transport_lines',
           o.line_id,
           jsonb_build_object('lot_code', o.lot_code, 'route', o.route,
                              'outstanding_weight_kg', o.outstanding_weight_kg,
                              'age_days', o.age_days)
      from v_outstanding_receipts o
    union all
    select 'LOT_COST_INCOMPLETE',
           coalesce((c.closed_at at time zone 'Asia/Bangkok')::date, c.priced_at),
           null::uuid,
           c.lot_id,
           'lots',
           c.lot_id,
           jsonb_build_object('lot_code', c.lot_code, 'missing_inputs', to_jsonb(c.missing_inputs))
      from v_lot_cost c
     where not c.is_complete
       and c.state >= 'CENTRAL_STOCK'
  ) u
 where fn_current_role() = 'L1_OWNER';

comment on view public.v_owner_exceptions is
  'M12 / Finding 14 — one row per exception the Owner must act on, read from the view that '
  'holds each verdict: YIELD_ALERT (notifications), DIFF_OVER_THRESHOLD (150), MATERIAL_LOW '
  '(161), COUNT_VARIANCE_OPEN (160), RECEIPT_VARIANCE (080, a reason was required), '
  'RECEIPT_OUTSTANDING (090), LOT_COST_INCOMPLETE (171, back at central and not final). '
  'ALERT only; nothing recomputed. L1 only (R34).';

revoke all    on public.v_owner_exceptions from anon, authenticated;
grant  select on public.v_owner_exceptions to   authenticated;
