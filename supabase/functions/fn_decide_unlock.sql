-- Card ^ref-08 — fn_decide_unlock. The Owner approves or rejects a PENDING unlock request,
-- having seen its impact first (UAT-12, D07, R42, OW 11).
--
-- L1 ONLY, AND NO SCOPE CHECK. OUT_OF_SCOPE is fn_request_unlock's, where the requester's
-- reach is the question. The Owner has no scope limit to check.
--
-- A NOTE IS REQUIRED, FOR BOTH DECISIONS. v0.2:112, OW 11: "อนุมัติปลดล็อกและระบุเหตุผล"
-- (approve the unlock and state the reason). A rejection with no reason is the same gap
-- from the requester's side. They cannot tell a "no" from a mis-tap.
--
-- THE IMPACT IS COMPUTED FIRST AND STORED WITH THE DECISION (D07: "shown before it is
-- written"). The panel showed it from v_unlock_requests a moment earlier. This call
-- recomputes it inside the decision's own transaction, stores it in decision_impact, and
-- returns it. What was approved is what the audit row carries.
--
-- AN APPROVAL NEVER TOUCHES THE TARGET (PLAN-unlock.md Finding 1). The day stays CLOSED and
-- the lot stays at its state. The APPROVED row with expires_at > now() is what R8's two
-- guards admit, and the expiry binds at write time without a job (R42).
--
-- R4 RIDES THE STATE, NOT THE KEY. There is no column for the decision's key, and none is
-- needed. The same Owner making the same decision on an already-decided row gets the stored
-- body back. Any other decision on a decided row is UNLOCK_ALREADY_DECIDED. An approval that
-- has since expired still answers an APPROVED replay, with the status reading EXPIRED. That
-- is fn_set_config's precedent for a natural key carrying the retry. p_idempotency_key is
-- still required so every write RPC has one shape (ADR-005).
--
-- Covered by supabase/tests/unlock_test.sql (UL-03, UL-23 ... UL-29, UL-35).

create or replace function public.fn_decide_unlock(
  p_idempotency_key   uuid,
  p_unlock_request_id uuid,
  p_decision          text,
  p_decision_note     text
) returns jsonb
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor  uuid;
  v_req    unlock_requests;
  v_impact jsonb;
  v_hours  numeric;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  v_actor := fn_require_owner();   -- NO_ACTOR, FORBIDDEN

  if p_decision is null or p_decision not in ('APPROVED', 'REJECTED') then
    raise exception 'UNLOCK_DECISION_INVALID: a decision is APPROVED or REJECTED, got %', p_decision;
  end if;

  if coalesce(btrim(p_decision_note), '') = '' then
    raise exception 'DECISION_NOTE_REQUIRED: OW 11 decides an unlock with a stated reason (v0.2 OW 11)';
  end if;

  select * into v_req from unlock_requests where id = p_unlock_request_id for update;
  if v_req.id is null then
    raise exception 'UNLOCK_REQUEST_NOT_FOUND: no unlock request %', p_unlock_request_id;
  end if;

  if v_req.status <> 'PENDING' then
    if v_req.decided_by = v_actor
       and ((p_decision = 'APPROVED' and v_req.status in ('APPROVED', 'EXPIRED'))
         or (p_decision = 'REJECTED' and v_req.status = 'REJECTED')) then
      return jsonb_build_object(
        'unlock_request_id', v_req.id,
        'status',            case when v_req.status = 'APPROVED' and v_req.expires_at <= now()
                                  then 'EXPIRED' else v_req.status::text end,
        'decided_by',        v_req.decided_by,
        'expires_at',        v_req.expires_at,
        'impact',            v_req.decision_impact);
    end if;
    raise exception 'UNLOCK_ALREADY_DECIDED: request % is already %', v_req.id, v_req.status;
  end if;

  v_impact := fn_unlock_impact(v_req.target_type, v_req.target_id);

  if p_decision = 'APPROVED' then
    v_hours := fn_config_numeric('unlock_window_hours', current_date);   -- CONFIG_NOT_SET
    if v_hours <= 0 then
      raise exception 'CONFIG_VALUE_INVALID: unlock_window_hours is %, and must be more than 0 (R42)', v_hours;
    end if;

    update unlock_requests
       set status          = 'APPROVED',
           decided_by      = v_actor,
           decided_at      = now(),
           decision_note   = btrim(p_decision_note),
           decision_impact = v_impact,
           expires_at      = now() + interval '1 hour' * v_hours::double precision
     where id = v_req.id
    returning * into v_req;
  else
    update unlock_requests
       set status          = 'REJECTED',
           decided_by      = v_actor,
           decided_at      = now(),
           decision_note   = btrim(p_decision_note),
           decision_impact = v_impact
     where id = v_req.id
    returning * into v_req;
  end if;

  return jsonb_build_object(
    'unlock_request_id', v_req.id,
    'status',            v_req.status,
    'decided_by',        v_req.decided_by,
    'expires_at',        v_req.expires_at,
    'impact',            v_req.decision_impact);
end $$;

revoke execute on function public.fn_decide_unlock(uuid, uuid, text, text) from public, anon, authenticated;
grant  execute on function public.fn_decide_unlock(uuid, uuid, text, text) to   authenticated;
