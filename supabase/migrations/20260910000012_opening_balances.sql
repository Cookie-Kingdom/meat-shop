-- Card ^ref-62, T2 — the opening-balance schema: the lot that has no purchase order, the
-- one-way close switch, the cost that cannot live on the ledger row, and the trigger that
-- makes "never again" an invariant instead of a promise.
--
-- Reads with ADR-021 (closed 9 Sep 2026), ADR-003 (append-only), D01 (one round, one lot)
-- and R46 (the OPENING row rule — renumbered from the duplicate R36, see PLAN Finding 4;
-- R42 ... R45 were taken by ^ref-21 ... ^ref-23 after that plan was written).

-------------------------------------------------------------------- 1. the opening lot
-- PLAN Finding 7 said one column blocked an opening lot. FOUR do. `lots` requires po_id,
-- po_delivery_id, foodiva_sent_weight_kg and chef_house_location_id, and an opening lot has
-- none of them: it is meat already in a freezer on day one, smoked before the software
-- existed, with a smoke date and no paper behind it.
--
-- Each column is dropped for its own reason, not as a batch:
--
--   po_id / po_delivery_id  — the purchase orders were on paper too (ADR-021).
--   foodiva_sent_weight_kg  — R16a makes this THE loss base and ADR-011's divisor. An
--                             opening lot has no dispatch weight, so its yield is undefined.
--                             Null says that. A zero would make F7's loss read 100.00% and
--                             a copied received weight would make it read 0.00%; both are
--                             figures with nobody behind them, which is the failure ADR-011
--                             exists to stop.
--   chef_house_location_id  — naming a chef house for a pre-system lot asserts a production
--                             fact nobody recorded.
--
-- D01 IS UNTOUCHED. It says a dispatch round has exactly one lot, and `po_delivery_id` stays
-- UNIQUE. It never said a lot must have a round — that was the NOT NULL doing more than D01
-- asked.
--
-- The check is a BICONDITIONAL, not the disjunction the plan drafted. `po_delivery_id is not
-- null or is_opening` would also permit an opening lot carrying a phantom PO, which is the
-- synthetic-round design the plan rejected — reachable again through the back door. Either a
-- lot has its whole purchasing history or it has none of it.
alter table lots add column is_opening boolean not null default false;

alter table lots alter column po_id                  drop not null;
alter table lots alter column po_delivery_id         drop not null;
alter table lots alter column foodiva_sent_weight_kg drop not null;
alter table lots alter column chef_house_location_id drop not null;

alter table lots add constraint lots_round_or_opening check (
  case when is_opening
    then po_id                  is null
     and po_delivery_id         is null
     and foodiva_sent_weight_kg is null
     and chef_house_location_id is null
    else po_id                  is not null
     and po_delivery_id         is not null
     and foodiva_sent_weight_kg is not null
     and chef_house_location_id is not null
  end
);

comment on column lots.is_opening is
  'ADR-021: this lot was counted into the system at go-live and has no purchase order, no '
  'dispatch round, no dispatch weight and no recorded chef house. Its production happened '
  'before the software existed, so it is created in LOT_CLOSED and never accepts a smoke log.';

--------------------------------------------------------------- 2. the one-way close switch
-- NOT A CONFIG KEY, and that is the decision this table exists to make un-undoable
-- (PLAN Finding 3). `config_settings` resolution is `effective_from <= event_date ... limit
-- 1` — dated by construction. A permanent switch stored in a dated table is reopenable by
-- writing a row with a later effective_from, and `fn_set_config` would do it without
-- noticing. `v_config_readiness` already hints at this: its row for the opening window names
-- the FUNCTION as the source where every other row names config_settings.
--
-- `id boolean primary key check (id)` is the single-row idiom: `true` is the only value the
-- check permits and the primary key makes it unique, so a second close is a key violation
-- rather than a business rule somebody has to remember to write. The window is OPEN when the
-- table is empty and CLOSED when it holds its row. There is no is_open column to fall out of
-- step with reality, and nothing in this repo deletes from it.
--
-- closed_idempotency_key is not decoration. Without it R4 and TC-29 pull in opposite
-- directions: a genuine retry from a dropped connection and a deliberate second close are
-- the same statement, and the key is the only thing that tells them apart. Same key returns
-- the original closed_at (R4); a different key raises OPENING_ALREADY_CLOSED (TC-29).
create table opening_balance_close (
  id                     boolean primary key default true check (id),
  closed_at              timestamptz not null default now(),
  closed_by              uuid not null references profiles(id),
  closed_idempotency_key uuid not null unique
);

comment on table opening_balance_close is
  'ADR-021: empty means opening balances are still unlocked. One row, written once by '
  'fn_close_opening_balances, means no OPENING ledger row is accepted again by anyone, ever, '
  'and R28''s back-dating window re-arms. There is no reopen path and there must not be one.';

------------------------------------------------------------ 3. the cost, off the ledger row
-- R46 wants a cost per kg on every opening row and BR15 forbids the counter seeing a price,
-- so the quantity and the cost are entered by different people at different times. That is
-- an UPDATE, and `trg_stock_ledger_append_only` refuses every UPDATE on stock_ledger at the
-- statement level.
--
-- The plan first proposed `cost_thb_per_kg` on stock_ledger and then withdrew it, correctly:
-- relaxing R1's trigger for one column while a window is open is a hole in ADR-003 that
-- stays open exactly as long as somebody remembers to close it. A column you cannot write
-- twice is not where a two-step figure belongs.
--
-- So the cost gets its own table keyed on the ledger row. fn_close_opening_balances checks
-- for a MISSING ROW rather than a null column — the same completeness check by a left join,
-- with the ledger untouched. The primary key on ledger_id is also what makes
-- fn_set_opening_cost idempotent without a key column (R38's precedent: where a natural
-- unique key carries the retry, no key column is added).
create table opening_costs (
  ledger_id       uuid primary key references stock_ledger(id),
  cost_thb_per_kg numeric(12,2) not null check (cost_thb_per_kg >= 0),
  set_by          uuid not null references profiles(id),
  set_at          timestamptz not null default now()
);

comment on table opening_costs is
  'ADR-003/BR15: the Owner''s cost for an OPENING ledger row. A separate table because '
  'stock_ledger refuses UPDATE, and a separate write function because BR15 keeps the price '
  'away from whoever counted the meat.';

------------------------------------------------------- 4. the close, as a ledger invariant
-- DELIBERATE DUPLICATION, AND THE ONLY DUPLICATION ON THIS CARD (TDD Seam 2).
-- fn_record_opening_balance also refuses when the window is shut. The function is what gives
-- a screen a legible OPENING_CLOSED with a Thai message attached to it; this trigger is what
-- makes ADR-021's "by anyone, ever" true. "Ever" includes the fifth write function somebody
-- adds in 2027 that calls fn_post_ledger directly and never heard of this card.
--
-- BEFORE INSERT FOR EACH ROW, not a statement trigger: it has to read new.movement_type.
-- The append-only guard next door is `for each statement` because it refuses unconditionally
-- and never looks at a row.
--
-- The subquery runs only for OPENING rows, so the ordinary ledger path — every sale, thaw,
-- transfer and waste in the system — pays one enum comparison and no query at all.
create function fn_stock_ledger_opening_closed() returns trigger language plpgsql as $$
begin
  if new.movement_type = 'OPENING' and exists (select 1 from opening_balance_close) then
    raise exception
      'OPENING_CLOSED: opening balances were closed at %; no OPENING row is accepted again (ADR-021/R46)',
      (select closed_at from opening_balance_close);
  end if;
  return new;
end $$;

create trigger trg_stock_ledger_opening_closed
  before insert on stock_ledger
  for each row execute function fn_stock_ledger_opening_closed();

-- A trigger function fires as the table owner, so EXECUTE buys it nothing and no session
-- role should hold one. `functions/000_revoke_defaults.sql` sweeps the schema and runs after
-- every migration, so this one is covered by it — the same route the three trigger functions
-- in ...0003 and ...0004 take. Sweep 1e of rls_deny_all_test.sql is what proves it.
