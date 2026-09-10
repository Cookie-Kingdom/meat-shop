-- Card ^ref-49 — fn_record_physical_count. BR 08's end-of-day count: the 7 materials, chilli
-- paste and smoked meat, one batch per screen (PLAN-materials.md T3, Findings 3, 4, 6, 12;
-- TDD Seam 3).
--
-- A COUNT NEVER WRITES stock_ledger (R19, the card's acceptance). It stores what was counted
-- beside what the ledger said at that moment, and variance_qty (a generated column) is the
-- difference. That variance is a REPORTED number. Closing it is a separate, deliberate L1 act,
-- fn_accept_count_variance, which goes through fn_reverse_ledger_entry. M6's worked case: receive
-- 100, sell 12, the system says 88; the shelf has 87. The count reports -1 and moves nothing. A
-- count that also deducted would leave 87 in the system, 87 on the shelf, and a tube nobody can
-- account for.
--
-- ONE CALL IS ONE BATCH (R39), the lot_bags / sales_lines shape. The key is per batch and seq is
-- the element's position, minted here. Two mechanisms, as in lane C's fn_record_sales:
--
--   1. Any row on this key → return the original batch, write nothing. The key wins, even over
--      a payload that disagrees (R4). This also closes lot_bags' remaining hole: a replay
--      carrying MORE elements would otherwise insert the extras without conflicting.
--   2. A concurrent replay cannot see the first batch's uncommitted rows, so it passes step 1.
--      Its first insert then blocks on physical_counts_batch_key and fails with unique_violation
--      once the first batch commits. That failure is caught, and the committed batch is
--      returned (TC-32 in materials_concurrency_test.sh).
--
-- THE WHOLE ARRAY IS VALIDATED BEFORE ANY ROW IS WRITTEN, the fn_upsert_smoke_daily_log shape.
-- One transaction would roll a failure back anyway. The pre-pass makes the refusal a named
-- exception about element N rather than a constraint name about whichever row hit it (TC-44).
--
-- WHAT IS COUNTED, AND AGAINST WHAT (PLAN Finding 6):
--   PACKAGING     an active packaging_items row; system = the ledger for that item here
--   CHILLI_PASTE  whole tubes; system = every chilli row here, whatever product_id lane C's
--                 fn_record_sales posts it under
--   SMOKED_MEAT   a smoke_date_group, which names the lot (ADR-017); system = that group here
-- IN_TRANSIT is excluded from every system figure: meat on a truck to this branch is not on its
-- shelf. Rice is NOT counted here (COUNT_ITEM_INVALID): its balance is rice_records, and
-- fn_record_rice is its only writer.
--
-- system_qty IS A SNAPSHOT WITH NO LOCK. It is a reported figure, not a balance check, so a
-- sale landing a millisecond later makes the variance a millisecond stale rather than wrong
-- stock. fn_post_ledger's advisory lock is for draws; nothing here draws.
--
-- A RECOUNT APPENDS (v0.2:253, "เก็บการตรวจนับและส่วนต่าง ไม่เขียนทับประวัติ"). A second batch
-- for the same report under a new key is a second set of rows. v_material_alerts reads the
-- latest one.
--
-- L2 ONLY, fn_require_branch (v0.2:58, PLAN Finding 3). No CLOSED check here: lane C's
-- fn_guard_report_closed (...0018) raises REPORT_CLOSED on the insert. R28's window IS checked,
-- after the replay (Finding 12).
--
-- Covered by supabase/tests/materials_count_test.sql (TC-33 ... TC-50, TC-60 ... TC-62) and
-- supabase/tests/materials_concurrency_test.sh (TC-32).

create or replace function public.fn_record_physical_count(
  p_idempotency_key uuid,
  p_daily_report_id uuid,
  p_counts          jsonb
) returns json
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor   uuid;
  v_report  daily_reports;
  v_el      jsonb;
  v_seq     bigint;
  v_type    text;
  v_qty     numeric;
  v_pack    uuid;
  v_group   uuid;
  v_tag     text;
  v_seen    text[]    := '{}';
  v_types   text[]    := '{}';
  v_qtys    numeric[] := '{}';
  v_packs   uuid[]    := '{}';
  v_groups  uuid[]    := '{}';
  v_reasons text[]    := '{}';
  v_system  numeric;
  i         integer;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  select * into v_report from daily_reports where id = p_daily_report_id;
  if not found then
    raise exception 'REPORT_NOT_FOUND: no daily report % — open the day first (BR 01)', p_daily_report_id;
  end if;

  v_actor := fn_require_branch(v_report.location_id);

  if not exists (select 1 from physical_counts where idempotency_key = p_idempotency_key) then
    ------------------------------------------------------------------ the window (R28)
    if not fn_backdating_allowed(v_report.report_date) then
      raise exception 'BACKDATE_NOT_ALLOWED: % is outside the back-dating window — a count that old goes through the unlock path (R28)',
        v_report.report_date;
    end if;

    if p_counts is null or jsonb_typeof(p_counts) <> 'array' then
      raise exception 'COUNTS_REQUIRED: p_counts must be an array of counts, got %',
        coalesce(jsonb_typeof(p_counts), 'null');
    end if;
    if jsonb_array_length(p_counts) = 0 then
      raise exception 'COUNTS_REQUIRED: an empty batch counts nothing (BR 08)';
    end if;

    ---------------------------------------------------------- validate the whole array
    for v_el, v_seq in
      select e.value, e.ordinality from jsonb_array_elements(p_counts) with ordinality as e(value, ordinality)
    loop
      v_type := v_el ->> 'item_type';
      if v_type is null or v_type not in ('PACKAGING', 'CHILLI_PASTE', 'SMOKED_MEAT') then
        raise exception 'COUNT_ITEM_INVALID: count % is [%] — this count takes PACKAGING, CHILLI_PASTE and SMOKED_MEAT; rice is recorded by fn_record_rice (M7)',
          v_seq, coalesce(v_type, 'null');
      end if;

      -- Not a number is the same refusal as no number, and it is reported by name below.
      begin
        v_qty := (v_el ->> 'counted_qty')::numeric;
      exception when others then
        v_qty := null;
      end;
      if v_qty is null or v_qty < 0 then
        raise exception 'COUNT_QTY_INVALID: count % has counted_qty [%] — a count is a number >= 0',
          v_seq, coalesce(v_el ->> 'counted_qty', 'null');
      end if;

      -- BR21. The physical_counts_whole_units CHECK is the backstop; this is the message.
      if v_type in ('CHILLI_PASTE', 'PACKAGING') and v_qty <> trunc(v_qty) then
        raise exception 'QTY_NOT_WHOLE_UNITS: count % is % — % is counted in whole units (BR21)',
          v_seq, v_qty, v_type;
      end if;

      begin
        v_pack  := (v_el ->> 'packaging_item_id')::uuid;
        v_group := (v_el ->> 'smoke_date_group_id')::uuid;
      exception when invalid_text_representation then
        raise exception 'COUNT_ITEM_INVALID: count % names an id that is not a uuid: %', v_seq, v_el;
      end;

      -- An id that does not belong to the item type is dropped, not stored: a chilli row
      -- carrying a smoke group would sit on a tuple no balance is held on.
      if v_type = 'PACKAGING' then
        v_group := null;
        if v_pack is null then
          raise exception 'PACKAGING_ITEM_REQUIRED: count % is PACKAGING and names no packaging_item_id (M8)', v_seq;
        end if;
        if not exists (select 1 from packaging_items where id = v_pack and is_active) then
          raise exception 'PACKAGING_ITEM_NOT_FOUND: count % names %, which is not an active packaging item',
            v_seq, v_pack;
        end if;
        v_tag := 'PACKAGING:' || v_pack;

      elsif v_type = 'SMOKED_MEAT' then
        v_pack := null;
        if v_group is null then
          raise exception 'SMOKE_GROUP_REQUIRED: count % is SMOKED_MEAT and names no smoke_date_group_id — meat is held per smoke date and lot (ADR-017)',
            v_seq;
        end if;
        if not exists (select 1 from smoke_date_groups where id = v_group) then
          raise exception 'SMOKE_GROUP_NOT_FOUND: count % names smoke date group %, which does not exist', v_seq, v_group;
        end if;
        v_tag := 'SMOKED_MEAT:' || v_group;

      else
        v_pack  := null;
        v_group := null;
        v_tag   := 'CHILLI_PASTE';
      end if;

      if v_tag = any (v_seen) then
        raise exception 'COUNT_ITEM_DUPLICATED: count % repeats %, already counted in this batch — one row per item',
          v_seq, v_tag;
      end if;
      v_seen := v_seen || v_tag;

      v_types   := array_append(v_types,   v_type);
      v_qtys    := array_append(v_qtys,    v_qty);
      v_packs   := array_append(v_packs,   v_pack);
      v_groups  := array_append(v_groups,  v_group);
      v_reasons := array_append(v_reasons, nullif(btrim(v_el ->> 'reason'), ''));
    end loop;

    ------------------------------------------------------------------ write the batch
    begin
      for i in 1 .. array_length(v_types, 1) loop
        -- The ledger's figure for this tuple, now. Never written back (R19).
        select coalesce(sum(l.qty_delta), 0) into v_system
          from stock_ledger l
         where l.location_id  = v_report.location_id
           and l.item_type    = v_types[i]::item_type
           and l.stock_state <> 'IN_TRANSIT'
           and (v_types[i] <> 'PACKAGING'   or l.packaging_item_id   = v_packs[i])
           and (v_types[i] <> 'SMOKED_MEAT' or l.smoke_date_group_id = v_groups[i]);

        insert into physical_counts (daily_report_id, location_id, event_date, item_type,
                                     packaging_item_id, smoke_date_group_id, counted_qty,
                                     system_qty, reason, created_by, idempotency_key, seq)
             values (v_report.id, v_report.location_id, v_report.report_date,
                     v_types[i]::item_type, v_packs[i], v_groups[i], v_qtys[i],
                     v_system, v_reasons[i], v_actor, p_idempotency_key, i);
      end loop;
    exception
      -- physical_counts_batch_key, and only it: the table has no other unique constraint. A
      -- concurrent call on this key committed first. This batch's rows rolled back to the
      -- block's savepoint, and the committed batch is what gets returned below (R4).
      when unique_violation then
        null;
    end;
  end if;

  -- One exit for the first call, the replay and the concurrent replay: the batch as stored.
  return (
    select json_build_object(
             'physical_count_ids', json_agg(pc.id order by pc.seq),
             'counts', json_agg(json_build_object(
                 'physical_count_id',   pc.id,
                 'item_type',           pc.item_type,
                 'packaging_item_id',   pc.packaging_item_id,
                 'smoke_date_group_id', pc.smoke_date_group_id,
                 'counted_qty',         pc.counted_qty,
                 'system_qty',          pc.system_qty,
                 'variance_qty',        pc.variance_qty) order by pc.seq))
      from physical_counts pc
     where pc.idempotency_key = p_idempotency_key);
end $$;

revoke execute on function public.fn_record_physical_count(uuid, uuid, jsonb) from public, anon, authenticated;
grant  execute on function public.fn_record_physical_count(uuid, uuid, jsonb) to authenticated;
