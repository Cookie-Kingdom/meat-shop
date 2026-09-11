-- Card ^ref-19 — fn_create_po. The Owner raises a purchase order against a supplier.
--
-- A PO IS A COMMITMENT, NOT A MOVEMENT. Nothing here touches stock_ledger: the meat has
-- not left Foodiva, and posting it now would put weight into IN_TRANSIT days before the
-- truck. Stock enters the system at fn_dispatch_transport_line (^ref-22, F5). TC-25 counts
-- the ledger across a PO and two rounds and asserts it did not move.
--
-- ordered_weight_kg is NOT the loss base and never becomes one. What was ordered and what
-- actually left the building are different numbers, and the whole point of D01 is that the
-- second one is recorded per round on po_deliveries (BR03, R16). This column exists so the
-- Owner can see what is still outstanding, and for nothing else.
--
-- po_number is generated here because F4 says a reference number is generated. Letting the
-- Owner type one hands them a unique-constraint error for a field they thought was free
-- text, at the worst possible moment. Format PO-YYYYMM-NNN, the counter scoped to the
-- month of the order date and derived under an advisory lock on that month — two POs
-- raised in the same second would otherwise compute the same NNN and one would fail on the
-- po_number index. The format is Owner-facing and written on paper; it is an Open Question
-- in TDD-purchasing.md and wants confirming before the first real PO, because renumbering
-- afterwards means rewriting a reference somebody already holds.
--
-- created_by is resolved from auth.uid() inside the body and is never a parameter. A
-- purchase commitment is exactly the kind of row the audit trail exists for, and a caller
-- must not be able to sign one as somebody else (TC-06).
--
-- L1 only, checked in the body rather than by a policy: this is SECURITY DEFINER, so RLS
-- does not apply inside it and there is no policy to consult. The function is the boundary
-- (ADR-002, ADR-004).
--
-- Covered by supabase/tests/purchasing_test.sql (TC-05 ... TC-12).

create or replace function public.fn_create_po(
  p_idempotency_key       uuid,
  p_supplier_id           uuid,
  p_event_date            date,
  p_ordered_weight_kg     numeric,
  p_unit_price_thb_per_kg numeric default null,
  p_brine_pct_offered     numeric default null,
  p_brine_cost_thb        numeric default null,
  p_note                  text    default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor    uuid;
  v_active   boolean;
  v_row      purchase_orders;
  v_id       uuid;
  v_month    text;
  v_next     integer;
  v_po_number text;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- ^fix-numeric-scale: a third decimal is refused by name, not rounded by the column.
  perform fn_require_two_decimals('p_ordered_weight_kg', p_ordered_weight_kg);
  perform fn_require_two_decimals('p_unit_price_thb_per_kg', p_unit_price_thb_per_kg);
  perform fn_require_two_decimals('p_brine_pct_offered', p_brine_pct_offered);
  perform fn_require_two_decimals('p_brine_cost_thb', p_brine_cost_thb);

  v_actor := fn_require_owner();

  if p_event_date is null then
    raise exception 'PO_EVENT_DATE_REQUIRED: an undated order cannot be resolved by event date (R12)';
  end if;

  -- Named before the CHECK fires. `violates check constraint
  -- "purchase_orders_ordered_weight_kg_check"` reaching the Owner is a support ticket; the
  -- CHECK stays as the backstop, not as the message (TC-10).
  if p_ordered_weight_kg is null or p_ordered_weight_kg <= 0 then
    raise exception 'PO_WEIGHT_INVALID: ordered_weight_kg must be > 0, got %', p_ordered_weight_kg;
  end if;

  select is_active into v_active from suppliers where id = p_supplier_id;
  if not found then
    raise exception 'SUPPLIER_NOT_FOUND: no supplier %', p_supplier_id;
  end if;
  if not v_active then
    raise exception 'SUPPLIER_INACTIVE: supplier % is not active', p_supplier_id;
  end if;

  ------------------------------------------------------------------------- the retry check
  -- Asked before the number is minted, so a retry does not burn a po_number on its way to
  -- returning the original id.
  select * into v_row from purchase_orders where idempotency_key = p_idempotency_key;
  if found then
    if v_row.supplier_id = p_supplier_id
       and v_row.event_date = p_event_date
       and v_row.ordered_weight_kg = p_ordered_weight_kg
       and v_row.unit_price_thb_per_kg is not distinct from p_unit_price_thb_per_kg
       and v_row.brine_pct_offered is not distinct from p_brine_pct_offered
       and v_row.brine_cost_thb is not distinct from p_brine_cost_thb then
      return v_row.id;                          -- a dropped connection, replayed (R4)
    end if;
    -- Same key, different payload. Not a retry — either a client bug or a key reused for a
    -- second order. Raising leaves the committed PO exactly as it was; returning its id
    -- would tell the caller their 120 kg order succeeded when a 100 kg one is what exists.
    raise exception 'PO_IDEMPOTENCY_CONFLICT: key % was used for a different order', p_idempotency_key;
  end if;

  ------------------------------------------------------------------------ the number, once
  -- xact lock, never the session form — that one leaks into the next request on a pooled
  -- connection and the lock is never released.
  v_month := to_char(p_event_date, 'YYYYMM');
  perform pg_advisory_xact_lock(hashtext('po_number:' || v_month));

  -- max of the existing suffix, not count(*): a gap in the sequence must not hand the next
  -- PO a number that has already been written on paper.
  select coalesce(max((regexp_match(po_number, '(\d+)$'))[1]::integer), 0) + 1
    into v_next
    from purchase_orders
   where po_number like 'PO-' || v_month || '-%';

  v_po_number := 'PO-' || v_month || '-' || lpad(v_next::text, 3, '0');

  insert into purchase_orders (
    po_number, supplier_id, event_date, ordered_weight_kg, unit_price_thb_per_kg,
    brine_pct_offered, brine_cost_thb, note, created_by, idempotency_key)
  values (
    v_po_number, p_supplier_id, p_event_date, p_ordered_weight_kg, p_unit_price_thb_per_kg,
    p_brine_pct_offered, p_brine_cost_thb, p_note, v_actor, p_idempotency_key)
  returning id into v_id;

  -- No audit_log insert here. ^ref-06's generic trigger already writes one inside this same
  -- transaction, with actor_id and actor_role resolved from auth.uid() (R32). A second one
  -- would audit every purchase order twice (TC-26).
  return v_id;

exception
  -- Two identical calls that both got past the retry check above. The index is the
  -- authority; re-read the row it protected and answer as a retry.
  when unique_violation then
    select * into v_row from purchase_orders where idempotency_key = p_idempotency_key;
    if found then
      return v_row.id;
    end if;
    raise;
end $$;

revoke execute on function public.fn_create_po(uuid, uuid, date, numeric, numeric, numeric, numeric, text) from public, anon, authenticated;
grant  execute on function public.fn_create_po(uuid, uuid, date, numeric, numeric, numeric, numeric, text) to authenticated;
