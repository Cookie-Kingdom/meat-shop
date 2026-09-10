-- Card ^ref-08 — fn_request_unlock. Ask to reopen a closed day or a closed lot (R28, BR15,
-- D07, UAT-18). Inside R28's window the responsible role's request approves itself.
-- Everything else waits for L1.
--
-- WHO GETS WHAT.
--   L1         anything closed → APPROVED at once, decided_by = the Owner. The Owner is the
--              escalation, so there is nobody further up to ask.
--   L2         a CLOSED day at one of its own branches. Inside the window
--              (fn_backdating_allowed) → APPROVED, decided_by null, because R28 decided it.
--              Outside the window → PENDING for L1 ("เกิน 3 วัน Owner เท่านั้นปลดล็อก", D07).
--   L3         a closed lot assigned to it, at its own chef house → ALWAYS PENDING. v0.2:358:
--              "Lot ที่ปิดแล้วต้องขอ Owner ปลดล็อก… กติกาเปิดแก้ภายใน 3 วัน…ใช้กับการปิดวัน"
--              (a closed lot must ask the Owner; the 3-day rule is for the day close).
--   anyone     outside that scope → OUT_OF_SCOPE. The window widens who may act, not what
--              they may reach (R28).
--
-- AN APPROVAL NEVER TOUCHES THE TARGET (PLAN-unlock.md Finding 1). daily_reports.status stays
-- CLOSED and lots.state stays where it is. The APPROVED row with expires_at > now() is what
-- admits the write: fn_guard_lot_closed (...0013) and lane C's fn_guard_report_closed
-- (...0018) both read exactly (target_type, target_id, status = 'APPROVED', expires_at >
-- now()). A flip to UNLOCKED would be admitted by C's guard unconditionally, and the day would
-- stay writable after expires_at. That is the stale-approval hole R42 exists to close.
--
-- ONE WINDOW DEFINITION. The window is fn_backdating_allowed, not a second
-- `current_date - k`. So it is inclusive of its last day (R28), it moves when the Owner
-- retunes unlock_max_days_back, and while opening_balance_close is empty every L2 day request
-- auto-approves (ADR-021's relaxation, applied once, in one place).
--
-- EXPIRY IS A CLOCK FROM CONFIG (R42). expires_at = now() + unlock_window_hours, resolved at
-- current_date. An unset key raises CONFIG_NOT_SET, never a defaulted duration (ADR-023). A
-- PENDING row needs no expiry and does not read the key.
--
-- LAZY EXPIRY, THIS TARGET ONLY. A stale APPROVED row on this target is stored as EXPIRED
-- before the duplicate check, so asking again after expiry makes a new row. R42: "the
-- requester asks again, and the second request is its own audit row". v_unlock_requests
-- derives EXPIRED on every read anyway. This flip only keeps the stored value honest.
--
-- ORDER: key → shape → actor → lock the target → replay → scope → closed → expire → duplicate
-- → path. The replay sits behind the target lock, so two taps of one form serialise on the
-- day or lot and the second returns the first's row (R4) instead of UNLOCK_ALREADY_PENDING.
-- Scope comes before "closed", so an L2 cannot learn another branch's day status from the
-- error it gets.
--
-- No ledger row. The audit row is fn_audit_row's trigger on unlock_requests (^ref-06).
--
-- Covered by supabase/tests/unlock_test.sql (UL-01 ... UL-22, UL-36).

create or replace function public.fn_request_unlock(
  p_idempotency_key uuid,
  p_target_type     unlock_target,
  p_target_id       uuid,
  p_reason          text
) returns jsonb
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor   uuid;
  v_role    user_role;
  v_report  daily_reports;
  v_lot     lots;
  v_req     unlock_requests;
  v_status  unlock_status;
  v_by      uuid;
  v_at      timestamptz;
  v_expires timestamptz;
  v_hours   numeric;
  v_impact  jsonb;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  if p_target_type is null or p_target_id is null then
    raise exception 'UNLOCK_TARGET_REQUIRED: an unlock names a day or a lot (R28)';
  end if;

  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'UNLOCK_REASON_REQUIRED: say what is being corrected and why (UAT-18)';
  end if;

  -- is_active folded in, as fn_require_owner does. A deactivated session is NO_ACTOR (R31).
  select id, role into v_actor, v_role from profiles where id = auth.uid() and is_active;
  if v_actor is null then
    raise exception 'NO_ACTOR: the caller has no active profile (R31)';
  end if;

  ------------------------------------------------------------------------ the target, locked
  if p_target_type = 'DAILY_REPORT' then
    select * into v_report from daily_reports where id = p_target_id for update;
    if v_report.id is null then
      raise exception 'UNLOCK_TARGET_NOT_FOUND: no daily report %', p_target_id;
    end if;
  else
    select * into v_lot from lots where id = p_target_id for update;
    if v_lot.id is null then
      raise exception 'UNLOCK_TARGET_NOT_FOUND: no lot %', p_target_id;
    end if;
  end if;

  ------------------------------------------------------------------------------ the replay
  -- A return, not a raise (R4). The key wins and the payload is ignored. A key that belongs
  -- to somebody else's request is a client bug, not a retry, and answering it would hand one
  -- user another's row.
  select * into v_req from unlock_requests where idempotency_key = p_idempotency_key;
  if v_req.id is not null then
    if v_req.requested_by is distinct from v_actor then
      raise exception 'UNLOCK_IDEMPOTENCY_CONFLICT: key % belongs to another caller''s request',
        p_idempotency_key;
    end if;
    return jsonb_build_object(
      'unlock_request_id', v_req.id,
      'status',            case when v_req.status = 'APPROVED' and v_req.expires_at <= now()
                                then 'EXPIRED' else v_req.status::text end,
      'decided_by',        v_req.decided_by,
      'expires_at',        v_req.expires_at);
  end if;

  ------------------------------------------------------------------------------- the scope
  if v_role = 'L2_BRANCH_ADMIN' then
    -- fn_current_locations() is '{}' and never null, so `<> all` is true for no membership.
    if p_target_type <> 'DAILY_REPORT'
       or v_report.location_id <> all (fn_current_locations()) then
      raise exception 'OUT_OF_SCOPE: a branch admin unlocks a day at their own branch, nothing else (R28)';
    end if;
  elsif v_role = 'L3_CM_OPERATOR' then
    -- `is distinct from`: an unassigned lot has a null operator, and `null <> actor` is null,
    -- which would let any L3 at the chef house reach a lot nobody owns (fn_require_operator).
    if p_target_type <> 'LOT'
       or v_lot.assigned_operator_id is distinct from v_actor
       or v_lot.chef_house_location_id is null
       or v_lot.chef_house_location_id <> all (fn_current_locations()) then
      raise exception 'OUT_OF_SCOPE: an operator unlocks a lot assigned to them at their own chef house, nothing else (R28, CM 01)';
    end if;
  elsif v_role is distinct from 'L1_OWNER' then
    raise exception 'FORBIDDEN: role % may not request an unlock (ADR-004)', v_role;
  end if;

  ------------------------------------------------------------------------------ the closure
  -- OPEN is writable already, and UNLOCKED was reopened by some other path and is writable
  -- too (C's guard). Only CLOSED is a thing to unlock.
  if p_target_type = 'DAILY_REPORT' then
    if v_report.status <> 'CLOSED' then
      raise exception 'TARGET_NOT_CLOSED: the day % is %, and only a CLOSED day is unlocked (R8)',
        v_report.report_date, v_report.status;
    end if;
  elsif v_lot.is_opening or v_lot.state < 'LOT_CLOSED' then
    -- An opening lot is gated by opening_balance_close, never by an unlock (ADR-021, R46), and
    -- fn_guard_lot_closed exempts it, so an approval would admit nothing.
    raise exception 'TARGET_NOT_CLOSED: lot % is at % (opening: %), and only a closed production lot is unlocked (R8)',
      v_lot.lot_code, v_lot.state, v_lot.is_opening;
  end if;

  ----------------------------------------------------------------- lazy expiry, then duplicates
  update unlock_requests
     set status = 'EXPIRED'
   where target_type = p_target_type
     and target_id   = p_target_id
     and status      = 'APPROVED'
     and expires_at  <= now();

  if exists (select 1 from unlock_requests
              where target_type = p_target_type and target_id = p_target_id
                and status = 'PENDING') then
    raise exception 'UNLOCK_ALREADY_PENDING: a request for this % is already waiting for the Owner',
      p_target_type;
  end if;

  -- After the flip above, any APPROVED row left is live.
  if exists (select 1 from unlock_requests
              where target_type = p_target_type and target_id = p_target_id
                and status = 'APPROVED') then
    raise exception 'UNLOCK_ALREADY_OPEN: this % is already unlocked and still inside its window (R42)',
      p_target_type;
  end if;

  -------------------------------------------------------------------------------- the path
  if v_role = 'L1_OWNER' then
    v_status := 'APPROVED';
    v_by     := v_actor;
    -- The Owner acting directly is still a decision, so the impact is stored with it (D07).
    v_impact := fn_unlock_impact(p_target_type, p_target_id);
  elsif v_role = 'L2_BRANCH_ADMIN' and fn_backdating_allowed(v_report.report_date) then
    v_status := 'APPROVED';
    v_by     := null;      -- R28 decided it, not a person
  else
    v_status := 'PENDING';
  end if;

  if v_status = 'APPROVED' then
    v_hours := fn_config_numeric('unlock_window_hours', current_date);   -- CONFIG_NOT_SET
    if v_hours <= 0 then
      -- fn_set_config refuses this now. A row written before that guard existed must not
      -- grant an unlock that is expired the moment it is granted.
      raise exception 'CONFIG_VALUE_INVALID: unlock_window_hours is %, and must be more than 0 (R42)', v_hours;
    end if;
    v_at      := now();
    v_expires := now() + interval '1 hour' * v_hours::double precision;
  end if;

  insert into unlock_requests (target_type, target_id, requested_by, reason, status,
                               decided_by, decided_at, expires_at, decision_impact,
                               idempotency_key)
       values (p_target_type, p_target_id, v_actor, btrim(p_reason), v_status,
               v_by, v_at, v_expires, v_impact,
               p_idempotency_key)
    returning * into v_req;

  return jsonb_build_object(
    'unlock_request_id', v_req.id,
    'status',            v_req.status,
    'decided_by',        v_req.decided_by,
    'expires_at',        v_req.expires_at);
end $$;

revoke execute on function public.fn_request_unlock(uuid, unlock_target, uuid, text) from public, anon, authenticated;
grant  execute on function public.fn_request_unlock(uuid, unlock_target, uuid, text) to   authenticated;
