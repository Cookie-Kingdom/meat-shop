-- v_central_available — OW 07's allocation picker: smoked meat at rest in central stock, one
-- row per lot inside a smoke date (card ^ref-36, PLAN-movement.md Finding 6, TDD Seam 5).
--
-- v_smoke_group_available narrowed to FROZEN at a CENTRAL location. That view is the general
-- picking list and offers IN_TRANSIT rows at every location; allocating one of those draws on
-- central FROZEN stock that has not landed, and fn_post_ledger refuses it with
-- INSUFFICIENT_STOCK after the Owner has already picked a branch, a weight and a bag count.
-- fn_allocate_to_branch validates against THIS view, so the picker and the function read one
-- definition of "allocatable" and cannot drift apart.
--
-- FIFO IS BY SMOKE DATE (v0.2:184, :188, :329). The first DATE is the proposal. The lots inside
-- it are the Owner's choice, not a ranking — v0.2:188 "แสดง Lot ให้เลือกภายในวันนั้น" — so inside
-- a date the order is lot_code, which is what the Owner reads, and not lot_id, which is a uuid.
-- Two lots on one date stay two rows (ADR-017). The order by stays because this view IS the
-- proposal; a screen that re-sorts it is a bug the view cannot prevent.
--
-- SCOPE is v_stock_balance's: L1 all; an L2 only their own locations, and no L2 holds a CENTRAL
-- one, so zero rows — the can_receive_central delegate included, because the delegation grants
-- the act and widens no read (Seam 1). L3 none. TC-28 asserts it rather than trusting it: it is
-- true only while no L2 is ever assigned a CENTRAL location.
--
-- ponytail: assumes one CENTRAL location. A second one makes this return both and gives
-- fn_allocate_to_branch no rule for choosing an origin (TDD-movement.md open question 3).
--
-- Covered by supabase/tests/movement_test.sql (TC-27, TC-28, TC-33a).

create or replace view public.v_central_available as
select g.smoke_date,
       g.smoke_date_group_id,
       g.lot_id,
       g.lot_code,
       g.location_id,
       g.available_qty
  from v_smoke_group_available g
  join locations l on l.id = g.location_id
 where g.stock_state = 'FROZEN'
   and l.kind = 'CENTRAL'
 order by g.smoke_date asc, g.lot_code asc;

comment on view public.v_central_available is
  'OW 07 — FROZEN smoked meat at central, one row per lot inside a smoke date (ADR-017). FIFO '
  'is the oldest smoke DATE; the lot inside it is a choice (v0.2:188). L1 all rows, everyone '
  'else none (R34). Assumes one CENTRAL location.';

revoke all    on public.v_central_available from anon, authenticated;
grant  select on public.v_central_available to   authenticated;
