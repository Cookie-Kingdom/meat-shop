-- Card ^ref-66 — fn_assign_lot_operator. The Owner names the L3 who works a lot at its chef
-- house (CM 01, v0.2:66, :78 — "เลือก Lot ที่ได้รับมอบหมาย"). Until this existed nothing wrote
-- lots.assigned_operator_id, and fn_require_operator's step 4 refused every chef-house write.
--
-- L1 ONLY, AND BEFORE THE LOOKUP. fn_require_owner() runs first, so an L2 or L3 probing lot ids
-- learns nothing, not even LOT_NOT_FOUND (fn_set_smoke_fee_override's reason, ADR-004).
--
-- THE OPERATOR MUST BE ABLE TO USE THE ASSIGNMENT: an active L3 profile (NOT_AN_OPERATOR) with a
-- user_locations row at the lot's chef house (OPERATOR_NOT_AT_CHEF_HOUSE). Without either,
-- fn_require_operator refuses the operator at step 1-3 anyway; refusing here shows the mistake
-- to the Owner instead of leaving an operator with an empty CM 01.
--
-- NOT FROM THE CLOSE ON (LOT_ALREADY_CLOSED). A closed lot is the Owner's (ADR-013), and
-- fn_request_unlock reads assigned_operator_id to decide which L3 may ask to reopen it, so moving
-- it after close would hand the unlock to somebody who never worked the lot. Before close a
-- reassignment is ordinary: an operator off sick mid-smoke.
--
-- IDEMPOTENCY RIDES THE NATURAL KEY (R38): (lot, operator). The operator who already stands
-- returns the lot and writes nothing — checked before the close refusal, so a retry that lands
-- after the close is still a retry (fn_set_return_pickup_date's ordering). The key is required
-- and not stored.
--
-- THE AUDIT ROW IS trg_audit_lots's (R32): the UPDATE carries the before and after operator and
-- the Owner as actor. A replay writes nothing, so it adds no audit row.
--
-- ponytail: no unassign — a null operator is OPERATOR_REQUIRED. Nothing in v0.2 empties an
-- assignment; add it when a screen needs one. Writes nothing to stock_ledger.
--
-- Covered by supabase/tests/lot_assignment_test.sql (LA-01 ... LA-10).

create or replace function public.fn_assign_lot_operator(
  p_idempotency_key uuid,
  p_lot_id          uuid,
  p_operator_id     uuid
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_lot lots;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- NO_ACTOR, FORBIDDEN. Before the lookup, on purpose (header).
  perform fn_require_owner();

  select * into v_lot from lots where id = p_lot_id for update;
  if not found then
    raise exception 'LOT_NOT_FOUND: no lot %', p_lot_id;
  end if;

  if p_operator_id is null then
    raise exception 'OPERATOR_REQUIRED: name the operator who works lot %', v_lot.lot_code;
  end if;

  -- R38: the standing operator again is a retry, and a retry writes nothing.
  if v_lot.assigned_operator_id = p_operator_id then
    return p_lot_id;
  end if;

  -- The enum's declaration order is the lifecycle, the mechanism fn_guard_lot_closed uses.
  if v_lot.state >= 'LOT_CLOSED' then
    raise exception 'LOT_ALREADY_CLOSED: lot % is at %; a closed lot keeps the operator who worked it (ADR-013)',
      v_lot.lot_code, v_lot.state;
  end if;

  if not exists (select 1 from profiles
                  where id = p_operator_id and is_active and role = 'L3_CM_OPERATOR') then
    raise exception 'NOT_AN_OPERATOR: % is not an active chef-house operator (L3)', p_operator_id;
  end if;

  if not exists (select 1 from user_locations
                  where profile_id = p_operator_id
                    and location_id = v_lot.chef_house_location_id) then
    raise exception 'OPERATOR_NOT_AT_CHEF_HOUSE: the operator does not work at the chef house of lot %',
      v_lot.lot_code;
  end if;

  update lots set assigned_operator_id = p_operator_id where id = p_lot_id;

  return p_lot_id;
end $$;

revoke execute on function public.fn_assign_lot_operator(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.fn_assign_lot_operator(uuid, uuid, uuid) to authenticated;
