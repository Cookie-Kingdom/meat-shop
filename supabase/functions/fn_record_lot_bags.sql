-- Card ^ref-28 — fn_record_lot_bags. CM 04's bottom half: the individual pack weights, sent
-- as one array per save rather than one call per row (BR18, R7, R7a, R39, Findings 2 and 7).
--
-- NO BAG CODE, AND NOTHING HERE IS ONE. BR18: the bag carries the smoke date and nothing is
-- printed, assigned or required. lot_bags has no column for a code and this function adds
-- none — the card's acceptance line is an absence, and production_schema_test.sql TC-04
-- asserts it. seq is a row number inside the group, not a label on a bag.
--
-- ONE DATE, AND IT MUST BE A DAY THE LOT WAS LOGGED (TDD-lots.md open question 5). CM 04 has
-- one date field — v0.2's CM 04 row, PRODUCT.md's "date (defaulted to today)", and the
-- skeleton's single DateNavigator — so the bags' smoke date and the log's event_date are the
-- same value by construction. p_smoke_date stays a parameter because the screen already holds
-- (lot, date), but a date with no smoke_daily_logs row for this lot raises SMOKE_LOG_MISSING:
-- bags from a day the lot never went into the smoker are meat from nowhere, and with the check
-- the two dates cannot drift. It is also the state floor — a log exists only from CM_RECEIVED
-- on — so there is no separate LOT_STATE_INVALID, and the upper end is fn_guard_lot_closed's,
-- exactly as in fn_upsert_smoke_daily_log (R8/R42, TC-50 ... TC-52).
--
-- THE BATCH KEY (Finding 2, R39). seq is minted as max(seq)+1, so a replay mints fresh seqs and
-- (smoke_date_group_id, seq) never fires; lot_bags_batch_key is unique on the PAIR
-- (idempotency_key, seq) because one call is one batch. The pair alone still admits a replay
-- carrying MORE bags — bag 61's (key, 61) collides with nothing — so the key is looked up
-- explicitly: same group and same weights return the original count and write nothing
-- (TC-26); anything else raises LOT_BAGS_IDEMPOTENCY_CONFLICT (TC-27). A NEW key on the same
-- smoke date is a second genuine batch and APPENDS (Seam 3, TC-28) — not a correction, which
-- is what the same situation means for the log and the receipt.
--
-- THE KEY IS CHECKED UNDER THE GROUP LOCK, NOT BEFORE IT — the difference from
-- fn_add_po_delivery. There the key alone is unique, so two sessions racing one key collide on
-- the index. Here they would not: both miss the lookup, the second waits on the lock and then
-- mints 61 ... 120 under the same key, and the pair index sees nothing wrong. Checked after the
-- lock, the second session finds the first one's committed batch and returns its count.
--
-- GET-OR-CREATE THE GROUP WITHOUT A RACE (R7, TC-29). Select it FOR UPDATE; only when it is not
-- there, insert ... on conflict do nothing and select again. A second session creating the same
-- group blocks on the first one's uncommitted row, does nothing, and then locks the committed
-- one — no unique violation reaches either caller. Selecting first also means a replay inserts
-- nothing and fires no trigger, so a dropped connection is still answered after the lot has
-- closed. The lock is what serialises seq: max(seq) is read by the statement after it.
--
-- NEVER WRITES THE GROUP'S TOTALS. smoke_date_groups.packed_weight_kg and bag_count belong to
-- trg_rollup_smoke_group_packed (Finding 7, R7a). This function inserts bags and nothing else,
-- so the numerator of every F7 yield figure has exactly one writer.
--
-- WEIGHTS ARE ROUNDED TO numeric(12,2) BEFORE THEY ARE CHECKED OR COMPARED, because that is
-- what the column stores: 0.004 kg would otherwise pass `> 0` here and die on the check
-- constraint as a name, and a replay of 0.524 would fail to match its own stored 0.52.
--
-- NO LEDGER ROW (Finding 10). The bags reach stock_ledger at fn_close_lot (^ref-29).
--
-- Covered by supabase/tests/production_test.sql (TC-25 ... TC-28) and
-- production_concurrency_test.sh (TC-29).

create or replace function public.fn_record_lot_bags(
  p_idempotency_key uuid,
  p_lot_id          uuid,
  p_smoke_date      date,
  p_pack_weights_kg numeric[]
) returns integer
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_weights     numeric(12,2)[];
  v_bad         bigint;
  v_group       uuid;
  v_prior_group uuid;
  v_prior       numeric[];
  v_seq         integer;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  if p_smoke_date is null then
    raise exception 'SMOKE_DATE_REQUIRED: the bag carries its smoke date and nothing else (BR18, R7)';
  end if;

  if p_pack_weights_kg is null or cardinality(p_pack_weights_kg) = 0 then
    raise exception 'PACK_WEIGHTS_REQUIRED: a batch is at least one pack weight';
  end if;

  v_weights := p_pack_weights_kg::numeric(12,2)[];
  select min(i) into v_bad
    from unnest(v_weights) with ordinality u(w, i)
   where w is null or w <= 0;
  if v_bad is not null then
    raise exception 'PACK_WEIGHT_INVALID: bag % weighs % kg — a pack weight is > 0 to two decimals',
      v_bad, coalesce(v_weights[v_bad]::text, 'null');
  end if;

  -- Four questions, and LOT_NOT_FOUND among them. See fn_require_operator's header.
  perform fn_require_operator(p_lot_id);

  if not exists (select 1 from smoke_daily_logs
                  where lot_id = p_lot_id and event_date = p_smoke_date) then
    raise exception 'SMOKE_LOG_MISSING: lot % has no smoke log on % — bags carry the date the lot was smoked (BR18)',
      p_lot_id, p_smoke_date;
  end if;

  ------------------------------------------------------------ 1. get-or-create, then lock (R7)
  select id into v_group from smoke_date_groups
   where lot_id = p_lot_id and smoke_date = p_smoke_date for update;
  if not found then
    insert into smoke_date_groups (lot_id, smoke_date) values (p_lot_id, p_smoke_date)
    on conflict (lot_id, smoke_date) do nothing;
    select id into v_group from smoke_date_groups
     where lot_id = p_lot_id and smoke_date = p_smoke_date for update;
  end if;

  ------------------------------------------------------- 2. the batch key, under the lock (R39)
  select smoke_date_group_id, array_agg(packed_weight_kg order by seq)
    into v_prior_group, v_prior
    from lot_bags where idempotency_key = p_idempotency_key
   group by smoke_date_group_id;
  if found then
    if v_prior_group = v_group and v_prior = v_weights then
      return cardinality(v_prior);
    end if;
    raise exception 'LOT_BAGS_IDEMPOTENCY_CONFLICT: key % was used for a different batch',
      p_idempotency_key;
  end if;

  ---------------------------------------------------------------- 3. append after max(seq)
  select coalesce(max(seq), 0) into v_seq from lot_bags where smoke_date_group_id = v_group;

  insert into lot_bags (smoke_date_group_id, seq, packed_weight_kg, idempotency_key)
  select v_group, v_seq + i, w, p_idempotency_key
    from unnest(v_weights) with ordinality u(w, i);

  return cardinality(v_weights);
end $$;

revoke execute on function public.fn_record_lot_bags(uuid, uuid, date, numeric[]) from public, anon, authenticated;
grant  execute on function public.fn_record_lot_bags(uuid, uuid, date, numeric[]) to authenticated;
