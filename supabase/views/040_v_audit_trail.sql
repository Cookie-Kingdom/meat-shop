-- v_audit_trail — the OW 11 audit reader (card ^ref-09). Writer is fn_audit_row (^ref-06).
--
-- AN EXPANSION, NOT A PROJECTION. audit_log stores whole-row `before`/`after` jsonb; the
-- AuditLogTable contract is per-field — ผู้แก้ · เวลา · Field · ค่าเดิม · ค่าใหม่. So one
-- audit row becomes N rows here, and that expansion is the whole risk in this view:
--
--   * Expand only the keys that actually moved (IS DISTINCT FROM). Expanding every key
--     makes each edit read as a total rewrite — twenty "value → same value" rows per
--     change, with the one field that moved buried in them.
--   * INSERT and DELETE expand to ONE row with field_name null. A creation is one event,
--     not one edit per column, and per-field expansion of an insert is twenty
--     "null → value" rows of noise. The LEFT JOIN LATERAL is what produces that row: the
--     lateral yields nothing for those actions, and `on true` keeps the audit row.
--     An UPDATE that moved no field lands in the same shape, which is honest — it says
--     the row was written and nothing changed.
--   * changed_at is created_at, NEVER event_date (ADR-007, and the contract says so).
--     event_date is when the business thing happened; the audit trail answers *when was
--     this typed*. Two clocks that agree on most rows is exactly how the wrong one ships.
--
-- COMPARED AS TEXT (`->>`), not as jsonb (`->`). jsonb equality would call 96.50 and
-- 96.5 different values, and the screen renders text anyway.
--
-- L1 ONLY, AND THAT CANNOT BE A GRANT. There is one database role for application users —
-- `authenticated` — and L1/L2/L3 lives on profiles, so the permissions table's
-- "v_audit_trail: L1 all, L2 —, L3 —" has to be a WHERE clause (R34), the same pattern as
-- v_stock_balance and v_po_outstanding. An L2 or L3 session gets zero rows from the
-- database, not a hidden nav item (ADR-004, UAT-15).
--
-- SECURITY DEFINER (the Postgres default), not security_invoker: audit_log is deny-all
-- with RLS on, so an invoker view returns nothing for every role including L1. Standing
-- consequence, the same one v_stock_balance carries — never `force row level security` on
-- audit_log or profiles.
--
-- LEFT JOIN to profiles: actor_id may be null. fn_audit_row reads profiles directly so a
-- JWT with no profile row still gets logged, and an inner join would drop exactly the
-- rows worth reading.
--
-- ponytail: no index on audit_log (created_at desc) for the screen's default sort. The
-- existing index is (table_name, row_id, created_at desc) and the sequential scan is free
-- at this business's write volume. Ceiling: add the index when the log passes ~100k rows
-- or the screen is measurably slow, whichever comes first.
--
-- BR22 — nothing is deleted by age, so this grows without bound. The screen paginates
-- from day one; the view deliberately carries no ORDER BY or LIMIT of its own.
--
-- Covered by supabase/tests/audit_trail_test.sql (TC-A … TC-G).

create or replace view public.v_audit_trail as
select
  a.id            as audit_id,
  a.created_at    as changed_at,     -- ADR-007. Not event_date. See the header.
  a.table_name,
  a.row_id,
  a.action,
  a.actor_id,
  p.display_name  as actor_name,
  a.actor_role,
  a.event_date,
  f.field_name,
  f.old_value,
  f.new_value,
  a.reason
from audit_log a
left join profiles p on p.id = a.actor_id
left join lateral (
  select k.field_name,
         a.before ->> k.field_name as old_value,
         a.after  ->> k.field_name as new_value
    from jsonb_object_keys(
           -- Only an UPDATE expands. '{}' yields zero keys, so INSERT and DELETE fall
           -- through to the `on true` row with a null field_name.
           case when a.action = 'UPDATE'
                then coalesce(a.before, '{}'::jsonb) || coalesce(a.after, '{}'::jsonb)
                else '{}'::jsonb
           end
         ) as k(field_name)
   where (a.before ->> k.field_name) is distinct from (a.after ->> k.field_name)
) f on true
where fn_current_role() = 'L1_OWNER';

comment on view public.v_audit_trail is
  'OW 11. One row per CHANGED FIELD of an UPDATE, one row with field_name null for an '
  'INSERT or DELETE. changed_at is audit_log.created_at, never event_date (ADR-007). '
  'L1 only, enforced in the WHERE (R34) — audit_log itself stays deny-all.';

revoke all    on public.v_audit_trail from anon, authenticated;
grant  select on public.v_audit_trail to   authenticated;
