-- Card ^ref-35 — fn_confirm_central_intake. OW 06's RPC: the return leg signed for at central
-- stock, by L1 or a can_receive_central delegate (BR12, R27).
--
-- A ROUTE ASSERTION IN FRONT OF fn_confirm_transport_receipt, AND NOTHING ELSE (PLAN-movement.md
-- Finding 3, Seam 2). That function already receives into CENTRAL — partial receipts, the
-- over-delivery ADJUSTMENT, the ALERT-mode variance, the second key under `for update` — and
-- since ^ref-35 it also admits the delegate and advances the lot to CENTRAL_STOCK. A second
-- writer of the same transport line would be a second copy of every one of those rules, and
-- the two diverge on the first amendment to either. So this one reads, refuses, and delegates.
--
-- The lot's state advance is NOT here. Both functions are granted to authenticated, so an L1
-- calling the base function directly on a return line — which OW 02 legitimately does for the
-- other two routes — would receive the meat and leave the lot at LOT_CLOSED (TC-23).
--
-- Why it exists at all: a line id typed into the central-intake screen that turns out to be a
-- branch leg fails by name, NOT_A_CENTRAL_INTAKE, instead of quietly signing for somebody
-- else's delivery (TC-25).
--
-- THE PREAMBLE RUNS FIRST, before the line is read, so a caller with no right to OW 06 learns
-- nothing about which route a line id belongs to. The base function asks again; that is one
-- indexed lookup, and it keeps the base function honest when called on its own.
--
-- The read is not under `for update`: this is routing, not a guard. Two concurrent intakes
-- still resolve to one winner and one LINE_ALREADY_RECEIVED inside the base function, where the
-- lock is (transport_concurrency_test.sh, TC-24).
--
-- Same signature as the base function, deliberately: OW 06's typed wrapper is then the same
-- shape as OW 02's, and one contract does not drift from the other.
--
-- Covered by supabase/tests/movement_test.sql (TC-25, TC-26).

create or replace function public.fn_confirm_central_intake(
  p_idempotency_key     uuid,
  p_line_id             uuid,
  p_event_date          date,
  p_received_weight_kg  numeric,
  p_variance_reason     text    default null,
  p_variance_settlement text    default null,
  p_received_bag_count  integer default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_route transport_route;
  v_kind  location_kind;
begin
  -- ^fix-numeric-scale: a third decimal is refused by name, not rounded by the column.
  perform fn_require_two_decimals('p_received_weight_kg', p_received_weight_kg);

  perform fn_require_central_receiver();

  select r.route, l.kind into v_route, v_kind
    from transport_lines t
    join transport_runs r on r.id = t.run_id
    join locations l      on l.id = t.to_location_id
   where t.id = p_line_id;
  if not found then
    raise exception 'LINE_NOT_FOUND: no transport line %', p_line_id;
  end if;

  if v_route <> 'CM_TO_FOODIVA' or v_kind <> 'CENTRAL' then
    raise exception 'NOT_A_CENTRAL_INTAKE: line % is a % leg into a % location; OW 06 signs for the return leg into central only (BR12)',
      p_line_id, v_route, v_kind;
  end if;

  return fn_confirm_transport_receipt(p_idempotency_key, p_line_id, p_event_date,
                                      p_received_weight_kg, p_variance_reason,
                                      p_variance_settlement, p_received_bag_count);
end $$;

revoke execute on function public.fn_confirm_central_intake(uuid, uuid, date, numeric, text, text, integer) from public, anon, authenticated;
grant  execute on function public.fn_confirm_central_intake(uuid, uuid, date, numeric, text, text, integer) to authenticated;
