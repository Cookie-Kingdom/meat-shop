-- Card ^ref-08 — fn_unlock_impact. What reopening this day or lot touches, shown to the Owner
-- before the decision is written (D07, UAT-18, R28: "every decision shows the impact on
-- sales, stock and profit").
--
-- THE FIGURES.
--   DAILY_REPORT  that report's sales_lines, plus every stock_ledger row at the report's
--                 (location, business_date). A correction to that day moves exactly those rows.
--   LOT           every stock_ledger row on lot_id, plus every sales_line naming the lot,
--                 plus the number of distinct days those sales sit on.
-- sales_thb is Σ qty × unit_price_thb, the BR23 snapshot already on the line. meat_moved_kg
-- is Σ |qty_delta| over SMOKED_MEAT rows only, because qty_delta carries no unit of its own
-- and a chilli tube is not a kilo. A reversal pair counts twice, since both rows are still
-- in the ledger.
--
-- PROFIT IS null, NOT 0. P&L is ^ref-57's and does not exist yet. A 0 here would read as "no
-- effect on profit", which nobody has computed. The panel says "not computed yet".
--
-- L1 ONLY, AND STILL GRANTED. The response carries money, and L3 never reads a price (R20).
-- It is granted to `authenticated` anyway, because v_unlock_requests calls it and a view's
-- caller needs EXECUTE on every function the view uses. The guard is the first statement.
--
-- Covered by supabase/tests/unlock_test.sql (UL-30 ... UL-34).

create or replace function public.fn_unlock_impact(
  p_target_type unlock_target,
  p_target_id   uuid
) returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_location uuid;
  v_date     date;
  v_reports  bigint;
  v_rows     bigint;
  v_lines    bigint;
  v_thb      numeric;
  v_kg       numeric;
begin
  perform fn_require_owner();

  if p_target_type is null or p_target_id is null then
    raise exception 'UNLOCK_TARGET_REQUIRED: an impact is asked about a day or a lot (R28)';
  end if;

  if p_target_type = 'DAILY_REPORT' then
    select location_id, report_date into v_location, v_date
      from daily_reports where id = p_target_id;
    if not found then
      raise exception 'UNLOCK_TARGET_NOT_FOUND: no daily report %', p_target_id;
    end if;

    select count(*), coalesce(sum(qty * unit_price_thb), 0)
      into v_lines, v_thb
      from sales_lines where daily_report_id = p_target_id;

    select count(*), coalesce(sum(abs(qty_delta)) filter (where item_type = 'SMOKED_MEAT'), 0)
      into v_rows, v_kg
      from stock_ledger where location_id = v_location and business_date = v_date;

    v_reports := 1;
  else
    perform 1 from lots where id = p_target_id;
    if not found then
      raise exception 'UNLOCK_TARGET_NOT_FOUND: no lot %', p_target_id;
    end if;

    select count(*), coalesce(sum(abs(qty_delta)) filter (where item_type = 'SMOKED_MEAT'), 0)
      into v_rows, v_kg
      from stock_ledger where lot_id = p_target_id;

    select count(*), coalesce(sum(qty * unit_price_thb), 0), count(distinct daily_report_id)
      into v_lines, v_thb, v_reports
      from sales_lines where lot_id = p_target_id;
  end if;

  return jsonb_build_object(
    'affected_daily_reports', v_reports,
    'affected_ledger_rows',   v_rows,
    'sales_lines',            v_lines,
    'sales_thb',              round(v_thb, 2),
    'meat_moved_kg',          round(v_kg, 2),
    'profit_thb',             null);
end $$;

revoke execute on function public.fn_unlock_impact(unlock_target, uuid) from public, anon, authenticated;
grant  execute on function public.fn_unlock_impact(unlock_target, uuid) to   authenticated;
