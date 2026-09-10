-- Card ^ref-42 — what F10's tables owe before a sale, a waste row or a day close can be
-- written (PLAN-sales.md T1; Findings 2, 3, 4, 5, 7, 10, 12).
--
-- sales_lines and waste_records were created in ...0004, with qty > 0, the unit_price_thb
-- snapshot, reason NOT NULL on waste, and R21's fn_require_lot_for_meat trigger on both. So
-- the card's acceptance line ("every sale and waste row names its source lot_id", ADR-017) was
-- already true of that file. This is the seventh stale-in-Backlog card of that shape. What the
-- migration actually owes is five things, one per section:
--
--   1. three retry keys, in three shapes                        (R39, Finding 5)
--   2. sales_lines.created_by and the pack-weight snapshot      (R32, R29, Finding 4)
--   3. R8's daily-report half: fn_guard_report_closed           (R8, R42, Finding 3)
--   4. BR21's whole units, folded into fn_require_lot_for_meat  (BR21, Finding 12)
--   5. the five SKUs nothing seeds                              (D03.1, BR08, Findings 7, 10)
--
-- Section 5 uses BEVERAGE, which ...0017 added alone in its own file.

-------------------------------------------------------------------- 1. the three retry keys
-- R39. Three tables, three shapes, and the shapes are not interchangeable.
--
-- sales_lines. One call is one BATCH of lines, because fn_record_sales takes p_lines, so the
-- key is per batch and the unique constraint is on the PAIR (idempotency_key, seq). A key alone
-- would refuse line 2 of a five-line save. A payload key would refuse two genuine MEAT_BOX
-- lines from two lots on one afternoon, which is D01's ordinary case. seq is the array's
-- ordinality, minted inside the function. That is lot_bags' shape from ...0013, and it
-- inherits lot_bags' remaining hole: a replay carrying MORE lines inserts the extras without
-- conflicting. fn_record_sales closes the hole with R39's explicit pre-check, taken under a
-- lock on the key (SALES_IDEMPOTENCY_CONFLICT).
--
-- waste_records. One call is one row, so the key alone is exact. smoke_daily_logs' shape.
--
-- daily_reports. The row is written twice, by two functions, on two different evenings.
-- fn_open_daily_report rides R5's natural key and needs no column, but the close is a second
-- act that the natural key cannot describe. Without its own key, a retry after a dropped
-- connection reads REPORT_ALREADY_CLOSED: a false error on a write that succeeded, which R4
-- forbids. transport_lines.receipt_idempotency_key (...0010) exists one table over for the
-- same reason. The column holds the key of the MOST RECENT close. An UNLOCKED day that is
-- closed again arrives on a fresh key and overwrites it, which keeps the unique index safe
-- across re-closes.
--
-- All three are nullable. These are column adds on tables that hold no rows in any
-- environment, and every writer rejects a null key by name before it writes, as ...0008,
-- ...0010 and ...0013 do. NOT NULL would only turn a named exception into a constraint name.
alter table sales_lines   add column idempotency_key uuid;
alter table sales_lines   add column seq integer check (seq > 0);
alter table sales_lines   add constraint sales_lines_batch_key unique (idempotency_key, seq);

alter table waste_records add column idempotency_key uuid;
create unique index waste_records_idempotency_key on waste_records (idempotency_key);

alter table daily_reports add column close_idempotency_key uuid;
create unique index daily_reports_close_idempotency_key on daily_reports (close_idempotency_key);

------------------------------------------------- 2. the actor, and the pack-weight snapshot
-- created_by (R32). thaw_records, waste_records, physical_counts and stock_ledger all carry
-- one, and sales_lines did not. The audit trail would have been the only record of who keyed a
-- sale, and the audit trail answers "when was this typed", not "whose number is this". The
-- table is empty in every environment, so NOT NULL lands directly, as ...0009 did for
-- daily_reports.shift_started_at.
alter table sales_lines add column created_by uuid not null references profiles(id);

-- pack_weight_kg (R29): "Whatever a config value was at the time is stored on the row that
-- used it: price, fee rate, avg pack weight." unit_price_thb was snapshotted and the pack
-- weight was not, yet the pack weight is the other half of every meat line. 24 boxes at 0.20
-- kg draws 4.80 kg of READY. If the Owner later sets 0.22, a Diff recomputed from config
-- re-prices a closed day. The column is null on every line that is not meat.
alter table sales_lines add column pack_weight_kg numeric(12,2) check (pack_weight_kg > 0);

comment on column sales_lines.pack_weight_kg is
  'R29 snapshot of avg_pack_weight_kg at the report''s business date, on meat lines only and '
  'null otherwise. The SALE ledger row was computed from THIS value, so v_branch_diff reads the '
  'ledger and never re-reads config: a later config row must not move a closed Diff (BR23).';

comment on column sales_lines.created_by is
  'R32: the actor who keyed the line, resolved inside fn_record_sales from auth.uid(). It is '
  'never a parameter, so no caller can sign a sale as somebody else.';

------------------------------------------------------------ 3. R8, the daily-report half
-- ...0013 built the lot half and said so: "The daily-report half is F9/F10's." Until now,
-- nothing refused a child row that arrived for a report closed the night before.
-- fn_open_daily_report refuses to REOPEN a closed day, which is a different rule. This range
-- creates the closed state that the rest of the system will assume is enforced, so it also
-- builds the enforcement.
--
-- Six tables carry daily_report_id, and all six are guarded: sales_lines, thaw_records,
-- waste_records, physical_counts, rice_records and branch_expenses. Lanes B (thaw) and D (rice,
-- counts, expenses) write functions that meet REPORT_CLOSED from this trigger and add no guard
-- of their own. Their functions raise REPORT_CLOSED by name as well, to carry the Thai
-- message. This trigger is the backstop, and it still holds against a writer added in 2027.
--
-- THE PREDICATE IS status = 'CLOSED', NEVER status <> 'OPEN'. UNLOCKED is a past day reopened
-- under R28, and it must accept the correction it was reopened for. daily_reports_one_open
-- (...0009) is partial on status = 'OPEN' for exactly this reason. A guard that refused
-- UNLOCKED would make the unlock path dead code, and the failure would look like a
-- permissions bug three layers away.
--
-- R42 IS EVALUATED HERE, AT WRITE TIME: expires_at > now() on this read, never by a sweep. A
-- job that has not run yet would leave a stale APPROVED row admitting writes. unlock_requests
-- stays empty until ^ref-08 lands, and until then the close is simply absolute. That is the
-- correct behaviour, not a degraded one, and fn_guard_lot_closed has the same relationship.
--
-- A NULL PARENT FALLS THROUGH. physical_counts.daily_report_id is nullable ("null for ad-hoc
-- counts"). `where id = null` finds no row, v_status stays null, and null = 'CLOSED' is not
-- true, so the guard falls through by construction. TC-11 asserts it anyway, because one
-- defensive coalesce would refuse every ad-hoc count in the system.
--
-- ONE DIFFERENCE FROM THE LOT HALF, ON PURPOSE: an UPDATE is checked against the OLD report as
-- well as the new one. Moving a row out of a closed day is a write to that day.
-- fn_guard_lot_closed reads only new.lot_id because its tables never change lot on update.
--
-- It lives in the migration rather than in supabase/functions/, following fn_guard_lot_closed:
-- it attaches to six named tables and has no reason to be re-applied on every deploy.
create function fn_guard_report_closed() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_reports uuid[];
  v_report  uuid;
  v_status  report_status;
  v_date    date;
begin
  -- Branch, do not CASE: `old` is unassigned in an INSERT trigger (see fn_audit_row).
  if tg_op = 'INSERT' then
    v_reports := array[new.daily_report_id];
  elsif tg_op = 'UPDATE' then
    v_reports := array[old.daily_report_id, new.daily_report_id];
  else
    v_reports := array[old.daily_report_id];
  end if;

  foreach v_report in array v_reports loop
    -- A select that finds no row sets both targets to null. That is the null-parent case.
    select status, report_date into v_status, v_date from daily_reports where id = v_report;

    if v_status = 'CLOSED' and not exists (
         select 1 from unlock_requests u
          where u.target_type = 'DAILY_REPORT'
            and u.target_id   = v_report
            and u.status      = 'APPROVED'
            and u.expires_at  > now())                -- R42, on this read
    then
      raise exception
        'REPORT_CLOSED: the day % (report %) is closed — no % row may be written without an approved, unexpired unlock_request (R8/R42)',
        v_date, v_report, tg_table_name;
    end if;
  end loop;

  if tg_op = 'DELETE' then return old; else return new; end if;
end $$;

create trigger trg_guard_report_closed
  before insert or update or delete on sales_lines
  for each row execute function fn_guard_report_closed();

create trigger trg_guard_report_closed
  before insert or update or delete on thaw_records
  for each row execute function fn_guard_report_closed();

create trigger trg_guard_report_closed
  before insert or update or delete on waste_records
  for each row execute function fn_guard_report_closed();

create trigger trg_guard_report_closed
  before insert or update or delete on physical_counts
  for each row execute function fn_guard_report_closed();

create trigger trg_guard_report_closed
  before insert or update or delete on rice_records
  for each row execute function fn_guard_report_closed();

create trigger trg_guard_report_closed
  before insert or update or delete on branch_expenses
  for each row execute function fn_guard_report_closed();

comment on function fn_guard_report_closed() is
  'R8, the daily-report half (^ref-42). Refuses any write to a branch-daily child row whose '
  'report is CLOSED, unless an APPROVED DAILY_REPORT unlock_request with expires_at > now() '
  'exists (R42). UNLOCKED is writable and a null daily_report_id falls through. Raises '
  'REPORT_CLOSED by name, and lanes B and D rely on that name.';

--------------------------------------------------------------------- 4. BR21's whole units
-- "จำนวนซอง หลอด และชิ้นเป็นจำนวนเต็ม" (BR21, D03). sales_lines.qty is numeric(12,2) with
-- check (qty > 0), so 12.5 boxes stores fine, prices at 350 x 12.5, and comes out of the Diff
-- as 2.50 kg of meat that was never packed. A CHECK cannot see the rule, because the unit lives
-- on products.sale_unit, one table over.
--
-- EXTENDED, NOT ADDED. fn_require_lot_for_meat already fires on both tables and already looks
-- the product up for sales_lines. A second trigger function would fire on the same row for the
-- same class of reason and need a second name in sweep 1g. Its comment is rewritten to say what
-- it now is, because a name that no longer describes its function is how the next reader adds
-- a third.
--
-- RICE_KG's unit is kg, so rice stays fractional: 8.50 kg is an ordinary sale. waste_records
-- has no product column, so that branch tests item_type instead. A wasted tube of chilli is a
-- whole tube, and meat is wasted in kg.
--
-- `set search_path` is restated because CREATE OR REPLACE replaces the function's SET clauses
-- along with its body, and ...0006 pinned this function's search path.
create or replace function fn_require_lot_for_meat() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_item item_type;
  v_unit text;
  v_code text;
begin
  if tg_table_name = 'sales_lines' then
    select item_type, sale_unit, code into v_item, v_unit, v_code
      from products where id = new.product_id;
  else
    v_item := new.item_type;
    v_unit := case when v_item = 'CHILLI_PASTE' then 'tube' else 'kg' end;
    v_code := v_item::text;
  end if;

  -- R21 / ADR-017, unchanged from ...0004.
  if v_item = 'SMOKED_MEAT' and new.lot_id is null then
    raise exception 'LOT_REQUIRED: % on SMOKED_MEAT needs lot_id (R21/D01)', tg_table_name;
  end if;

  -- BR21. Every unit that is not kg is counted whole.
  if v_unit <> 'kg' and new.qty <> trunc(new.qty) then
    raise exception 'QTY_NOT_WHOLE_UNITS: % % of % — packs, tubes and pieces are whole numbers (BR21)',
      new.qty, v_unit, v_code;
  end if;

  return new;
end $$;

comment on function fn_require_lot_for_meat() is
  'Row-shape guard for branch daily lines on sales_lines and waste_records. R21: a SMOKED_MEAT '
  'line names its lot. BR21 (^ref-42): a line whose unit is not kg is a whole number. The unit '
  'is products.sale_unit on sales_lines; on waste_records, CHILLI_PASTE is counted in tubes and '
  'everything else in kg.';

-- Trigger functions fire as the table owner, so EXECUTE buys them nothing. 000_revoke_defaults
-- sweeps the schema after every migration, and this line says the same thing where the
-- functions are defined (sweep 1e, rls_deny_all_test.sql).
revoke execute on function fn_guard_report_closed()  from public, anon, authenticated;
revoke execute on function fn_require_lot_for_meat() from public, anon, authenticated;

------------------------------------------------------------ 5. the five SKUs nothing seeds
-- Finding 7. fn_record_sales resolves product_code against products. `into products` finds
-- three test fixtures and nothing else: no migration seeded the table, no fn_* writes it, and
-- RLS is deny-all. fn_set_product_price (^ref-11) prices products that nothing creates.
-- ^ref-61 seeds config KEYS, and a price is not a SKU.
--
-- The five codes are v0.2-confirmed (BR06, BR08, BR13, D03.1) and are already written into
-- the fn_record_sales contract, so this is reference data with no other owner. PRICES STAY OUT.
-- They are BLOCK rows the Owner enters (ADR-023), and until then fn_record_sales raises
-- CONFIG_NOT_SET naming the SKU.
--
-- MEAT_BOX and MEAT_ADDON_SEALED are two SKUs, never one row with two prices. They are
-- separate sale lines (D03.1, UAT-16), and the add-on is counted in bags (v0.2:211).
--
-- is_stock_tracked = false on RICE_KG (Finding 10) and WATER_BOTTLE (BR08). Rice's balance at
-- a branch is an entered figure (M7), carried in, cooked today and remaining on rice_records,
-- and fn_open_daily_report reads it from there. A SALE row against COOKED_RICE would create a
-- second balance for the same rice, and before ^ref-48 it would be a draw against a tuple with
-- no intake at all. If F11 decides rice belongs in the ledger, this flag flips and
-- fn_record_sales needs no change.
--
-- `on conflict (code) do nothing`, so an Owner who has already created a row keeps it.
insert into products (code, name_th, item_type, sale_unit, is_stock_tracked) values
  ('MEAT_BOX',          'เนื้อรมควัน กล่องปกติ',        'SMOKED_MEAT',  'box',    true),
  ('MEAT_ADDON_SEALED', 'Add-on เนื้อซีลเพิ่ม 1 ถุง',     'SMOKED_MEAT',  'bag',    true),
  ('CHILLI_TUBE',       'น้ำพริก หลอด 30 กรัม',         'CHILLI_PASTE', 'tube',   true),
  ('RICE_KG',           'ข้าวเหนียว (กิโลกรัม)',          'COOKED_RICE',  'kg',     false),
  ('WATER_BOTTLE',      'น้ำเปล่า',                     'BEVERAGE',     'bottle', false)
on conflict (code) do nothing;

comment on column products.is_stock_tracked is
  'false: fn_record_sales writes and prices the line and posts NO ledger row. RICE_KG (a '
  'branch''s rice balance is rice_records, M7) and WATER_BOTTLE (BR08) are seeded false by '
  '^ref-42.';
