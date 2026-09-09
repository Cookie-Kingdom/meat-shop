-- fn_reverse_ledger_entry() — the only way to correct a posted movement (ADR-003, R2).
--
-- The ledger is append-only, so a correction is two new rows and not an edit: a REVERSAL
-- row carrying the opposite quantity and pointing at the original through `reversal_of`,
-- then the replacement row with the figure that should have been entered. The original
-- stays readable forever — what was first believed is part of the trail, and a schema that
-- lets it be edited cannot prove anything about the past.
--
-- Both rows go through fn_post_ledger. This function never touches stock_ledger directly,
-- for the reason ADR-002 gives: one writer, one place the balance check and the idempotency
-- branch can be got wrong.
--
-- The two keys. A pair of rows cannot share one idempotency key — the column is UNIQUE.
-- The replacement's key is DERIVED from the caller's, deterministically:
--
--   replacement_key = md5(caller_key || ':replacement')::uuid
--
-- so a retry of the correction re-derives the same key, both inserts hit ON CONFLICT DO
-- NOTHING, and the caller gets the original two ids back. A random second key would turn
-- every dropped connection into a duplicated correction, which is the exact failure R4
-- exists to prevent. (Not uuid_generate_v5 — that needs uuid-ossp, and md5 is already in
-- core and just as deterministic here.)
--
-- p_replacement_qty_delta may be null: that is a plain cancellation, reversal only, no
-- replacement row. replacement_id comes back null with it.
--
-- One consequence worth stating: the reversal is posted through the same non-negative
-- check as any other draw. Reversing an INTAKE whose stock has since been consumed fails
-- with INSUFFICIENT_STOCK rather than stranding the tuple below zero. That is deliberate —
-- a correction that cannot be made without breaking BR24 needs a human, not a silent pass.

create or replace function public.fn_reverse_ledger_entry(
  p_idempotency_key       uuid,
  p_original_id           uuid,
  p_replacement_qty_delta numeric default null,
  p_reason                text default null,
  out reversal_id         uuid,
  out replacement_id      uuid
)
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_orig stock_ledger%rowtype;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- L1 only (RPC table, ADR-004). The check is here and not in the route: a SECURITY
  -- DEFINER function runs as the owner, so without this any authenticated session could
  -- reverse any row in the ledger and the UI would be the only thing saying otherwise.
  if fn_current_role() is distinct from 'L1_OWNER' then
    raise exception 'FORBIDDEN: only L1 may reverse a ledger entry (R20/ADR-004)';
  end if;

  select * into v_orig from stock_ledger where id = p_original_id;
  if not found then
    raise exception 'LEDGER_ROW_NOT_FOUND: no stock_ledger row %', p_original_id;
  end if;

  if v_orig.movement_type = 'REVERSAL' then
    raise exception 'NOT_REVERSIBLE: % is itself a REVERSAL row (R2)', p_original_id;
  end if;

  -- Already answered. Checked against the ledger rather than a flag column, because a flag
  -- would be a mutable column on an append-only table.
  if exists (select 1 from stock_ledger
              where reversal_of = p_original_id
                and idempotency_key <> p_idempotency_key) then
    raise exception 'ALREADY_REVERSED: % has already been reversed (R2)', p_original_id;
  end if;

  reversal_id := fn_post_ledger(
    p_idempotency_key     => p_idempotency_key,
    p_item_type           => v_orig.item_type,
    p_location_id         => v_orig.location_id,
    p_stock_state         => v_orig.stock_state,
    p_movement_type       => 'REVERSAL',
    p_qty_delta           => -v_orig.qty_delta,
    p_business_date       => v_orig.business_date,   -- ADR-007: the day it happened, not today
    p_event_at            => v_orig.event_at,
    p_product_id          => v_orig.product_id,
    p_packaging_item_id   => v_orig.packaging_item_id,
    p_lot_id              => v_orig.lot_id,
    p_smoke_date_group_id => v_orig.smoke_date_group_id,
    p_source_table        => v_orig.source_table,
    p_source_id           => v_orig.source_id,
    p_reason              => p_reason,
    p_reversal_of         => p_original_id);

  if p_replacement_qty_delta is not null then
    replacement_id := fn_post_ledger(
      p_idempotency_key     => (md5(p_idempotency_key::text || ':replacement'))::uuid,
      p_item_type           => v_orig.item_type,
      p_location_id         => v_orig.location_id,
      p_stock_state         => v_orig.stock_state,
      p_movement_type       => v_orig.movement_type,
      p_qty_delta           => p_replacement_qty_delta,
      p_business_date       => v_orig.business_date,
      p_event_at            => v_orig.event_at,
      p_product_id          => v_orig.product_id,
      p_packaging_item_id   => v_orig.packaging_item_id,
      p_lot_id              => v_orig.lot_id,
      p_smoke_date_group_id => v_orig.smoke_date_group_id,
      p_source_table        => v_orig.source_table,
      p_source_id           => v_orig.source_id,
      p_reason              => p_reason);
  end if;
end $$;

-- `authenticated` may call it; the L1 test inside decides. anon holds nothing.
revoke execute on function public.fn_reverse_ledger_entry(uuid, uuid, numeric, text) from public;
grant  execute on function public.fn_reverse_ledger_entry(uuid, uuid, numeric, text) to authenticated;
