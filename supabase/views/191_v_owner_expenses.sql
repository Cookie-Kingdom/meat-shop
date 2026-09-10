-- v_owner_expenses — OW 09's reader, and what ^ref-56 / ^ref-57 group by (card ^ref-53).
--
-- L1 ONLY, IN THE DATABASE. M11 AC (v0.2:286): "L2/L3 ไม่เข้าถึงข้อมูลบัญชี Owner". One database
-- role carries every user, so that is a WHERE clause (R34), and an L2 or L3 session reads zero
-- rows from here rather than being shown a hidden menu (ADR-004, R20). owner_expenses stays
-- deny-all with no SELECT policy; that is the final posture.
--
-- pnl_month IS THE ONE MONTH RULE. coalesce(expense_month, to_char(event_date, 'YYYY-MM')):
-- a MONTHLY_FIXED row lands in the month it covers, everything else in the month it was paid —
-- ADR-020 expenses an investment in full in the month bought. …0025's biconditional makes that
-- exact (expense_month is set iff MONTHLY_FIXED), so a report reads this column and never
-- re-derives the rule. Lane K groups by `kind` (the หมวด, PLAN Finding 8) and `pnl_month`.
--
-- month_total_thb IS THE DATABASE'S SUM, so OW 09 never adds money in TypeScript (repo
-- CLAUDE.md). A window over pnl_month: every row of a month carries that month's total.
--
-- LEFT JOIN locations (null = central) and profiles (a JWT with no profile row must not drop
-- the row — v_audit_trail's reason). SECURITY DEFINER, the Postgres default: the tables are
-- deny-all, and an invoker view would return nothing for every role. Standing consequence —
-- never `force row level security` on owner_expenses, locations or profiles.
--
-- No ORDER BY: the screen orders and pages. ponytail: no index; a handful of rows a month.
--
-- Covered by supabase/tests/expenses_test.sql (TC-07, TC-21 … TC-24).

create or replace view public.v_owner_expenses as
select
  e.id,
  e.kind,
  e.event_date,
  e.expense_month,
  coalesce(e.expense_month, to_char(e.event_date, 'YYYY-MM')) as pnl_month,
  e.location_id,
  l.name_th       as location_name_th,
  e.amount_thb,
  e.detail,
  e.created_by,
  p.display_name  as created_by_name,
  e.created_at,
  sum(e.amount_thb) over (
    partition by coalesce(e.expense_month, to_char(e.event_date, 'YYYY-MM'))
  )::numeric(12,2) as month_total_thb
from owner_expenses e
left join locations l on l.id = e.location_id
left join profiles  p on p.id = e.created_by
where fn_current_role() = 'L1_OWNER';

comment on view public.v_owner_expenses is
  'OW 09 (M11). Owner expenses with pnl_month = coalesce(expense_month, month of event_date) '
  'and month_total_thb summed in the database. L1 only via the WHERE (R34); owner_expenses '
  'stays deny-all.';

revoke all    on public.v_owner_expenses from anon, authenticated;
grant  select on public.v_owner_expenses to   authenticated;
