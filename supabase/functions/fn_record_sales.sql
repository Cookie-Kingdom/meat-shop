-- Card ^ref-43 — fn_record_sales. BR 07's sales half: one batch of lines per save, recorded
-- as quantities against named lots, not as money (UAT-13, D03.1, D04, R14, R21, R29, R39).
--
-- WHO. The branch's own L2, or L1 (v0.2:57: the Owner "ดูและแก้ไขทุกสาขา" on Branch Operation
-- ขาย). fn_require_branch_or_owner is lane B's preamble (PLAN-thaw.md T3), called here and not
-- redefined. It runs with the report's location, which is null when the report does not
-- exist. An L2 then reads FORBIDDEN_LOCATION, the same answer a real report at another branch
-- gives, so nothing leaks. Only an L1 can reach REPORT_NOT_FOUND (PLAN-sales.md B1).
--
-- THE ORDER IS THE DESIGN (PLAN-sales.md B2, PLAN-thaw.md Finding 6):
--   key -> report -> preamble -> not found -> lock on the key -> replay -> REPORT_CLOSED
--   -> back-dating -> lines.
-- The replay comes BEFORE REPORT_CLOSED. Take a save that commits at 20:55 and loses its
-- response, a close at 21:00, and a retry at 21:01. Asking REPORT_CLOSED first would report a
-- write that succeeded, and R4 forbids that. The preamble comes before the replay, so a
-- non-member cannot probe keys.
--
-- ONE CLIENT KEY, THREE IDEMPOTENT OBJECTS (TDD Seam 5):
--   * the batch of sales_lines is unique on (idempotency_key, seq), with seq = the array's
--     ordinality;
--   * each stock_ledger row takes a DERIVED key, md5(key || ':' || seq)::uuid, so the batch's
--     one key becomes one stable key per line and a replay re-derives the same ones. Passing
--     the batch key itself would post line 1 and silently return line 1's id for lines 2 to 5,
--     because fn_post_ledger is unique on the key alone. R2's replacement key is the precedent;
--   * the whole call gets R39's explicit pre-check, because the pair constraint alone admits a
--     replay that carries MORE lines. A matching payload returns the original ids and writes
--     nothing. A different payload raises SALES_IDEMPOTENCY_CONFLICT. The pre-check runs under
--     a transaction advisory lock on the key, so two sessions racing one key become one write
--     and one replay rather than one write and one unique_violation (PLAN-sales.md B16).
--
-- WHERE EACH LINE LANDS (PLAN-sales.md Finding 10, B12, B13):
--   * SMOKED_MEAT: SALE off (SMOKED_MEAT, product NULL, lot, group, branch, READY), in KG.
--     product_id is null because the thaw, TRANSFER_IN and OPENING all hold meat on a tuple
--     with no product. A product id here would find no READY stock at all. The kilograms are
--     qty x the avg_pack_weight_kg snapshot, and the snapshot is stored on the row (R29), so the
--     row and the ledger cannot disagree and v_branch_diff never reads config. R14: READY
--     only, never FROZEN.
--   * any other stock-tracked SKU (CHILLI_TUBE today): SALE off (item_type, product, no lot,
--     READY) in its own unit. That is the tuple fn_record_opening_balance lands chilli on.
--     Chilli is deducted here and only here (M6). The end-of-day count reports a variance and
--     writes nothing (R19).
--   * is_stock_tracked = false (RICE_KG, WATER_BOTTLE): the line is written and priced, and no
--     ledger row is posted. If F11 flips rice to tracked, it takes the branch above with no
--     change here.
--
-- PRICE FROM product_prices, resolved at the report's business date and snapshotted into
-- unit_price_thb (BR23, R29). The report's date, never current_date (ADR-014). No row means
-- CONFIG_NOT_SET naming the SKU (ADR-023). Nothing is defaulted.
--
-- avg_pack_weight_kg is resolved once per batch. CONFIG_NOT_SET propagates from
-- fn_config_numeric and names the key. The value must be > 0 with at most two decimals, or the
-- call raises PACK_WEIGHT_INVALID. The snapshot column is numeric(12,2), and silently storing
-- 0.21 while the ledger drew at 0.205 is how a row and its movement stop agreeing (B14).
--
-- INSUFFICIENT_STOCK FROM fn_post_ledger IS RE-RAISED AS INSUFFICIENT_READY_STOCK, naming the
-- lot, its smoke date and the shortfall (Finding 13). It is caught, never pre-checked: a
-- balance read outside fn_post_ledger's advisory lock is the race that lock exists to remove.
--
-- channel is the constant 'LINE_MAN', set here and not as a column default. D04 makes it a
-- constant TODAY, and a default would hide it on the day M13 turns it into a dimension.
--
-- NO AUDIT INSERT. ^ref-06's trigger covers sales_lines and stock_ledger in this transaction
-- (R32). created_by is the actor, never a parameter.
--
-- Covered by supabase/tests/sales_test.sql (TC-16 ... TC-31) and sales_concurrency_test.sh
-- (TC-53).

create or replace function public.fn_record_sales(
  p_idempotency_key uuid,
  p_daily_report_id uuid,
  p_lines           jsonb
) returns json
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_report      daily_reports;
  v_actor       uuid;
  v_ids         uuid[];
  v_stored      jsonb;
  v_sent        jsonb;
  v_same_report boolean;
  v_line        record;
  v_prod        products;
  v_meat        boolean;
  v_qty         numeric;
  v_price       numeric(12,2);
  v_pack_raw    numeric;
  v_pack        numeric(12,2);
  v_draw        numeric(12,2);
  v_lot         uuid;
  v_group       uuid;
  v_group_lot   uuid;
  v_line_id     uuid;
  v_balance     numeric;
  v_lot_code    text;
  v_smoke_date  date;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'SALES_LINES_REQUIRED: a sale is at least one line — p_lines is a non-empty array';
  end if;

  select * into v_report from daily_reports where id = p_daily_report_id;

  v_actor := fn_require_branch_or_owner(v_report.location_id);

  if v_report.id is null then
    raise exception 'REPORT_NOT_FOUND: no daily report %', p_daily_report_id;
  end if;

  ------------------------------------------------------------------ the replay (R4, R39)
  perform pg_advisory_xact_lock(hashtextextended('fn_record_sales|' || p_idempotency_key::text, 0));

  select jsonb_agg(jsonb_build_object('c', p.code, 'q', s.qty,
                                      'l', s.lot_id, 'g', s.smoke_date_group_id)
                   order by s.seq),
         array_agg(s.id order by s.seq),
         bool_and(s.daily_report_id = p_daily_report_id)
    into v_stored, v_ids, v_same_report
    from sales_lines s
    join products p on p.id = s.product_id
   where s.idempotency_key = p_idempotency_key;

  if v_ids is not null then
    -- The payload, normalised the way the write path stores it: qty to two decimals, and a
    -- lot or group on a non-meat line dropped, because the write path never stores one.
    select jsonb_agg(jsonb_build_object(
             'c', t.e ->> 'product_code',
             'q', case when jsonb_typeof(t.e -> 'qty') = 'number'
                       then (t.e ->> 'qty')::numeric(12,2) end,
             'l', case when p.item_type = 'SMOKED_MEAT'
                       then nullif(t.e ->> 'lot_id', '')::uuid end,
             'g', case when p.item_type = 'SMOKED_MEAT'
                       then nullif(t.e ->> 'smoke_date_group_id', '')::uuid end)
           order by t.i)
      into v_sent
      from jsonb_array_elements(p_lines) with ordinality t(e, i)
      left join products p on p.code = t.e ->> 'product_code';

    if not (v_same_report and v_sent = v_stored) then
      raise exception 'SALES_IDEMPOTENCY_CONFLICT: key % was used for a different batch of lines (R39)',
        p_idempotency_key;
    end if;
    -- A return, not a raise (R4). Nothing is written. The balances below are read now.
  else
    ------------------------------------------------------------------ the day (R8, R28)
    -- The trigger's predicate exactly (fn_guard_report_closed, ...0018), so the message and
    -- the backstop cannot disagree about an unlocked day (PLAN-sales.md B3).
    if v_report.status = 'CLOSED' and not exists (
         select 1 from unlock_requests u
          where u.target_type = 'DAILY_REPORT'
            and u.target_id   = v_report.id
            and u.status      = 'APPROVED'
            and u.expires_at  > now()) then
      raise exception 'REPORT_CLOSED: the day % is closed — no sale can be recorded against it without an approved unlock (R8/R42)',
        v_report.report_date;
    end if;

    -- R28 binds an OPEN day only. An UNLOCKED day, or a CLOSED one under an approved unlock,
    -- IS the escalation R28 points to (v0.2 D07, UAT-18: past three days the Owner unlocks).
    -- Asking the window again would refuse the very correction the unlock was granted for.
    -- Lane B's fn_record_thaw applies the same rule (PLAN-sales.md B21).
    if v_report.status = 'OPEN' and not fn_backdating_allowed(v_report.report_date) then
      raise exception 'BACKDATE_NOT_ALLOWED: % is outside the back-dating window (R28) — the unlock path reopens it',
        v_report.report_date;
    end if;

    v_ids := '{}'::uuid[];

    ------------------------------------------------------------------------ the lines
    for v_line in
      select t.e, t.i::integer as seq
        from jsonb_array_elements(p_lines) with ordinality t(e, i)
       order by t.i
    loop
      v_prod := null;
      select * into v_prod from products
       where code = v_line.e ->> 'product_code' and is_active;
      if v_prod.id is null then
        raise exception 'PRODUCT_UNKNOWN: line % names [%], which is not an active SKU',
          v_line.seq, coalesce(v_line.e ->> 'product_code', 'no product_code');
      end if;
      v_meat := v_prod.item_type = 'SMOKED_MEAT';

      if jsonb_typeof(v_line.e -> 'qty') is distinct from 'number' then
        raise exception 'SALES_QTY_INVALID: line % (%) carries no numeric qty', v_line.seq, v_prod.code;
      end if;
      v_qty := (v_line.e ->> 'qty')::numeric;
      if v_qty <= 0 or v_qty <> round(v_qty, 2) then
        raise exception 'SALES_QTY_INVALID: line % (%) qty is % — a quantity is > 0 to two decimals',
          v_line.seq, v_prod.code, v_qty;
      end if;
      -- BR21. fn_require_lot_for_meat is the backstop; this raise is the message.
      if v_prod.sale_unit <> 'kg' and v_qty <> trunc(v_qty) then
        raise exception 'QTY_NOT_WHOLE_UNITS: % % of % — packs, tubes and pieces are whole numbers (BR21)',
          v_qty, v_prod.sale_unit, v_prod.code;
      end if;

      -- The source (R21, D01, D05). Meat names its lot AND the smoke-date group the READY
      -- balance is held on. A group that belongs to another lot is refused by name here,
      -- rather than read as an empty tuple further down.
      v_lot := null;
      v_group := null;
      if v_meat then
        v_lot   := nullif(v_line.e ->> 'lot_id', '')::uuid;
        v_group := nullif(v_line.e ->> 'smoke_date_group_id', '')::uuid;
        if v_lot is null then
          raise exception 'LOT_REQUIRED: line % (%) is meat and names no lot (R21/D01)', v_line.seq, v_prod.code;
        end if;
        if v_group is null then
          raise exception 'SMOKE_GROUP_REQUIRED: line % (%) names no smoke-date group — the READY balance is held on one (R21)',
            v_line.seq, v_prod.code;
        end if;
        select lot_id into v_group_lot from smoke_date_groups where id = v_group;
        if v_group_lot is distinct from v_lot then
          raise exception 'LOT_REQUIRED: line % names smoke-date group %, which belongs to lot %, not % (R21)',
            v_line.seq, v_group, coalesce(v_group_lot::text, 'no lot'), v_lot;
        end if;
      end if;

      -- The price, as it was on the business date (BR23, R29).
      v_price := null;
      select price_thb into v_price
        from product_prices
       where product_id = v_prod.id and effective_from <= v_report.report_date
       order by effective_from desc
       limit 1;
      if v_price is null then
        raise exception 'CONFIG_NOT_SET: no price for % on or before % — the Owner enters it (ADR-023, BR23)',
          v_prod.code, v_report.report_date;
      end if;

      -- The pack weight, once per batch (BR04, R12, R29).
      if v_meat and v_pack is null then
        v_pack_raw := fn_config_numeric('avg_pack_weight_kg', v_report.report_date, v_report.location_id);
        if v_pack_raw <= 0 or v_pack_raw <> round(v_pack_raw, 2) then
          raise exception 'PACK_WEIGHT_INVALID: avg_pack_weight_kg resolved to % at % — a pack weight is > 0 kg to two decimals (BR04, BR21)',
            v_pack_raw, v_report.report_date;
        end if;
        v_pack := v_pack_raw;
      end if;

      insert into sales_lines (daily_report_id, product_id, lot_id, smoke_date_group_id, qty,
                               unit_price_thb, pack_weight_kg, channel, created_by,
                               idempotency_key, seq)
      values (v_report.id, v_prod.id, v_lot, v_group, v_qty,
              v_price, case when v_meat then v_pack end, 'LINE_MAN', v_actor,
              p_idempotency_key, v_line.seq)
      returning id into v_line_id;

      if v_prod.is_stock_tracked then
        v_draw := case when v_meat then round(v_qty * v_pack, 2) else v_qty end;
        begin
          perform fn_post_ledger(
            p_idempotency_key     => md5(p_idempotency_key::text || ':' || v_line.seq)::uuid,
            p_item_type           => v_prod.item_type,
            p_location_id         => v_report.location_id,
            p_stock_state         => 'READY',
            p_movement_type       => 'SALE',
            p_qty_delta           => -v_draw,
            p_business_date       => v_report.report_date,
            p_product_id          => case when v_meat then null else v_prod.id end,
            p_lot_id              => v_lot,
            p_smoke_date_group_id => v_group,
            p_source_table        => 'sales_lines',
            p_source_id           => v_line_id);
        exception when others then
          if sqlerrm not like 'INSUFFICIENT_STOCK:%' then
            raise;
          end if;
          -- The message only, read after the refusal. The refusal itself came from inside
          -- the lock.
          select coalesce(sum(qty_delta), 0) into v_balance
            from stock_ledger
           where item_type   = v_prod.item_type
             and location_id = v_report.location_id
             and stock_state = 'READY'
             and product_id          is not distinct from (case when v_meat then null else v_prod.id end)
             and lot_id              is not distinct from v_lot
             and smoke_date_group_id is not distinct from v_group;
          if v_meat then
            select l.lot_code, g.smoke_date into v_lot_code, v_smoke_date
              from smoke_date_groups g join lots l on l.id = g.lot_id
             where g.id = v_group;
            raise exception 'INSUFFICIENT_READY_STOCK: lot % smoked % has % kg ready at this branch; line % (% x % kg = % kg) is % kg short — thaw first or check the count (R14, R3)',
              v_lot_code, v_smoke_date, v_balance, v_line.seq, v_qty, v_pack, v_draw, v_draw - v_balance;
          end if;
          raise exception 'INSUFFICIENT_READY_STOCK: % has % % ready at this branch; line % asks for % and is % short (R3)',
            v_prod.code, v_balance, v_prod.sale_unit, v_line.seq, v_draw, v_draw - v_balance;
        end;
      end if;

      v_ids := array_append(v_ids, v_line_id);
    end loop;
  end if;

  return json_build_object(
    'sales_line_ids', to_json(v_ids),
    -- The branch's whole READY meat balance, across lots, after this batch.
    'ready_remaining_kg', (select coalesce(sum(qty_delta), 0)
                             from stock_ledger
                            where item_type   = 'SMOKED_MEAT'
                              and location_id = v_report.location_id
                              and stock_state = 'READY'),
    'chilli_paste_remaining_tubes', (select coalesce(sum(qty_delta), 0)
                                       from stock_ledger
                                      where item_type   = 'CHILLI_PASTE'
                                        and location_id = v_report.location_id
                                        and stock_state = 'READY'));
end $$;

revoke execute on function public.fn_record_sales(uuid, uuid, jsonb) from public, anon, authenticated;
grant  execute on function public.fn_record_sales(uuid, uuid, jsonb) to authenticated;
