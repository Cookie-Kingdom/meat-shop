-- v_lot_return_pending — OW 05's queue: closed lots waiting for a return pickup date, and the
-- ones already given one (BR17, R34, card ^ref-34, PLAN-movement.md Finding 7).
--
-- One row per lot at LOT_CLOSED or RETURN_SCHEDULED. A lot leaves the queue by moving on —
-- nothing reads the pickup date to decide it, so a rescheduled lot stays visible with its new
-- date. days_since_close is what makes it a queue rather than a table.
--
-- OPENING LOTS ARE LEFT OUT. ^ref-62 creates them at LOT_CLOSED on purpose, with no closed_at
-- and no chef house, so without this filter every one would sit in the queue for ever as
-- "closed, never collected". fn_set_return_pickup_date still accepts one.
-- ponytail: an opening lot counted AT the chef house on go-live day gets no row here, so OW 05
-- cannot offer it; add `or exists` over its chef-house balance if the go-live count has one.
--
-- NO COST, NO YIELD, NO DISPATCH WEIGHT (R20, TC-21). A delegate may be an L2, and R20 keeps
-- both figures out of anything an L2 can select. packed_weight_kg alone is not a yield — the
-- divisor is the Foodiva dispatch weight (ADR-011), and it is not in this view.
--
-- SCOPE (R34): L1 all; a profile holding can_receive_central on any row all — it is the list
-- of the job it was delegated, and like the delegation itself it does not ask which location
-- the flag sits on; everyone else zero rows, including the L3 whose lot it is (BR15 gives the
-- chef house no transport scope). `fn_current_role() is not null` keeps a deactivated
-- delegate out. SECURITY DEFINER (the Postgres default), never security_invoker.
--
-- No order by, no limit — the screen sorts and pages (v_audit_trail's rule).
--
-- Covered by supabase/tests/movement_test.sql (TC-20 ... TC-22).

create or replace view public.v_lot_return_pending as
select
  l.id                                      as lot_id,
  l.lot_code,
  l.state,
  l.chef_house_location_id,
  l.closed_at,
  l.return_pickup_date,
  current_date - l.closed_at::date          as days_since_close,
  coalesce(g.packed_weight_kg, 0)           as packed_weight_kg,
  coalesce(g.group_count, 0)                as group_count
from lots l
left join (
  select lot_id, sum(packed_weight_kg) as packed_weight_kg, count(*) as group_count
    from smoke_date_groups
   group by lot_id
) g on g.lot_id = l.id
where l.state in ('LOT_CLOSED', 'RETURN_SCHEDULED')
  and not l.is_opening
  and (fn_current_role() = 'L1_OWNER'
       or (fn_current_role() is not null
           and exists (select 1 from user_locations ul
                        where ul.profile_id = auth.uid() and ul.can_receive_central)));

comment on view public.v_lot_return_pending is
  'OW 05 — lots at LOT_CLOSED or RETURN_SCHEDULED, opening lots excluded (BR17). No cost, '
  'no yield, no dispatch weight (R20). L1 and can_receive_central delegates all rows, '
  'everyone else none (R34).';

revoke all    on public.v_lot_return_pending from anon, authenticated;
grant  select on public.v_lot_return_pending to   authenticated;
