-- Card ^ref-45 — fn_close_daily_report. BR 09's one irreversible action: the day is closed by a
-- person who has checked the figures, from 21:00, and only when the meat reconciles
-- (UAT-04, UAT-14, R13, R22, R23, M5, BR21).
--
-- WHO: the branch's own L2, or L1 (v0.2:57, PLAN-sales.md B1). fn_require_branch_or_owner is
-- lane B's preamble, called with the report's location before anything is locked. An L2
-- probing a report that does not exist gets FORBIDDEN_LOCATION, and only an L1 reaches
-- REPORT_NOT_FOUND.
--
-- THE REPORT ROW IS LOCKED (for update) BEFORE ANY GATE IS READ. Two sessions closing one day
-- therefore run one after the other, and the second one sees the first one's CLOSED row
-- (TC-54).
--
-- THE RETRY FIRST (R4, Finding 5). A CLOSED row carrying this call's close_idempotency_key is
-- a retry after a dropped connection: return the original body and write nothing. A CLOSED
-- row with any other key is REPORT_ALREADY_CLOSED, because reopening a day is the unlock path
-- (R28, ^ref-08).
--
-- THE GATES, IN THE ORDER BR 09 SHOWS THEM (B6):
--   1. CLOSE_TOO_EARLY. Refused while now() < (report_date + business_day_close_earliest) at
--      time zone 'Asia/Bangkok' (B8, ADR-010). One expression covers every date: today closes
--      from 21:00, and an unlocked past day closes at any hour (TC-49), with no current_date
--      comparison, which would be UTC in a default session. The key is text 'HH:MI'. A value
--      that will not cast is CONFIG_WRONG_TYPE and is never defaulted to 21:00
--      (fn_config_date's precedent). CONFIG_NOT_SET propagates.
--   2. DIFF_OVER_THRESHOLD / DIFF_REASON_REQUIRED (R22, R23, M5). The day's row from
--      v_branch_diff, then fn_check_variance(sold + wasted, ready_in, 'BLOCK'). BLOCK, because
--      this is the one variance in the system that refuses rather than alerts: the day is
--      still open and the number is still fixable (TDD Seam 6). There is no threshold
--      argument, so the band is R22's 20.00 and not the receiving tolerance (Finding 9). The
--      band's VARIANCE_OVER_THRESHOLD is re-raised under the contract's name, with the
--      kilograms. At a zero expected the verdict is REASON_REQUIRED, and the close needs
--      p_remark (B7). A day with no READY meat movement has no Diff row and needs none.
--      ASKED BEFORE R13, NOT AFTER (B6). diff_kg IS the day's net READY movement, so once R13
--      has forced READY to zero the Diff is zero as well and the band could never fire.
--   3. READY_STOCK_NOT_ZERO (R13, BR19). The branch's whole READY meat balance, across lots
--      and dates, must be zero, naming what is left per lot. Rice is not in it: it posts no
--      ledger row (Finding 10), so it needs no exemption clause to carry forward (M7).
--   4. MATERIAL_COUNT_INCOMPLETE (M8, Finding 6). Every ACTIVE packaging_items row has a
--      physical_counts row against this report. Derived, not the constant 7, so it is vacuous
--      while the table is unseeded and bites the day the seven rows arrive, with no code change
--      (ADR-018). Lane D does not seed them today.
--   5. RICE_RECORD_MISSING (M7, Finding 6, B22). A branch with a rice_model needs this
--      report's rice_records row carrying the EVENING figure, cooked_remaining_kg. Lane D's
--      fn_record_rice upserts the row morning and evening, and a morning-only row would close
--      the day and leave tomorrow's carry-in null.
--
-- NO R28 CHECK (B9). A stale OPEN day refused by the back-dating window would stay open
-- forever, and daily_reports_one_open would then refuse every later open at that branch.
--
-- THE WRITE is one UPDATE: status, closed_by (the actor, never a parameter), closed_at, the
-- remark, and the key. R32's trigger writes the one audit row with before and after. There is
-- no audit insert here, and no ledger row: closing a day moves no stock (TC-50).
--
-- material_alerts (B20, relayed from lane D). It comes from lane D's v_material_alerts (161):
-- the rows for this branch whose is_low is true or null (null means not configured or not
-- counted, R9), or [] when there are none. It is computed only when the report being closed
-- was OPEN, i.e. the live shift (ADR-014), because the view resolves at current_date. An
-- UNLOCKED past day closed again, and a retry, return null: not computed, which is not the
-- same as nothing low. The view is read through to_regclass and EXECUTE, so this function
-- applies and runs whichever lane merges first.
--
-- ponytail: a thaw that commits between gate 3 and this function's commit could leave READY on
-- a closed day. The report-row lock does not cover writers that never read it. At four users
-- this does not happen (BR24). The upgrade is a `for share` of the report row in the writers.
--
-- Covered by supabase/tests/day_close_test.sql (TC-43 ... TC-52) and
-- sales_concurrency_test.sh (TC-54).

create or replace function public.fn_close_daily_report(
  p_idempotency_key uuid,
  p_daily_report_id uuid,
  p_remark          text default null
) returns json
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_location   uuid;
  v_actor      uuid;
  v_report     daily_reports;
  v_was_open   boolean;
  v_remark     text;
  v_cfg        config_settings;
  v_earliest   time;
  v_diff       record;
  v_var        record;
  v_ready      numeric;
  v_lots       text;
  v_missing    text;
  v_n          bigint;
  v_rice_model rice_model;
  v_alerts     json;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  select location_id into v_location from daily_reports where id = p_daily_report_id;
  v_actor := fn_require_branch_or_owner(v_location);

  select * into v_report from daily_reports where id = p_daily_report_id for update;
  if v_report.id is null then
    raise exception 'REPORT_NOT_FOUND: no daily report %', p_daily_report_id;
  end if;

  --------------------------------------------------------------------------- the retry (R4)
  if v_report.status = 'CLOSED' then
    if v_report.close_idempotency_key = p_idempotency_key then
      return json_build_object(
        'daily_report_id', v_report.id,
        'status',          v_report.status,
        'closed_at',       v_report.closed_at,
        'material_alerts', null);
    end if;
    raise exception 'REPORT_ALREADY_CLOSED: % was closed at % — reopening a closed day is the unlock path (R28)',
      v_report.report_date, v_report.closed_at;
  end if;

  v_was_open := v_report.status = 'OPEN';
  v_remark   := nullif(btrim(p_remark), '');

  ---------------------------------------------------------- 1. CLOSE_TOO_EARLY (BR21, B8)
  v_cfg := fn_config_value('business_day_close_earliest', v_report.report_date, v_report.location_id);
  if v_cfg.value_text is null then
    raise exception 'CONFIG_WRONG_TYPE: business_day_close_earliest resolved to a non-text row at % — it is a time such as 21:00',
      v_report.report_date;
  end if;
  begin
    v_earliest := btrim(v_cfg.value_text)::time;
  exception when invalid_datetime_format or datetime_field_overflow then
    raise exception 'CONFIG_WRONG_TYPE: business_day_close_earliest is [%] at %, which is not a time such as 21:00',
      v_cfg.value_text, v_report.report_date;
  end;

  if now() < (v_report.report_date + v_earliest) at time zone 'Asia/Bangkok' then
    raise exception 'CLOSE_TOO_EARLY: % can be closed from % Bangkok time, and it is % now (BR21, UAT-14)',
      v_report.report_date, to_char(v_earliest, 'HH24:MI'),
      to_char(now() at time zone 'Asia/Bangkok', 'HH24:MI');
  end if;

  --------------------------------------------------- 2. the Diff (R22, R23, M5; B6, B7, B10)
  select * into v_diff
    from v_branch_diff
   where location_id = v_report.location_id and business_date = v_report.report_date;
  if found then
    begin
      select * into v_var
        from fn_check_variance(v_diff.sold_kg + v_diff.wasted_kg, v_diff.ready_in_kg, 'BLOCK');
    exception when others then
      if sqlerrm not like 'VARIANCE_OVER_THRESHOLD:%' then
        raise;
      end if;
      raise exception 'DIFF_OVER_THRESHOLD: % kg of the % kg of meat made ready on % is unaccounted for — % percent against R22''s 20 percent band. The day cannot close until sales and waste reconcile (R22, R23, M5)',
        v_diff.diff_kg, v_diff.ready_in_kg, v_report.report_date, v_diff.variance_pct;
    end;

    if v_var.verdict = 'REASON_REQUIRED' and v_remark is null then
      raise exception 'DIFF_REASON_REQUIRED: no meat was made ready on %, yet % kg left READY — the Diff has no expected figure to divide by, so a remark is required (R22)',
        v_report.report_date, v_diff.sold_kg + v_diff.wasted_kg;
    end if;
  end if;

  --------------------------------------------------------- 3. READY_STOCK_NOT_ZERO (R13)
  select coalesce(sum(qty_delta), 0) into v_ready
    from stock_ledger
   where item_type = 'SMOKED_MEAT' and location_id = v_report.location_id and stock_state = 'READY';
  if v_ready <> 0 then
    select string_agg(format('%s %s kg', coalesce(lo.lot_code, 'no lot'), b.kg), ', '
                      order by lo.lot_code)
      into v_lots
      from (select lot_id, sum(qty_delta) as kg
              from stock_ledger
             where item_type = 'SMOKED_MEAT' and location_id = v_report.location_id
               and stock_state = 'READY'
             group by lot_id
            having sum(qty_delta) <> 0) b
      left join lots lo on lo.id = b.lot_id;
    raise exception 'READY_STOCK_NOT_ZERO: % kg of thawed meat is still READY at this branch (%) — write it off as waste before the day closes (R13, BR19)',
      v_ready, v_lots;
  end if;

  ------------------------------------------------------ 4. MATERIAL_COUNT_INCOMPLETE (M8)
  select count(*), string_agg(p.code, ', ' order by p.code) into v_n, v_missing
    from packaging_items p
   where p.is_active
     and not exists (select 1 from physical_counts c
                      where c.daily_report_id = v_report.id and c.packaging_item_id = p.id);
  if v_n > 0 then
    raise exception 'MATERIAL_COUNT_INCOMPLETE: % active material(s) have no count on % (%) — BR 08 counts every one (M8)',
      v_n, v_report.report_date, v_missing;
  end if;

  ------------------------------------------------------ 5. RICE_RECORD_MISSING (M7, B22)
  select rice_model into v_rice_model from locations where id = v_report.location_id;
  if v_rice_model is not null and not exists (
       select 1 from rice_records r
        where r.daily_report_id = v_report.id and r.cooked_remaining_kg is not null) then
    raise exception 'RICE_RECORD_MISSING: % has no evening rice record (cooked_remaining_kg) — a % branch records it before the day closes, and tomorrow carries it in (M7)',
      v_report.report_date, v_rice_model;
  end if;

  ------------------------------------------------------------ material alerts (B20, ^ref-50)
  if v_was_open and to_regclass('public.v_material_alerts') is not null then
    execute $q$
      select coalesce(json_agg(json_build_object(
                        'packaging_item_code', a.packaging_code,
                        'remaining_qty',       a.remaining_qty,
                        'full_stock_qty',      a.full_stock_qty,
                        'is_low',              a.is_low)
                      order by a.packaging_code), '[]'::json)
        from public.v_material_alerts a
       where a.location_id = $1 and a.is_low is not false
    $q$ into v_alerts using v_report.location_id;
  end if;

  ------------------------------------------------------------------------------ the write
  update daily_reports
     set status                = 'CLOSED',
         closed_by             = v_actor,
         closed_at             = now(),
         remark                = coalesce(v_remark, remark),
         close_idempotency_key = p_idempotency_key
   where id = v_report.id
  returning * into v_report;

  return json_build_object(
    'daily_report_id', v_report.id,
    'status',          v_report.status,
    'closed_at',       v_report.closed_at,
    'material_alerts', v_alerts);
end $$;

revoke execute on function public.fn_close_daily_report(uuid, uuid, text) from public, anon, authenticated;
grant  execute on function public.fn_close_daily_report(uuid, uuid, text) to authenticated;
