-- Card ^ref-34 (absorbed, PLAN-movement.md Finding 2) — the only writer of
-- user_locations.can_receive_central.
--
-- API_DATA_MODEL.md contracted this function and no card owned it, so the delegation BR12 and
-- BR17 describe could only be granted by a direct UPDATE — which authenticated may not make
-- (ADR-002). A delegation nobody can grant reads as implemented and is not.
--
-- The flag is a property of an EXISTING assignment. No row for (profile, location) is
-- USER_LOCATION_NOT_FOUND, not an insert: creating the assignment is identity work (^ref-05),
-- and a grant that could also create one would hand out location membership — read scope —
-- through a function whose whole point is that it grants none (TC-07).
--
-- IDEMPOTENCY RIDES THE NATURAL KEY (R38): (profile, location) plus the target value. The same
-- value again returns the row's id and writes nothing, so R32's audit trigger records a change
-- only when there was one (TC-06). The key is required and not stored.
--
-- Granted to authenticated; the L1 gate is fn_require_owner, inside.
--
-- Covered by supabase/tests/movement_test.sql (TC-04 ... TC-07).

create or replace function public.fn_grant_central_receiver(
  p_idempotency_key uuid,
  p_profile_id      uuid,
  p_location_id     uuid,
  p_can_receive     boolean
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_id  uuid;
  v_cur boolean;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  perform fn_require_owner();

  if p_can_receive is null then
    raise exception 'CAN_RECEIVE_REQUIRED: say true to delegate or false to revoke';
  end if;

  select id, can_receive_central into v_id, v_cur
    from user_locations
   where profile_id = p_profile_id and location_id = p_location_id
     for update;
  if not found then
    raise exception 'USER_LOCATION_NOT_FOUND: profile % is not assigned to location %',
      p_profile_id, p_location_id;
  end if;

  if v_cur is distinct from p_can_receive then
    update user_locations set can_receive_central = p_can_receive where id = v_id;
  end if;

  return v_id;
end $$;

revoke execute on function public.fn_grant_central_receiver(uuid, uuid, uuid, boolean) from public, anon, authenticated;
grant  execute on function public.fn_grant_central_receiver(uuid, uuid, uuid, boolean) to authenticated;
