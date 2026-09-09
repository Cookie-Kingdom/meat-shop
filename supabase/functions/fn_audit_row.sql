-- Card ^ref-06 — the generic audit trigger, and the guard that makes the log worth keeping.
--
-- One trigger function for every table, not one per table: the audit shape cannot drift
-- between tables, and a table added by a later card cannot silently skip the audit.
--
-- SECURITY DEFINER is correctness, not hardening. `audit_log` is deny-all — RLS on, zero
-- grants — so the trigger has to insert as the table owner, who is exempt while
-- `force row level security` is off. Same mechanism as R31, same standing rule: never force
-- RLS on this table either.
--
-- Neither function below is revocable-in-any-meaningful-sense: a `returns trigger` function
-- cannot be invoked outside a trigger and PostgREST does not expose one. `search_path` is
-- pinned all the same, matching migration …0006.
--
-- This file is a state file, not a migration: it is re-applied on every deploy
-- (migrations -> functions -> policies), which is what keeps the attach loop at the foot
-- from going stale the way migration …0005's RLS loop did.
--
-- Covered by supabase/tests/audit_trigger_test.sql.

create or replace function public.fn_audit_row()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $fn$
declare
  v_before jsonb;
  v_after  jsonb;
  v_row    jsonb;
  v_actor  uuid;
  v_role   user_role;
begin
  -- Branch, do not CASE: referencing `old` in an INSERT trigger raises "record old is not
  -- assigned yet" when plpgsql passes it into the expression, short-circuit or not.
  if tg_op = 'INSERT' then
    v_after  := to_jsonb(new);
  elsif tg_op = 'UPDATE' then
    v_before := to_jsonb(old);
    v_after  := to_jsonb(new);
  else
    v_before := to_jsonb(old);
  end if;
  v_row := coalesce(v_after, v_before);

  -- Read straight from profiles rather than through fn_current_role(): the helper folds in
  -- is_active and goes null for a deactivated caller (R31), which is right for a policy and
  -- wrong here. If a deactivated session somehow writes, the log must still say who and what
  -- role they held. A JWT with no profile row yields null/null, which also keeps the
  -- actor_id FK from blocking the very write it was meant to record.
  -- ponytail: one select per audited row. Free at this write volume; a bulk backfill would
  -- want a per-statement cache, not a redesign.
  select p.id, p.role into v_actor, v_role from profiles p where p.id = auth.uid();

  insert into audit_log (
    table_name, row_id, action, actor_id, actor_role, event_date,
    before, after, reason, idempotency_key
    -- created_at is never listed: it takes its default now(). Card acceptance.
  ) values (
    tg_table_name,
    (v_row ->> 'id')::uuid,
    tg_op,
    v_actor,
    v_role,
    -- ADR-007: business_date is the trading day and wins where a table has both. Eleven
    -- tables carry only event_date; the rest carry neither and record null.
    coalesce((v_row ->> 'business_date')::date, (v_row ->> 'event_date')::date),
    v_before,
    v_after,
    -- The schema spells "reason" three ways. FIFO skipped (R15), data mismatched (R22, R27),
    -- and the plain column on waste_records.
    coalesce(v_row ->> 'fifo_override_reason', v_row ->> 'variance_reason', v_row ->> 'reason'),
    (v_row ->> 'idempotency_key')::uuid
  );

  return null;   -- after trigger; the return value is discarded
end $fn$;

-- TC-18. An audit trail that can be edited proves nothing. Two triggers for the same reason
-- R1 needs two (migration …0007): Postgres fires neither event for the other, so a
-- `before update or delete` trigger alone leaves TRUNCATE free to empty the log.
create or replace function public.fn_audit_log_append_only()
  returns trigger
  language plpgsql
  set search_path = public, pg_temp
as $fn$
begin
  raise exception 'AUDIT_APPEND_ONLY: audit_log is insert-only, and only the audit trigger inserts';
end $fn$;

create or replace trigger trg_audit_log_append_only
  before update or delete on audit_log
  for each statement execute function fn_audit_log_append_only();

create or replace trigger trg_audit_log_no_truncate
  before truncate on audit_log
  for each statement execute function fn_audit_log_append_only();

-- Attach to everything except audit_log itself, which would recurse. Re-applied every deploy,
-- so a table created by a later card is covered without anyone remembering to come back here.
do $do$
declare t text;
begin
  for t in
    select tablename from pg_tables
     where schemaname = 'public'
       and tablename <> 'audit_log'
     order by tablename
  loop
    execute format(
      'create or replace trigger %I after insert or update or delete on public.%I
         for each row execute function fn_audit_row()',
      'trg_audit_' || t, t);
  end loop;
end $do$;
