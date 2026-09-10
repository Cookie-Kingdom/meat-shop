-- Card ^ref-08 — v_unlock_requests. OW 11's UnlockPanel, and the only read path to
-- unlock_requests (ADR-004). The table stays deny-all.
--
-- ROLE-SCOPED IN THE WHERE (R34), NOT L1-ONLY.
--   L1  every row.
--   L2  the DAILY_REPORT rows at its own branches. A branch screen has to be able to say
--       "this day is open until 14:30", and "rejected, because …".
--   L3  the LOT rows for lots assigned to it.
-- A role that may not see a row reads zero of them. The (owner) route guard is the mirror.
--
-- impact IS L1-ONLY. It carries sales_thb, and L3 never reads a price (R20). The simplest
-- rule that keeps that true is "only the Owner sees impact", and only the Owner decides. A
-- PENDING row's impact is computed live by fn_unlock_impact. A decided row shows the stored
-- decision_impact, which is what the Owner actually approved, and is not recomputed.
--
-- status READS EXPIRED ON THE SAME READ THE TRIGGER REFUSES ON (R42). An APPROVED row with
-- expires_at <= now() is reported as EXPIRED here whether or not fn_request_unlock has flipped
-- it yet. The guards compare the same clock, so the screen and the refusal cannot disagree,
-- and no scheduled job is involved.
--
-- auto_approved: APPROVED (or since EXPIRED) with no deciding Owner, i.e. R28's window made
-- the decision. An L1 self-request carries the Owner as decided_by and is not "auto".
--
-- SECURITY DEFINER (the default), never security_invoker. The base table has RLS on and no
-- policies, so an invoker view would return nothing for every role (R34).
--
-- Covered by supabase/tests/unlock_test.sql (UL-29, UL-34 ... UL-39).

create or replace view public.v_unlock_requests as
select
  u.id                                              as unlock_request_id,
  u.target_type,
  u.target_id,
  coalesce(r.location_id, l.chef_house_location_id) as location_id,
  loc.name_th                                       as location_name,
  r.report_date,
  l.lot_code,
  u.reason,
  case when u.status = 'APPROVED' and u.expires_at <= now()
       then 'EXPIRED'::unlock_status
       else u.status
  end                                               as status,
  u.requested_by,
  rq.display_name                                   as requested_by_name,
  u.created_at                                      as requested_at,
  u.decided_by,
  dc.display_name                                   as decided_by_name,
  u.decided_at,
  u.decision_note,
  (u.status in ('APPROVED', 'EXPIRED') and u.decided_by is null) as auto_approved,
  u.expires_at,
  case when fn_current_role() = 'L1_OWNER' then
         case when u.status = 'PENDING'
              then fn_unlock_impact(u.target_type, u.target_id)
              else u.decision_impact
         end
  end                                               as impact
from unlock_requests u
left join daily_reports r   on u.target_type = 'DAILY_REPORT' and r.id = u.target_id
left join lots          l   on u.target_type = 'LOT'          and l.id = u.target_id
left join locations     loc on loc.id = coalesce(r.location_id, l.chef_house_location_id)
left join profiles      rq  on rq.id = u.requested_by
left join profiles      dc  on dc.id = u.decided_by
where fn_current_role() = 'L1_OWNER'
   or (fn_current_role() = 'L2_BRANCH_ADMIN'
       and u.target_type = 'DAILY_REPORT'
       and r.location_id = any (fn_current_locations()))
   or (fn_current_role() = 'L3_CM_OPERATOR'
       and u.target_type = 'LOT'
       and l.assigned_operator_id = auth.uid());

comment on view public.v_unlock_requests is
  'OW 11 UnlockPanel (^ref-08). L1 every row; L2 day rows at its branches; L3 lot rows '
  'assigned to it (R34, in the WHERE). status reads EXPIRED once expires_at <= now() (R42). '
  'impact is L1-only: live for PENDING, the stored decision_impact otherwise.';

revoke all    on public.v_unlock_requests from anon, authenticated;
grant  select on public.v_unlock_requests to   authenticated;
