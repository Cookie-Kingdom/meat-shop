-- v_count_variance — counted against system, one row per physical count, and whether the Owner
-- has accepted it (card ^ref-49, R19; PLAN-materials.md T5).
--
-- A count writes nothing to the ledger (R19). This view is where its variance is read, and it is
-- how "a reconcilable variance" in the card's acceptance line becomes something a screen can list:
--
--   MATCHED   counted = system; nothing to reconcile
--   OPEN      a variance nobody has accepted
--   ACCEPTED  fn_accept_count_variance corrected a ledger row for it
--
-- THE CORRECTION IS FOUND BY ITS KEY, NOT A LINK TABLE. fn_accept_count_variance posts its
-- reversal under md5(count_id || ':count-accept')::uuid, and fn_reverse_ledger_entry derives the
-- replacement's key from that as md5(<that key> || ':replacement')::uuid. The two joins below
-- are the same expressions. If either function's derivation changes, this view must change
-- with it, or every accepted count reads OPEN again (TC-57 catches it).
--
-- lot_id comes through the smoke date group for a meat count (ADR-017): the group names its lot,
-- so the count does not need a second copy that could disagree.
--
-- SCOPE is v_stock_balance's: L1 all rows; an L2 their own locations; L3 none (R34). The base
-- tables are deny-all, so the view is SECURITY DEFINER (the default), never security_invoker.
-- No price column (R20).
--
-- Covered by supabase/tests/materials_count_test.sql (TC-50, TC-51, TC-57, TC-62).

create or replace view public.v_count_variance as
select pc.id                  as physical_count_id,
       pc.daily_report_id,
       pc.location_id,
       pc.event_date,
       pc.item_type,
       pc.packaging_item_id,
       pc.smoke_date_group_id,
       g.lot_id,
       pc.counted_qty,
       pc.system_qty,
       pc.variance_qty,
       pc.reason,
       pc.created_by          as counted_by,
       pc.created_at          as counted_at,
       case when rv.id is not null   then 'ACCEPTED'
            when pc.variance_qty = 0 then 'MATCHED'
            else 'OPEN' end   as status,
       rv.id                  as correction_reversal_id,
       rp.id                  as correction_replacement_id,
       rv.created_at          as corrected_at,
       rv.created_by          as corrected_by,
       rv.reason              as correction_reason
  from physical_counts pc
  left join smoke_date_groups g on g.id = pc.smoke_date_group_id
  left join stock_ledger rv
         on rv.idempotency_key = md5(pc.id::text || ':count-accept')::uuid
  left join stock_ledger rp
         on rp.idempotency_key = md5(md5(pc.id::text || ':count-accept')::uuid::text || ':replacement')::uuid
 where fn_current_role() = 'L1_OWNER'
    or (fn_current_role() = 'L2_BRANCH_ADMIN' and pc.location_id = any (fn_current_locations()));

comment on view public.v_count_variance is
  'R19 — one row per physical count: counted vs system, and whether the Owner accepted it '
  '(MATCHED / OPEN / ACCEPTED). The correction is found by fn_accept_count_variance''s derived '
  'ledger key. L1 all rows, L2 own branches, L3 none (R34).';

revoke all    on public.v_count_variance from anon, authenticated;
grant  select on public.v_count_variance to   authenticated;
