-- Card ^ref-44 — fn_record_waste. One write-off, with its reason, against the lot it came out
-- of (BR19, R13, R21, R32). Chiefly the end-of-day case: thawed meat has no tomorrow, so what
-- is left in READY at close is weighed and written off here before fn_close_daily_report will
-- accept the day (R13, v0.2:94 "บังคับให้เนื้อพร้อมขายที่เหลือลง Waste ก่อนปิดวัน").
--
-- ONE ROW PER CALL. The reason belongs to the row, and a batch would let one reason cover
-- several lots. The screen loops. So the key alone is exact: waste_records_idempotency_key
-- (...0018) is a plain unique, smoke_daily_logs' shape, and the ledger row takes the caller's
-- own key straight through, as fn_confirm_transport_receipt does for its first row.
--
-- p_stock_state HAS NO DEFAULT. READY is the end-of-day case, but spoiled FROZEN stock is a real
-- second one. A default would let the second be written as the first by omission, and the
-- ledger tuple would then be wrong in a way no report shows. ^ref-22 refused to default
-- p_event_date and ^ref-39 p_report_date for the same reason. Only READY and FROZEN are
-- accepted (WASTE_STATE_INVALID): meat still IN_TRANSIT to a branch is the sender's problem,
-- not the branch's write-off.
--
-- MEAT AND CHILLI ONLY (PLAN-sales.md B15, WASTE_ITEM_TYPE_INVALID). Rice has no ledger balance
-- to write off (Finding 10): its leftover is rice_records.cooked_remaining_kg (M7), and a WASTE
-- row against COOKED_RICE would be a draw on a tuple with no intake. Packaging is counted, not
-- wasted (R19).
--
-- THE LEDGER TUPLE (B12):
--   * SMOKED_MEAT on (product NULL, lot, group, branch, state), the tuple the thaw and every
--     transfer use. The lot AND its smoke-date group are required, because the balance is held
--     on the pair (R21, D05, v0.2:174 "การหยิบไปขาย/Waste ต้องระบุ Lot ต้นทาง").
--   * CHILLI_PASTE on (product, no lot, branch, state). waste_records has no product column, so
--     the product is the single active stock-tracked CHILLI_PASTE SKU. Zero or several is
--     PRODUCT_AMBIGUOUS rather than a guess: posting against the wrong product id strands the
--     write-off on a tuple no sale draws from.
--
-- THE ORDER is fn_record_sales' (B2): key -> report -> preamble -> not found -> lock on the key
-- -> replay -> REPORT_CLOSED -> back-dating -> the row. A retry that lands after the close
-- returns the original id (R4). A replay whose payload differs (report, item, state, qty, lot,
-- group or reason) raises WASTE_IDEMPOTENCY_CONFLICT, fn_allocate_to_branch's shape.
--
-- WHO: the branch's L2, or L1 (v0.2:57, B1), through lane B's fn_require_branch_or_owner.
--
-- INSUFFICIENT_STOCK FROM R3 IS NOT RENAMED (TDD TC-36). A write-off larger than the balance is
-- refused by fn_post_ledger inside its lock, and the whole call rolls back, record included.
--
-- NO AUDIT INSERT. ^ref-06's trigger covers waste_records and stock_ledger here (R32), and picks
-- up waste_records.reason as the audit row's reason.
--
-- Covered by supabase/tests/waste_test.sql (TC-32 ... TC-37).

create or replace function public.fn_record_waste(
  p_idempotency_key     uuid,
  p_daily_report_id     uuid,
  p_item_type           item_type,
  p_stock_state         stock_state,
  p_qty                 numeric,
  p_reason              text,
  p_lot_id              uuid default null,
  p_smoke_date_group_id uuid default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_report     daily_reports;
  v_actor      uuid;
  v_prior      waste_records;
  v_prior_st   stock_state;
  v_reason     text;
  v_meat       boolean;
  v_lot        uuid;
  v_group      uuid;
  v_group_lot  uuid;
  v_product    uuid;
  v_n          bigint;
  v_id         uuid;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  select * into v_report from daily_reports where id = p_daily_report_id;

  v_actor := fn_require_branch_or_owner(v_report.location_id);

  if v_report.id is null then
    raise exception 'REPORT_NOT_FOUND: no daily report %', p_daily_report_id;
  end if;

  v_reason := nullif(btrim(p_reason), '');
  v_meat   := p_item_type = 'SMOKED_MEAT';
  v_lot    := case when v_meat then p_lot_id end;
  v_group  := case when v_meat then p_smoke_date_group_id end;

  ------------------------------------------------------------------ the replay (R4, R39)
  perform pg_advisory_xact_lock(hashtextextended('fn_record_waste|' || p_idempotency_key::text, 0));

  select * into v_prior from waste_records where idempotency_key = p_idempotency_key;
  if found then
    select stock_state into v_prior_st
      from stock_ledger
     where source_table = 'waste_records' and source_id = v_prior.id;
    if v_prior.daily_report_id = p_daily_report_id
       and v_prior.item_type = p_item_type
       and v_prior_st is not distinct from p_stock_state
       and v_prior.qty = round(p_qty, 2)
       and v_prior.lot_id is not distinct from v_lot
       and v_prior.smoke_date_group_id is not distinct from v_group
       and v_prior.reason = v_reason then
      return v_prior.id;
    end if;
    raise exception 'WASTE_IDEMPOTENCY_CONFLICT: key % was used for a different write-off (R39)',
      p_idempotency_key;
  end if;

  ---------------------------------------------------------------------- the day (R8, R28)
  -- The trigger's predicate exactly (fn_guard_report_closed, ...0018, PLAN-sales.md B3).
  if v_report.status = 'CLOSED' and not exists (
       select 1 from unlock_requests u
        where u.target_type = 'DAILY_REPORT'
          and u.target_id   = v_report.id
          and u.status      = 'APPROVED'
          and u.expires_at  > now()) then
    raise exception 'REPORT_CLOSED: the day % is closed — no waste can be recorded against it without an approved unlock (R8/R42)',
      v_report.report_date;
  end if;

  -- R28 binds an OPEN day only. An unlocked day is the escalation (v0.2 D07, UAT-18;
  -- PLAN-sales.md B21), as in fn_record_sales and lane B's fn_record_thaw.
  if v_report.status = 'OPEN' and not fn_backdating_allowed(v_report.report_date) then
    raise exception 'BACKDATE_NOT_ALLOWED: % is outside the back-dating window (R28) — the unlock path reopens it',
      v_report.report_date;
  end if;

  ---------------------------------------------------------------------------- the row
  if p_item_type is null or p_item_type not in ('SMOKED_MEAT', 'CHILLI_PASTE') then
    raise exception 'WASTE_ITEM_TYPE_INVALID: % cannot be written off here — meat and chilli paste only; rice leftovers are rice_records (M7)',
      coalesce(p_item_type::text, 'no item type');
  end if;

  if p_stock_state is null or p_stock_state not in ('READY', 'FROZEN') then
    raise exception 'WASTE_STATE_INVALID: % — a write-off names READY or FROZEN, and there is no default (BR19)',
      coalesce(p_stock_state::text, 'no stock state');
  end if;

  if p_qty is null or p_qty <= 0 or p_qty <> round(p_qty, 2) then
    raise exception 'WASTE_QTY_INVALID: % — a write-off is > 0 to two decimals', coalesce(p_qty::text, 'null');
  end if;

  -- BR21. fn_require_lot_for_meat is the backstop; this raise is the message.
  if p_item_type = 'CHILLI_PASTE' and p_qty <> trunc(p_qty) then
    raise exception 'QTY_NOT_WHOLE_UNITS: % tube of CHILLI_PASTE — tubes are whole numbers (BR21)', p_qty;
  end if;

  if v_reason is null then
    raise exception 'WASTE_REASON_REQUIRED: a write-off carries its reason (BR19) — an unexplained one is the one found in an audit';
  end if;

  if v_meat then
    if v_lot is null then
      raise exception 'LOT_REQUIRED: a SMOKED_MEAT write-off names the lot it came out of (R21/D01)';
    end if;
    if v_group is null then
      raise exception 'SMOKE_GROUP_REQUIRED: a SMOKED_MEAT write-off names its smoke-date group — the balance is held on one (R21)';
    end if;
    select lot_id into v_group_lot from smoke_date_groups where id = v_group;
    if v_group_lot is distinct from v_lot then
      raise exception 'LOT_REQUIRED: smoke-date group % belongs to lot %, not % (R21)',
        v_group, coalesce(v_group_lot::text, 'no lot'), v_lot;
    end if;
  else
    select count(*), min(id::text)::uuid into v_n, v_product
      from products
     where item_type = 'CHILLI_PASTE' and is_active and is_stock_tracked;
    if v_n <> 1 then
      raise exception 'PRODUCT_AMBIGUOUS: % active stock-tracked CHILLI_PASTE product(s) — a chilli write-off needs exactly one to name its ledger tuple',
        v_n;
    end if;
  end if;

  insert into waste_records (daily_report_id, item_type, lot_id, smoke_date_group_id, qty,
                             reason, created_by, idempotency_key)
  values (v_report.id, p_item_type, v_lot, v_group, p_qty, v_reason, v_actor, p_idempotency_key)
  returning id into v_id;

  perform fn_post_ledger(
    p_idempotency_key     => p_idempotency_key,
    p_item_type           => p_item_type,
    p_location_id         => v_report.location_id,
    p_stock_state         => p_stock_state,
    p_movement_type       => 'WASTE',
    p_qty_delta           => -p_qty,
    p_business_date       => v_report.report_date,
    p_product_id          => v_product,
    p_lot_id              => v_lot,
    p_smoke_date_group_id => v_group,
    p_source_table        => 'waste_records',
    p_source_id           => v_id,
    p_reason              => v_reason);

  return v_id;
end $$;

revoke execute on function public.fn_record_waste(uuid, uuid, item_type, stock_state, numeric, text, uuid, uuid)
  from public, anon, authenticated;
grant  execute on function public.fn_record_waste(uuid, uuid, item_type, stock_state, numeric, text, uuid, uuid)
  to authenticated;
