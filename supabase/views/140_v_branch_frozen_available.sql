-- v_branch_frozen_available — BR 05's thaw picker: smoked meat at rest in a branch freezer, one
-- row per lot inside a smoke date (card ^ref-40, PLAN-thaw.md T4, Finding 4, TDD Seam 3).
--
-- v_smoke_group_available narrowed to FROZEN at a BRANCH location. That view filters neither
-- state nor location, and at a branch it offers two kinds of row a thaw must never draw from:
--
--   * IN_TRANSIT. R43 holds the transit tuple at the DESTINATION, so meat that was allocated
--     and not yet received reads as the branch's own. The picker would propose thawing meat
--     that is still on the truck, and fn_post_ledger would refuse it only after the operator
--     had typed a weight.
--   * READY. Already thawed.
--
-- fn_record_thaw asserts against THIS view (steps 9 and 10), so the picker and the function
-- read one definition of "thawable" and cannot drift apart — v_central_available's argument,
-- one location kind over.
--
-- FIFO IS BY SMOKE DATE (v0.2:92, :184, :188, :329; PLAN-thaw.md Finding 3). The first DATE is
-- the FIFO proposal. The first ROW is not: the lots inside the oldest date are the operator's
-- choice — v0.2:188 "แสดง Lot ให้เลือกภายในวันนั้น" — so inside a date the order is lot_code,
-- which is what the operator reads, never lot_id, which is a uuid. Two lots on one date stay
-- two rows (ADR-017, D01).
--
-- SCOPE is v_stock_balance's, inherited: L1 every branch, an L2 their own branch only, L3
-- nothing (R34, R20). thaw_test.sql TC-32 asserts it rather than trusting the inheritance.
-- No money, no yield (TC-33).
--
-- Covered by supabase/tests/thaw_test.sql (TC-15, TC-24, TC-32, TC-33) and
-- branch_screens_test.sql (TC-39, TC-40).

create or replace view public.v_branch_frozen_available as
select g.smoke_date,
       g.smoke_date_group_id,
       g.lot_id,
       g.lot_code,
       g.location_id,
       g.available_qty
  from v_smoke_group_available g
  join locations l on l.id = g.location_id
 where g.stock_state = 'FROZEN'
   and l.kind = 'BRANCH'
 order by g.smoke_date asc, g.lot_code asc;

comment on view public.v_branch_frozen_available is
  'BR 05 - FROZEN smoked meat at a branch, one row per lot inside a smoke date (ADR-017). FIFO '
  'is the oldest smoke DATE; the lot inside it is a choice (v0.2:188), so the first row is not '
  'the proposal. fn_record_thaw validates against this view. L1 all, L2 own branch, L3 none (R34).';

revoke all    on public.v_branch_frozen_available from anon, authenticated;
grant  select on public.v_branch_frozen_available to   authenticated;
