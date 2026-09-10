-- Card ^ref-40 — fn_record_thaw. BR 05: the branch moves weight FROZEN -> READY against a named
-- lot, with the FIFO check (R14, R15, R21, BR19, UAT-03, UAT-06, UAT-10).
--
-- THE ONLY WRITER OF THAW_OUT / THAW_IN. Meat lands at a branch FROZEN (fn_confirm_transport_
-- receipt's BRANCH arm) and a sale deducts READY only (R14). Nothing else moves the one into the
-- other, so until this exists no branch can sell (^ref-43 ... ^ref-46 all read what it writes).
--
-- THREE ROWS, ONE TRANSACTION, ONE KEY (TDD Seam 1). The thaw record is inserted FIRST, `on
-- conflict (idempotency_key) do nothing` against ...0019's unique index, and only then are the
-- two ledger rows posted through fn_post_ledger: THAW_OUT -kg on FROZEN under the caller's key,
-- THAW_IN +kg on READY under md5(key || ':in') — equal and opposite, same lot_id, same
-- smoke_date_group_id, same location (R14, ADR-017). The index is where a concurrent retry is
-- serialised: the second session blocks on the first's uncommitted entry, wakes to a conflict,
-- finds no row returned and answers with the winner's record (thaw_concurrency_test.sh TC-34).
-- Recovering the retry from stock_ledger instead would let both sessions insert a record and
-- only one reach the ledger (PLAN Finding 1).
--
-- THE ORDER IS THE DESIGN (PLAN T5, Finding 6):
--    1  key            IDEMPOTENCY_KEY_REQUIRED
--    2  load the report by id
--    3  preamble       fn_require_branch_or_owner(report's location). v0.2:57 gives branch
--                      operations to the branch's L2 and to the Owner for every branch. A report
--                      that does not exist has a null location, which is FORBIDDEN_LOCATION for
--                      an L2 — the same answer as another branch's real report, so nothing leaks.
--    4  REPORT_NOT_FOUND, reachable only by the Owner.
--    5  THE REPLAY, before any refusal. A thaw commits at 20:55 and its response is lost; the
--       branch closes at 21:00; the client retries at 21:01. Asking CLOSED first would report a
--       write that succeeded as refused, which R4 forbids. The key wins and the payload is
--       ignored. PLAN-sales.md T3 has this order backwards and is recorded as a cross-lane gap.
--    6  status = 'CLOSED' -> REPORT_CLOSED. NEVER `<> 'OPEN'`: UNLOCKED is a past day reopened
--       under R28 and must accept the correction it was reopened for (^fix-receipt-state-floor
--       is the same defect one table over). Lane C's fn_guard_report_closed trigger (...0018)
--       is the backstop; this raise is what a Thai screen can render.
--    7  BACKDATE_NOT_ALLOWED, via fn_backdating_allowed(report_date) — never current_date
--       (ADR-014) — and ONLY for an OPEN report. An UNLOCKED report skips it: the unlock IS the
--       escalation for a date outside the window (R28), so testing the window again would make
--       every unlock of an old day useless (lane B handoff, deviation 1).
--    8  THAW_WEIGHT_INVALID: null, <= 0, or more than 2 decimals. The column is numeric(12,2)
--       and would round 3.005 silently (BR21).
--    9  THE SOURCE. Null lot -> LOT_REQUIRED; null group -> SMOKE_GROUP_REQUIRED; a group of
--       another lot -> LOT_REQUIRED naming the group's lot; no row in v_branch_frozen_available
--       for (report location, lot, group) -> LOT_REQUIRED. That view, not v_smoke_group_
--       available, is the one definition of "thawable": the raw view offers IN_TRANSIT meat
--       still on the truck (R43 holds it at the destination) and READY meat already thawed
--       (PLAN Finding 4, Seam 3). BR 05's picker reads the same view.
--   10  FIFO, below.
--   11  insert the record, key first.
--   12  THAW_OUT. INSUFFICIENT_STOCK from fn_post_ledger is caught and re-raised as
--       INSUFFICIENT_FROZEN_STOCK naming the lot code, the smoke date and the frozen balance.
--       It is NOT pre-checked: a balance read outside fn_post_ledger's advisory lock is the race
--       that lock exists to remove (R3, PLAN-sales.md Finding 13; TC-35).
--   13  THAW_IN.
--   14  a real override writes one FIFO_OVERRIDE notification to L1 (Finding 5), in
--       fn_close_lot's shape: unconditional, because alert_enabled governs DELIVERY (D09), not
--       whether the event happened. A replay returns at step 5 and never reaches this step.
--   15  the response. A replay of a thaw made at ANOTHER branch asks the preamble again for
--       that branch, so an L2 of B holding A's key learns nothing (handoff deviation 2, TC-26b).
--
-- FIFO IS BY SMOKE DATE, AND THE LOT INSIDE THE DATE IS A CHOICE (PLAN Finding 3). v0.2:92
-- "เสนอวันที่เก่าที่สุดตาม FIFO", :184 "จ่ายกลุ่มวันที่เก่าก่อนตาม FIFO และบันทึกเหตุผลเมื่อข้าม", :188
-- "เรียงวันรมควันก่อนและแสดง Lot ให้เลือกภายในวันนั้น", :329 "FIFO ตามวันที่รมควัน". An override is a
-- pick whose smoke_date is later than the earliest smoke_date with FROZEN stock AT THIS BRANCH.
-- Any lot inside that date is compliant and needs no reason. "Oldest" is scoped: an older date
-- held only at another branch, only IN_TRANSIT here, or only READY here is not older for this
-- decision (TC-24). fn_allocate_to_branch applies the same rule at central, so the Owner and the
-- branch work to one FIFO. A reason sent with a compliant pick is DROPPED and null is stored, so
-- "how often was FIFO skipped" is `fifo_override_reason is not null` and nothing else (TC-22).
--
-- A KEY ALREADY SPENT ON ANOTHER WRITE IS REFUSED, not absorbed. stock_ledger.idempotency_key is
-- global, so a client that reused a sale's or a receipt's key would get fn_post_ledger's replay
-- path — the OTHER write's row id — and this thaw record would stand with no movement behind
-- it. The ledger row each post returns must name this thaw as its source, or IDEMPOTENCY_KEY_
-- REUSED (TC-26c).
--
-- NOT HERE: an audit insert (^ref-06's trigger covers thaw_records, stock_ledger and
-- notifications in this transaction, R32); lots.state (ADR-026 stops it at CENTRAL_STOCK — every
-- branch lot is there, and that is also why fn_guard_lot_closed must never reach thaw_records,
-- Finding 7); any config read beyond fn_backdating_allowed's (FIFO is a rule, not a number).
--
-- ponytail: the FIFO read at step 10 is outside any lock. A receipt of an OLDER date that commits
-- mid-thaw can let one newer pick through without a reason. Harmless at four users (BR24).
-- Upgrade path: take a per-branch advisory lock before step 10 if the Owner ever sees it happen.
--
-- Covered by supabase/tests/thaw_test.sql (TC-09 ... TC-33) and thaw_concurrency_test.sh
-- (TC-34, TC-35).

create or replace function public.fn_record_thaw(
  p_idempotency_key      uuid,
  p_daily_report_id      uuid,
  p_lot_id               uuid,
  p_smoke_date_group_id  uuid,
  p_thawed_weight_kg     numeric,
  p_fifo_override_reason text default null
) returns json
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor      uuid;
  v_report     daily_reports;
  v_thaw       thaw_records;
  v_group_lot  uuid;
  v_group_code text;
  v_pick       record;
  v_oldest     date;
  v_reason     text;
  v_ledger     uuid;
  v_thaw_loc   uuid;
  v_frozen     numeric(12,2);
  v_ready      numeric(12,2);
begin
  --------------------------------------------------------------------------- 1 ... 4
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  select * into v_report from daily_reports where id = p_daily_report_id;

  v_actor := fn_require_branch_or_owner(v_report.location_id);

  if v_report.id is null then
    raise exception 'REPORT_NOT_FOUND: no daily report %', p_daily_report_id;
  end if;

  ------------------------------------------------------------------------ 5 the replay
  select * into v_thaw from thaw_records where idempotency_key = p_idempotency_key;

  if v_thaw.id is null then
    ------------------------------------------------------------------- 6, 7 the day
    if v_report.status = 'CLOSED' then
      raise exception 'REPORT_CLOSED: % is closed at this branch; a correction goes through the unlock path (R8, R28)',
        v_report.report_date;
    end if;

    if v_report.status = 'OPEN' and not fn_backdating_allowed(v_report.report_date) then
      raise exception 'BACKDATE_NOT_ALLOWED: % is outside the back-dating window; a correction goes through the unlock path (R28)',
        v_report.report_date;
    end if;

    ---------------------------------------------------------------------- 8 the weight
    if p_thawed_weight_kg is null or p_thawed_weight_kg <= 0
       or p_thawed_weight_kg <> round(p_thawed_weight_kg, 2) then
      raise exception 'THAW_WEIGHT_INVALID: thawed_weight_kg must be > 0 with at most 2 decimals, got %',
        coalesce(p_thawed_weight_kg::text, 'none');
    end if;

    ---------------------------------------------------------------------- 9 the source
    if p_lot_id is null then
      raise exception 'LOT_REQUIRED: a thaw names the lot it draws from (R21, ADR-017)';
    end if;
    if p_smoke_date_group_id is null then
      raise exception 'SMOKE_GROUP_REQUIRED: a thaw names the smoke-date group it draws from (R15, R21)';
    end if;

    select g.lot_id, l.lot_code into v_group_lot, v_group_code
      from smoke_date_groups g
      join lots l on l.id = g.lot_id
     where g.id = p_smoke_date_group_id;
    if v_group_lot is not null and v_group_lot <> p_lot_id then
      raise exception 'LOT_REQUIRED: smoke-date group % belongs to lot %, not to the lot named (R21)',
        p_smoke_date_group_id, v_group_code;
    end if;

    select * into v_pick
      from v_branch_frozen_available
     where location_id = v_report.location_id
       and lot_id = p_lot_id
       and smoke_date_group_id = p_smoke_date_group_id;
    if not found then
      raise exception 'LOT_REQUIRED: lot % has no frozen stock in smoke-date group % at this branch (R21)',
        coalesce((select lot_code from lots where id = p_lot_id), p_lot_id::text), p_smoke_date_group_id;
    end if;

    ------------------------------------------------------------------ 10 FIFO by date
    select min(smoke_date) into v_oldest
      from v_branch_frozen_available
     where location_id = v_report.location_id;

    if v_pick.smoke_date > v_oldest then
      v_reason := nullif(btrim(p_fifo_override_reason), '');
      if v_reason is null then
        raise exception 'FIFO_REASON_REQUIRED: this branch still holds frozen meat smoked %; thawing % first needs a reason (R15, BR07)',
          v_oldest, v_pick.smoke_date;
      end if;
    end if;
    -- A compliant pick leaves v_reason null: the reason it was sent is dropped.

    ------------------------------------------------------------- 11 the record, first
    insert into thaw_records (daily_report_id, lot_id, smoke_date_group_id, thawed_weight_kg,
                              fifo_override_reason, created_by, idempotency_key)
    values (v_report.id, p_lot_id, p_smoke_date_group_id, p_thawed_weight_kg,
            v_reason, v_actor, p_idempotency_key)
    on conflict (idempotency_key) do nothing
    returning * into v_thaw;

    if v_thaw.id is null then
      -- A concurrent session with the same key committed first. Answer as its replay (TC-34).
      select * into v_thaw from thaw_records where idempotency_key = p_idempotency_key;
    else
      --------------------------------------------------------------- 12 THAW_OUT
      begin
        v_ledger := fn_post_ledger(
          p_idempotency_key     => p_idempotency_key,
          p_item_type           => 'SMOKED_MEAT',
          p_location_id         => v_report.location_id,
          p_stock_state         => 'FROZEN',
          p_movement_type       => 'THAW_OUT',
          p_qty_delta           => -p_thawed_weight_kg,
          p_business_date       => v_report.report_date,
          p_lot_id              => p_lot_id,
          p_smoke_date_group_id => p_smoke_date_group_id,
          p_source_table        => 'thaw_records',
          p_source_id           => v_thaw.id);
      exception when others then
        if sqlerrm like 'INSUFFICIENT_STOCK:%' then
          -- The exact tuple fn_post_ledger locked and summed.
          select coalesce(sum(qty_delta), 0) into v_frozen
            from stock_ledger
           where item_type = 'SMOKED_MEAT'
             and location_id = v_report.location_id
             and stock_state = 'FROZEN'
             and product_id is null and packaging_item_id is null
             and lot_id = p_lot_id
             and smoke_date_group_id = p_smoke_date_group_id;
          raise exception 'INSUFFICIENT_FROZEN_STOCK: lot % smoked % has % kg frozen at this branch, % kg asked (R3, BR24)',
            v_pick.lot_code, v_pick.smoke_date, v_frozen, p_thawed_weight_kg;
        end if;
        raise;
      end;

      if not exists (select 1 from stock_ledger
                      where id = v_ledger and source_table = 'thaw_records' and source_id = v_thaw.id) then
        raise exception 'IDEMPOTENCY_KEY_REUSED: key % already belongs to another write; a thaw needs a fresh key (R4)',
          p_idempotency_key;
      end if;

      ---------------------------------------------------------------- 13 THAW_IN
      v_ledger := fn_post_ledger(
        p_idempotency_key     => md5(p_idempotency_key::text || ':in')::uuid,
        p_item_type           => 'SMOKED_MEAT',
        p_location_id         => v_report.location_id,
        p_stock_state         => 'READY',
        p_movement_type       => 'THAW_IN',
        p_qty_delta           => p_thawed_weight_kg,
        p_business_date       => v_report.report_date,
        p_lot_id              => p_lot_id,
        p_smoke_date_group_id => p_smoke_date_group_id,
        p_source_table        => 'thaw_records',
        p_source_id           => v_thaw.id);

      if not exists (select 1 from stock_ledger
                      where id = v_ledger and source_table = 'thaw_records' and source_id = v_thaw.id) then
        raise exception 'IDEMPOTENCY_KEY_REUSED: key % already belongs to another write; a thaw needs a fresh key (R4)',
          p_idempotency_key;
      end if;

      ------------------------------------------------------ 14 the Owner is told
      if v_reason is not null then
        insert into notifications (kind, target_role, location_id, lot_id, payload)
        values ('FIFO_OVERRIDE', 'L1_OWNER', v_report.location_id, p_lot_id,
                jsonb_build_object(
                  'thaw_record_id',       v_thaw.id,
                  'report_date',          v_report.report_date,
                  'lot_code',             v_pick.lot_code,
                  'smoke_date',           v_pick.smoke_date,
                  'oldest_smoke_date',    v_oldest,
                  'thawed_weight_kg',     p_thawed_weight_kg,
                  'fifo_override_reason', v_reason));
      end if;
    end if;
  end if;

  ------------------------------------------------------------------------ 15 the response
  select location_id into v_thaw_loc from daily_reports where id = v_thaw.daily_report_id;
  if v_thaw_loc is distinct from v_report.location_id then
    perform fn_require_branch_or_owner(v_thaw_loc);
  end if;

  -- Both balances are the MOVED tuple's, read now — on a replay too. They are a read, not a
  -- stored fact; snapshotting them would be a balance column (ADR-003).
  select coalesce(sum(qty_delta) filter (where stock_state = 'FROZEN'), 0),
         coalesce(sum(qty_delta) filter (where stock_state = 'READY'), 0)
    into v_frozen, v_ready
    from stock_ledger
   where item_type = 'SMOKED_MEAT'
     and location_id = v_thaw_loc
     and product_id is null and packaging_item_id is null
     and lot_id = v_thaw.lot_id
     and smoke_date_group_id = v_thaw.smoke_date_group_id;

  return json_build_object(
    'thaw_record_id',      v_thaw.id,
    'lot_id',              v_thaw.lot_id,
    'smoke_date_group_id', v_thaw.smoke_date_group_id,
    'thawed_weight_kg',    v_thaw.thawed_weight_kg,
    'frozen_remaining_kg', v_frozen,
    'ready_available_kg',  v_ready,
    'fifo_override',       v_thaw.fifo_override_reason is not null);
end $$;

revoke execute on function public.fn_record_thaw(uuid, uuid, uuid, uuid, numeric, text) from public, anon, authenticated;
grant  execute on function public.fn_record_thaw(uuid, uuid, uuid, uuid, numeric, text) to authenticated;
