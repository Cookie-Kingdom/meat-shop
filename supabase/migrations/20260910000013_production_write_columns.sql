-- Card ^ref-25 — the one thing F6's tables cannot do without a migration.
--
-- lot_receipts, smoke_daily_logs, smoke_daily_log_sources, smoke_date_groups and lot_bags
-- were all created in ...0003_purchasing_production.sql, with R6's unique on
-- (lot_id, event_date), R7's on (lot_id, smoke_date), smoke_daily_log_sources.lot_id for D05
-- and the R6a roll-up trigger. The card's acceptance line is already true of that file, so
-- this is the sixth stale-in-Backlog card of the shape ^ref-04, ^ref-10, ^ref-13, ^ref-18
-- and ^ref-21 all had, and what it actually owes is the five things PLAN-lots.md's Findings
-- 2, 3, 4, 6 and 7 found missing.
--
-- One correction to the card's own wording while it is being amended: A SMOKE-DATE GROUP
-- DOES NOT HOLD SEVERAL LOTS. smoke_date_groups is unique (lot_id, smoke_date) — one group
-- row per lot per smoke date. What D05 says, and what this schema implements, is that one
-- smoke DATE carries several lots, as several group rows, and the FIFO picker sorts by smoke
-- date and then offers the lots inside it (R21). The many-to-many the card's wording suggests
-- would make a picked quantity stop naming its source lot, which is what ADR-017 and D01
-- exist to forbid.

------------------------------------------------------------------------- 1. the two retries
-- R39/ADR-005. Neither table can carry a retry on a natural key, and they fail differently.
--
-- smoke_daily_logs (Finding 3). "Idempotent on (lot_id, event_date)" and R4 are two rules,
-- not one, and this table needs both. A second write against the same (lot_id, event_date) is
-- NORMAL, not a retry: the operator enters the input weight and the brine in the morning and
-- comes back at 18:00 for the output weight. R5's trick — the natural key IS the payload, so
-- no column is needed — does not transfer, because here the natural key is two columns out of
-- nine. So the key column is what separates a correction from a dropped connection: a genuine
-- correction arrives on a fresh key and updates; a replay arrives on the same key and does
-- not. The column therefore holds the key of the MOST RECENT write, which is what makes the
-- unique index safe across corrections rather than in spite of them.
--
-- lot_bags (Finding 2). R39 names this failure by name: seq is derived by the writer as
-- max(seq) + 1, so a replay computes fresh seqs, the (smoke_date_group_id, seq) index never
-- fires, and 60 bags become 120. The roll-up in section 3 then doubles the group's
-- packed_weight_kg behind it — and that is the numerator of every yield figure in F7.
--
-- The key is per BATCH, not per bag: one call is one batch, so the unique is on the PAIR.
-- A key alone would refuse the second bag of a 60-bag save; riding a payload key instead
-- would refuse two genuine 0.52 kg bags in the same batch, which is an ordinary afternoon.
-- Uniqueness alone still does not close the hole — a replay carrying MORE bags than the first
-- call inserts the extra ones without conflicting — so fn_record_lot_bags (^ref-28) also does
-- R39's explicit pre-check: look the key up first, return the original count if the payload
-- matches, raise LOT_BAGS_IDEMPOTENCY_CONFLICT if it does not.
--
-- Nullable, because these are column adds on tables with no rows to backfill. Both functions
-- reject a null key by name before they write anything, the precedent ...0008 and ...0010 set;
-- NOT NULL would only turn a named exception into a constraint name.
alter table smoke_daily_logs add column idempotency_key uuid;
alter table lot_bags         add column idempotency_key uuid;

create unique index smoke_daily_logs_idempotency_key
  on smoke_daily_logs (idempotency_key);

alter table lot_bags add constraint lot_bags_batch_key
  unique (idempotency_key, seq);

-- lot_receipts needs no column and that is not an oversight. lot_id is already UNIQUE and the
-- lot id is in the payload, so the natural key carries the retry — R38's mechanism, the one
-- fn_open_daily_report uses under R5. Said here because the next reader will otherwise add a
-- column for symmetry with the two above.
comment on table lot_receipts is
  'One receipt per lot. lot_id UNIQUE is the retry key (R38/R5) — deliberately no '
  'idempotency_key column, unlike smoke_daily_logs and lot_bags, whose natural keys cannot '
  'carry one (R39).';

--------------------------------------------------------------------- 2. the post-drain bound
-- Finding 6. ^ref-26's acceptance and CM 03 both say post-drain may not exceed received, and
-- ...0003 has check (post_drain_weight_kg >= 0) and nothing more. Draining removes brine and
-- water; it cannot add meat, so a post-drain above the received weight is a typo that would
-- otherwise become the cross-check figure the whole receipt exists to provide.
--
-- BELT AND BRACES, NOT DUPLICATION: fn_record_lot_receipt raises POST_DRAIN_EXCEEDS_RECEIVED
-- as well. They fail at different layers and only one of them is a message. The constraint is
-- what survives a writer added in 2027; the raise is what CM 03 can render in Thai, because a
-- check_violation arrives as a constraint name and not as anything anyone can translate.
--
-- post_drain_weight_kg stays NULLABLE. CM 02 and CM 03 are two screens on two different
-- afternoons and the receipt row exists after the first one, so the check reads "null or".
alter table lot_receipts add constraint lot_receipts_post_drain_le_received
  check (post_drain_weight_kg is null
         or post_drain_weight_kg <= received_weight_kg);

---------------------------------------------------------------------- 3. the group's roll-up
-- Finding 7. smoke_date_groups.packed_weight_kg and bag_count are not null default 0 with NO
-- TRIGGER, while their sole source of truth is lot_bags. That is the identical defect R6a
-- already fixed one table over: a typed total and the rows it summarises diverge the first
-- time a write half-fails, and after that nobody can say which of the two is right.
--
-- An exact mirror of fn_rollup_smoke_log_input() in ...0003, down to the coalesce for the
-- delete-the-last-row case, because two roll-ups that read differently is how the next reader
-- concludes one of them is doing something clever.
create function fn_rollup_smoke_group_packed() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare v_group uuid := coalesce(new.smoke_date_group_id, old.smoke_date_group_id);
begin
  update smoke_date_groups
     set packed_weight_kg = (select coalesce(sum(packed_weight_kg), 0)
                               from lot_bags where smoke_date_group_id = v_group),
         bag_count        = (select count(*)
                               from lot_bags where smoke_date_group_id = v_group)
   where id = v_group;
  return null;
end $$;

create trigger trg_rollup_smoke_group_packed
  after insert or update or delete on lot_bags
  for each row execute function fn_rollup_smoke_group_packed();

-- The log's two packed columns are then a THIRD copy of the same number. PRODUCT.md's CM 04
-- totals output from the pack lines, and the pack lines belong to the smoke-date group, not
-- to the log. They are therefore not parameters of fn_upsert_smoke_daily_log and it never
-- writes them; v_lot_progress (^ref-27) reads the group's roll-up above. Dropping them from an
-- applied table is a rewrite for no gain — this is the treatment ^ref-21 gave
-- transport_lines.variance_pct, and for the same reason: the next person to read this DDL
-- will otherwise reach for them.
comment on column smoke_daily_logs.packed_weight_kg is
  'Never written. The pack lines belong to the smoke-date group, not to the log: '
  'smoke_date_groups.packed_weight_kg is the roll-up of lot_bags and is the only total '
  'v_lot_progress reads (PLAN-lots.md Finding 7). TC-08 asserts this column stays null.';

comment on column smoke_daily_logs.bag_count is
  'Never written. See packed_weight_kg on this table — smoke_date_groups.bag_count is the '
  'roll-up of lot_bags. TC-08 asserts this column stays null.';

------------------------------------------------------------------------ 4. R8, the lot half
-- Finding 4. fn_close_lot sets lots.state = LOT_CLOSED and NOTHING ANYWHERE refuses a later
-- write against that lot, so "closing locks the lot" is currently a word in an enum. R8:
-- "Child rows cannot be written when their daily_report.status = CLOSED or their lot is at
-- LOT_CLOSED or beyond, until an approved unlock_request exists. Trigger on each child table."
--
-- The lot half is this range's to build, because this range is what creates the closed state
-- the rest of the system will assume is enforced. The daily-report half is F9/F10's.
--
-- "OR BEYOND" IS LITERAL. lot_state is declared in lifecycle order — PO_CREATED, IN_TRANSIT,
-- CM_RECEIVED, SMOKING, LOT_CLOSED, RETURN_SCHEDULED, CENTRAL_STOCK, ALLOCATED, AT_BRANCH,
-- CONSUMED — so Postgres's enum ordering expresses it as >= and this guard needs no list to
-- maintain as F8 adds states after it.
--
-- R42 IS EVALUATED HERE, AT WRITE TIME. expires_at > now() is checked on this read, not by a
-- scheduled sweep: a background job that has not run yet would leave a stale APPROVED row
-- admitting writes it should refuse. This trigger is one of the two places R42 says that check
-- lives. It reads unlock_requests, which exists in ...0002 and stays empty until ^ref-08
-- lands — that is no dependency on ^ref-08, the same relationship v_po_outstanding already
-- has with an empty lot_receipts. Until then the guard is simply absolute, which is the
-- correct behaviour and not a degraded one.
--
-- OPENING LOTS ARE EXEMPT, AND THIS IS THE ONE THING PLAN-lots.md DID NOT SEE. ^ref-62's
-- fn_record_opening_balance creates its lot AT LOT_CLOSED — deliberately, because that lot's
-- production finished before the software existed — and then inserts a smoke_date_groups row
-- for it, twice over when 40 kg sits in one freezer and 15 kg in another. A guard reading
-- lot_state alone refuses the second write of a function that is merged and green. Opening
-- lots already have their own gate and it is a stricter one: opening_balance_close is one-way,
-- checked by both fn_record_opening_balance and trg_stock_ledger_opening_closed, and closing
-- it means "by anyone, ever" (ADR-021/R46). So is_opening short-circuits this guard rather
-- than being taught to it.
--
-- smoke_daily_log_sources reaches TWO lots and both are guarded: the lot being smoked, through
-- its parent log, and the lot the meat came out of, through D05's own lot_id. Consuming from a
-- closed lot after its yield was computed is the same corruption as writing into one, arriving
-- from the other side of the join.
--
-- In the migration rather than in supabase/functions/, following fn_rollup_smoke_log_input's
-- precedent in ...0003: it attaches to five named tables and has no reason to be re-applied
-- every deploy. fn_audit_row lives in functions/ because it loops over pg_tables and must pick
-- up tables added later; this one does not.
create function fn_guard_lot_closed() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_lots  uuid[];
  v_lot   uuid;
  v_state lot_state;
begin
  if tg_table_name = 'smoke_daily_log_sources' then
    if tg_op = 'DELETE' then
      select array[old.lot_id, l.lot_id] into v_lots
        from smoke_daily_logs l where l.id = old.smoke_daily_log_id;
    else
      select array[new.lot_id, l.lot_id] into v_lots
        from smoke_daily_logs l where l.id = new.smoke_daily_log_id;
    end if;
  elsif tg_table_name = 'lot_bags' then
    if tg_op = 'DELETE' then
      select array[g.lot_id] into v_lots
        from smoke_date_groups g where g.id = old.smoke_date_group_id;
    else
      select array[g.lot_id] into v_lots
        from smoke_date_groups g where g.id = new.smoke_date_group_id;
    end if;
  else
    -- lot_receipts, smoke_daily_logs and smoke_date_groups all carry lot_id directly.
    if tg_op = 'DELETE'
      then v_lots := array[old.lot_id];
      else v_lots := array[new.lot_id];
    end if;
  end if;

  foreach v_lot in array coalesce(v_lots, '{}'::uuid[]) loop
    -- `and not l.is_opening` leaves v_state NULL for an opening lot, and NULL >= anything is
    -- not true, so the guard falls through. See the OPENING LOTS paragraph above.
    select l.state into v_state from lots l where l.id = v_lot and not l.is_opening;

    if v_state >= 'LOT_CLOSED' and not exists (
         select 1 from unlock_requests u
          where u.target_type = 'LOT'
            and u.target_id   = v_lot
            and u.status      = 'APPROVED'
            and u.expires_at  > now())               -- R42, on this read
    then
      raise exception
        'LOT_CLOSED: lot % is at % — no child row may be written without an approved, unexpired unlock_request (R8/R42)',
        v_lot, v_state;
    end if;
  end loop;

  if tg_op = 'DELETE' then return old; else return new; end if;
end $$;

create trigger trg_guard_lot_closed
  before insert or update or delete on lot_receipts
  for each row execute function fn_guard_lot_closed();

create trigger trg_guard_lot_closed
  before insert or update or delete on smoke_daily_logs
  for each row execute function fn_guard_lot_closed();

create trigger trg_guard_lot_closed
  before insert or update or delete on smoke_daily_log_sources
  for each row execute function fn_guard_lot_closed();

create trigger trg_guard_lot_closed
  before insert or update or delete on smoke_date_groups
  for each row execute function fn_guard_lot_closed();

create trigger trg_guard_lot_closed
  before insert or update or delete on lot_bags
  for each row execute function fn_guard_lot_closed();

-- Both functions above fire as the table owner, so EXECUTE buys them nothing and no session
-- role should hold one. functions/000_revoke_defaults.sql sweeps the schema and runs after
-- every migration (R33), so they are covered by it — the route the three trigger functions in
-- ...0003, ...0004 and ...0012 all take. Sweep 1e of rls_deny_all_test.sql is what proves no
-- session role holds EXECUTE on them, and sweep 1g is where both names are excluded from the
-- opposite assertion — that every remaining fn_* IS callable. A trigger function added without
-- that second edit fails the suite reading "executable by nobody", which is the correct state
-- described as a defect.
