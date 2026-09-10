-- Card ^ref-49 — fn_accept_count_variance. The Owner accepts a physical count's variance, and
-- the ledger is corrected the only way it can be: a reversal plus a replacement (PLAN-materials.md
-- T4, Findings 7, 15; TDD Seam 4).
--
-- The card's acceptance: "a count never overwrites the ledger — it produces a reconcilable
-- variance, closed by a reversal plus replacement if the Owner accepts it." fn_record_physical_count
-- is the first half and this is the second. Nothing here inserts into stock_ledger or updates a
-- count. It CALLS fn_reverse_ledger_entry (^ref-16), which calls fn_post_ledger, so the balance
-- check and the idempotency branch stay in the one place they are written (ADR-002, ADR-003).
--
-- THE OWNER NAMES THE ROW. A variance says the shelf and the ledger disagree by N; it does not
-- say which movement was wrong. M6's case: 88 in the system, 87 on the shelf. The Owner decides
-- that the SALE of 12 was really 13, and names that row. The correction is then:
--
--   reversal     +12   (fn_reverse_ledger_entry, reversal_of = the SALE row)
--   replacement  -13   = original + variance = -12 + (-1)
--
-- and the tuple's balance becomes 87, which is the count (TC-57). A replacement that would change
-- the row's SIGN means the named row is too small to absorb the variance (a sale turned into an
-- intake), so it is refused: COUNT_CORRECTION_TOO_LARGE. A replacement of exactly zero is a plain
-- cancellation, passed to fn_reverse_ledger_entry as null.
--
-- THE ROW MUST BE ON THE COUNT'S TUPLE: same location, same item type, not IN_TRANSIT, and for
-- PACKAGING the same packaging item, for SMOKED_MEAT the same smoke date group. Chilli is checked
-- on item type and location only, matching how the count summed it (every product_id). A row from
-- another tuple would "fix" this count by moving somebody else's stock.
--
-- ONE ACCEPTANCE PER COUNT, AND NO NEW TABLE. The ledger key is derived from the count, not taken
-- from the caller:
--
--   md5(count_id || ':count-accept')::uuid
--
-- so a retry re-derives it and gets the committed pair back (R4), a second acceptance against a
-- DIFFERENT row is refused by name (COUNT_ALREADY_ACCEPTED), and v_count_variance finds the
-- correction with the same expression. p_idempotency_key stays required so the RPC shape and the
-- typed wrapper stay uniform (ADR-005, R38 — fn_open_daily_report's precedent), but it is not what
-- carries the retry. physical_counts is never updated, which is just as well: once the day closes,
-- lane C's R8 trigger would refuse the update anyway.
--
-- AN ADVISORY LOCK ON THAT KEY (Finding 15). Two Owners accepting one count against two different
-- rows would both miss the retry check, and fn_post_ledger's `on conflict do nothing` would return
-- the winner's reversal to the loser as though it were the loser's own. The xact lock makes the
-- second caller wait, see the first pair, and get COUNT_ALREADY_ACCEPTED.
--
-- WHAT THIS CANNOT DO, BY DESIGN. Reversing an INTAKE whose stock has since been drawn fails with
-- INSUFFICIENT_STOCK, because the reversal is posted before the replacement and fn_post_ledger
-- will not strand a tuple below zero (fn_reverse_ledger_entry's header). A variance with no row to
-- correct needs an R19 ADJUSTMENT, which is not built (PLAN, Deliberately left out).
--
-- L1 ONLY, fn_require_owner: a ledger correction is the Owner's (R2, ADR-004), and
-- fn_reverse_ledger_entry checks L1 again inside.
--
-- Covered by supabase/tests/materials_count_test.sql (TC-52 ... TC-59, TC-62).

create or replace function public.fn_accept_count_variance(
  p_idempotency_key   uuid,
  p_physical_count_id uuid,
  p_ledger_id         uuid,
  p_reason            text
) returns json
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_count physical_counts;
  v_key   uuid;
  v_prior stock_ledger;
  v_orig  stock_ledger;
  v_repl  numeric;
  v_rev   uuid;
  v_new   uuid;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  v_actor := fn_require_owner();

  select * into v_count from physical_counts where id = p_physical_count_id;
  if not found then
    raise exception 'COUNT_NOT_FOUND: no physical count %', p_physical_count_id;
  end if;

  v_key := md5(v_count.id::text || ':count-accept')::uuid;
  perform pg_advisory_xact_lock(hashtextextended(v_key::text, 0));

  ---------------------------------------------------------------------- the retry (R4)
  select * into v_prior from stock_ledger where idempotency_key = v_key;
  if found then
    if v_prior.reversal_of is distinct from p_ledger_id then
      raise exception 'COUNT_ALREADY_ACCEPTED: count % was accepted against ledger row % at % — one acceptance per count',
        v_count.id, v_prior.reversal_of, v_prior.created_at;
    end if;
    -- The replacement key is fn_reverse_ledger_entry's derivation, applied to this key.
    select id into v_new from stock_ledger
     where idempotency_key = md5(v_key::text || ':replacement')::uuid;
    return json_build_object('physical_count_id', v_count.id,
                             'reversal_id',       v_prior.id,
                             'replacement_id',    v_new);
  end if;

  -------------------------------------------------------------------- the arguments
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'COUNT_REASON_REQUIRED: accepting a variance moves stock, and the ledger row has to say why (R2, R19)';
  end if;

  if v_count.variance_qty = 0 then
    raise exception 'COUNT_NO_VARIANCE: count % matches the ledger (counted % = system %) — there is nothing to accept',
      v_count.id, v_count.counted_qty, v_count.system_qty;
  end if;

  select * into v_orig from stock_ledger where id = p_ledger_id;
  if not found then
    raise exception 'LEDGER_ROW_NOT_FOUND: no stock_ledger row %', p_ledger_id;
  end if;

  if v_orig.location_id <> v_count.location_id
     or v_orig.item_type <> v_count.item_type
     or v_orig.stock_state = 'IN_TRANSIT'
     or (v_count.item_type = 'PACKAGING'
         and v_orig.packaging_item_id is distinct from v_count.packaging_item_id)
     or (v_count.item_type = 'SMOKED_MEAT'
         and v_orig.smoke_date_group_id is distinct from v_count.smoke_date_group_id) then
    raise exception 'COUNT_CORRECTION_WRONG_TUPLE: ledger row % is % % at location %, not on count %''s tuple',
      p_ledger_id, v_orig.item_type, v_orig.stock_state, v_orig.location_id, v_count.id;
  end if;

  v_repl := v_orig.qty_delta + v_count.variance_qty;
  if v_repl <> 0 and sign(v_repl) <> sign(v_orig.qty_delta) then
    raise exception 'COUNT_CORRECTION_TOO_LARGE: row % moved %; a variance of % would turn it into % — name a row that can absorb it',
      p_ledger_id, v_orig.qty_delta, v_count.variance_qty, v_repl;
  end if;

  --------------------------------------------------------------------- the correction
  -- Zero is a plain cancellation: no replacement row, replacement_id null (R2).
  select r.reversal_id, r.replacement_id into v_rev, v_new
    from fn_reverse_ledger_entry(v_key, p_ledger_id, nullif(v_repl, 0), btrim(p_reason)) r;

  return json_build_object('physical_count_id', v_count.id,
                           'reversal_id',       v_rev,
                           'replacement_id',    v_new);
end $$;

revoke execute on function public.fn_accept_count_variance(uuid, uuid, uuid, text) from public, anon, authenticated;
grant  execute on function public.fn_accept_count_variance(uuid, uuid, uuid, text) to authenticated;
