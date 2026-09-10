-- Card ^ref-62, T5 — fn_record_opening_balance. The only path in the system that creates
-- stock with no purchase order behind it, and the only one with nothing to check itself
-- against.
--
-- Every other write has an expectation: a PO to over-deliver against, a dispatch weight to
-- receive against, a balance to draw from. An opening row IS the expectation. So the only
-- guards available are structural ones, and each of the ones below is a way a number becomes
-- permanently wrong on day one.
--
-- THERE IS NO COST PARAMETER, OF ANY NAME OR TYPE (BR15, TC-09). The chef house counter is
-- an L3_CM_OPERATOR — ADR-021 names ผู้จัดการเชียงใหม่ — and R20 says an L3 session reads no
-- price. A price that cannot be PASSED cannot be leaked by a screen that passes it, and the
-- enforcement is then inspectable in one line of the signature rather than in a branch
-- inside the body. fn_set_opening_cost is the L1 step, and it is a different function for
-- exactly this reason: "who may enter a price" is answered by which function you may call.
-- Same reasoning as fn_add_po_delivery's missing actor parameter.
--
-- L1 IS NOT A SUPERSET HERE, AND THIS IS THE ONE PLACE IN THE SYSTEM WHERE THAT IS TRUE.
-- Everywhere else the Owner reads every branch, writes every location and decides every
-- unlock. ADR-021 assigns a counter per location — L2 their branch, L3 the chef house, L1
-- CENTRAL — and says nobody counts outside their own scope. THIS WILL LOOK LIKE A BUG TO
-- WHOEVER READS IT NEXT AND IT IS NOT ONE: a count is a physical act, and an Owner in
-- Bangkok counting a Chiang Mai freezer is a figure with nobody behind it. TC-11 is the test
-- that stops it being "fixed".
--
-- THE STOCK STATE IS DERIVED, NOT A PARAMETER (TDD Open Question 1, settled here).
-- Smoked meat lands FROZEN: R14 moves weight FROZEN -> READY at the branch and a sale
-- deducts READY only, so opening stock that landed in READY would leave THAW_OUT with
-- nothing to draw from — the same reasoning fn_confirm_transport_receipt writes down. It is
-- also what R13/BR19 already imply: ready meat must be zero before a day can close, and an
-- opening position is a day boundary by construction. Everything else lands READY; there is
-- no thaw step for chilli paste, rice or packaging, and FROZEN would invent one.
--
-- A LOT AND A SMOKE DATE ARE REQUIRED FOR MEAT, AND THE FAILURE IS SILENT (R21, R46,
-- ADR-017). Without them the FIFO picker sorts the lot as the newest thing in stock and the
-- oldest meat never leaves. Nothing is wrong on day one. Three months later there is
-- year-old smoked meat at the back of a freezer and the picker has been correct about it the
-- entire time. fn_post_ledger already refuses meat with no lot; the smoke date has no guard
-- anywhere else, so it gets one here.
--
-- Covered by supabase/tests/opening_balance_test.sql and opening_schema_test.sql.

create or replace function public.fn_record_opening_balance(
  p_idempotency_key   uuid,
  p_item_type         item_type,
  p_location_id       uuid,
  p_qty               numeric,
  p_business_date     date,
  p_lot_id            uuid default null,
  p_smoke_date        date default null,
  p_lot_code          text default null,
  p_product_id        uuid default null,
  p_packaging_item_id uuid default null,
  p_note              text default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor  uuid;
  v_role   user_role;
  v_kind   location_kind;
  v_cutoff date;
  v_lot    uuid := p_lot_id;
  v_group  uuid;
  v_state  stock_state;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- Actor before role, the house order (fn_require_owner, fn_require_branch): a deactivated
  -- counter holding a live token is NO_ACTOR, not FORBIDDEN. Both are refusals; only one
  -- tells whoever reads the log which state they are actually in.
  select id into v_actor from profiles where id = auth.uid() and is_active;
  if v_actor is null then
    raise exception 'NO_ACTOR: the caller has no active profile (R31)';
  end if;
  v_role := fn_current_role();

  -- The window, before anything else is validated. A caller past the close should be told
  -- that and not which of their arguments is also wrong.
  if exists (select 1 from opening_balance_close) then
    raise exception
      'OPENING_CLOSED: opening balances were closed at %; no OPENING row is accepted again (ADR-021/R46)',
      (select closed_at from opening_balance_close);
  end if;

  if p_qty is null or p_qty <= 0 then
    raise exception 'OPENING_QTY_INVALID: an opening count is a positive quantity, not % (R46)', p_qty;
  end if;

  if p_business_date is null then
    raise exception 'BUSINESS_DATE_REQUIRED: an opening row is counted as of a date (ADR-007)';
  end if;

  -- ADR-023: CONFIG_NOT_SET propagates and THE RAISE IS THE FEATURE. A defaulted cut-off
  -- accepts every date, which is the same as having no cut-off while looking like having
  -- one. `opening_cutoff_date` is a BLOCK row in v_config_readiness until the Owner sets it.
  v_cutoff := fn_config_date('opening_cutoff_date', p_business_date);
  if p_business_date > v_cutoff then
    raise exception 'OPENING_AFTER_CUTOFF: % is after the opening cut-off % (R46/ADR-021)',
      p_business_date, v_cutoff;
  end if;

  ------------------------------------------------------------------------------- the scope
  select kind into v_kind from locations where id = p_location_id;
  if v_kind is null then
    raise exception 'LOCATION_NOT_FOUND: no location %', p_location_id;
  end if;

  if v_role = 'L2_BRANCH_ADMIN' then
    -- Role, membership and actor in one preamble. The kind check is on top of it because
    -- fn_require_branch asks whether the caller is assigned to the location, not what kind
    -- of place it is, and an L2 assigned to CENTRAL would otherwise count it.
    perform fn_require_branch(p_location_id);
    if v_kind <> 'BRANCH' then
      raise exception 'FORBIDDEN: an L2 branch admin counts their own branch, not a % (ADR-021)', v_kind;
    end if;

  elsif v_role = 'L3_CM_OPERATOR' then
    if v_kind <> 'CHEF_HOUSE' then
      raise exception 'FORBIDDEN: an L3 operator counts the chef house, not a % (ADR-021)', v_kind;
    end if;
    if p_location_id <> all (fn_current_locations()) then
      raise exception 'FORBIDDEN_LOCATION: the caller is not assigned to location %', p_location_id;
    end if;

  elsif v_role = 'L1_OWNER' then
    if v_kind <> 'CENTRAL' then
      raise exception
        'FORBIDDEN: the Owner counts CENTRAL and nothing else; a % has its own counter (ADR-021)',
        v_kind;
    end if;

  else
    raise exception 'FORBIDDEN: no role may record an opening balance (ADR-004)';
  end if;

  ------------------------------------------------------------------------- what is counted
  if p_item_type = 'SMOKED_MEAT' then
    if v_lot is null and p_lot_code is null then
      raise exception
        'OPENING_LOT_REQUIRED: smoked meat names its lot, or a lot code to create one (R21/ADR-017)';
    end if;
    if p_smoke_date is null then
      raise exception
        'OPENING_SMOKE_DATE_REQUIRED: an opening lot with no smoke date sorts as the newest stock and the oldest meat never leaves (R46)';
    end if;

    if v_lot is null then
      -- LOT_CLOSED, not the PO_CREATED default: this lot's production finished before the
      -- software existed. It has no dispatch round, no dispatch weight and no recorded chef
      -- house (migration ...0012's lots_round_or_opening), so there is no smoke log it could
      -- ever accept and no yield it could ever be evaluated for.
      insert into lots (lot_code, is_opening, state, event_date)
        values (p_lot_code, true, 'LOT_CLOSED', p_smoke_date)
        returning id into v_lot;
    end if;

    -- R7 is the natural key. `on conflict do nothing` then re-select rather than
    -- `do update`: two opening rows for the same lot and smoke date are ordinary — 40 kg
    -- counted in one freezer and 15 kg in another — and the group is shared, not rewritten.
    insert into smoke_date_groups (lot_id, smoke_date) values (v_lot, p_smoke_date)
      on conflict (lot_id, smoke_date) do nothing
      returning id into v_group;
    if v_group is null then
      select id into v_group from smoke_date_groups
       where lot_id = v_lot and smoke_date = p_smoke_date;
    end if;

    v_state := 'FROZEN';

  else
    -- TDD Open Question 2, settled: v_stock_balance groups by product_id AND
    -- packaging_item_id, so a row carrying neither is a balance nothing can find and nobody
    -- can correct — it is stock that exists only as a sum over a grouping no screen asks for.
    if p_item_type = 'PACKAGING' then
      if p_packaging_item_id is null then
        raise exception 'OPENING_PACKAGING_ITEM_REQUIRED: a packaging count names its item (R46)';
      end if;
    elsif p_product_id is null then
      raise exception 'OPENING_PRODUCT_REQUIRED: a % count names its product (R46)', p_item_type;
    end if;

    v_state := 'READY';
  end if;

  ------------------------------------------------------------------------------ the ledger
  -- The caller's own key, straight through, so a retry from a dropped connection returns the
  -- committed id and writes nothing twice (R4, ADR-005). fn_post_ledger writes no audit row
  -- and neither does this function: ^ref-06's generic trigger fires on the insert inside the
  -- same transaction, and a second one here would audit every opening count twice (R32).
  return fn_post_ledger(
    p_idempotency_key     => p_idempotency_key,
    p_item_type           => p_item_type,
    p_location_id         => p_location_id,
    p_stock_state         => v_state,
    p_movement_type       => 'OPENING',
    p_qty_delta           => p_qty,
    p_business_date       => p_business_date,
    p_product_id          => p_product_id,
    p_packaging_item_id   => p_packaging_item_id,
    p_lot_id              => v_lot,
    p_smoke_date_group_id => v_group,
    -- No source_table/source_id. Every other fn_record_* points the ledger row at the
    -- transaction record behind it; an opening count has none, which is the whole shape of
    -- ADR-021. Naming a table here that does not hold the row would be worse than null.
    p_reason              => p_note);
end $$;

revoke execute on function public.fn_record_opening_balance(
  uuid, item_type, uuid, numeric, date, uuid, date, text, uuid, uuid, text)
  from public, anon, authenticated;
grant  execute on function public.fn_record_opening_balance(
  uuid, item_type, uuid, numeric, date, uuid, date, text, uuid, uuid, text)
  to authenticated;
