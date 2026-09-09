-- Card ^ref-11 — config resolution. One lookup for thirty keys (R12, ADR-006, ADR-018).
--
-- Two things here, and the second is a thin wrapper on the first:
--
--   fn_config_value  → the whole config_settings row, so a text or jsonb key uses the same
--                      resolution as a numeric one. Adding a key stays a data change.
--   fn_config_numeric → the column almost every call site wants, with the type mismatch
--                      named out loud.
--
-- CONFIG_NOT_SET is a raise, not a null. This is the single most important line in the
-- card. A null invites `coalesce(fn_config_value(...), 0)` at a call site, and a zero rate
-- produces a settled-looking figure — the exact failure ADR-006, BR23 and BR04 exist to
-- prevent. `avg_pack_weight_kg` is the live case: fn_record_sales must refuse to price a
-- meat line until the Owner has entered one number, rather than pricing it at nothing.
--
-- p_event_date has no default either. `now()` would resolve a closed period against
-- today's rate, which is exactly what BR23 forbids, and a default is how a call site
-- inherits that without anyone writing it down.
--
-- SCOPE BEATS RECENCY. A branch row and a global row can both be in range; the branch row
-- wins even when the global row is newer. Newest-wins means an Owner editing a global
-- default silently overrides a per-branch value somebody set deliberately, and nothing on
-- any screen would show it.
--
-- EXECUTE is granted to NOBODY, the same posture as fn_post_ledger and for a related
-- reason: config_settings holds prices, and R20 says an L3 session never reads a price.
-- A grant to `authenticated` here would be a read path around the deny-all posture that
-- ^ref-12 is supposed to build deliberately, as a role-scoped view. SECURITY DEFINER
-- functions run as the owner, so every fn_record_* can call this; a session cannot.
--
-- Covered by supabase/tests/config_read_test.sql (TC-01 … TC-10).

create or replace function public.fn_config_value(
  p_key         text,
  p_event_date  date,
  p_location_id uuid default null
) returns config_settings
  language plpgsql
  stable
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_row config_settings;
begin
  if p_event_date is null then
    raise exception 'CONFIG_EVENT_DATE_REQUIRED: resolution takes the event date, never now() (R12)';
  end if;

  select * into v_row
    from config_settings
   where key = p_key
     and (scope_location_id = p_location_id or scope_location_id is null)
     and effective_from <= p_event_date
   order by (scope_location_id is not null) desc, effective_from desc
   limit 1;

  if v_row.id is null then
    raise exception 'CONFIG_NOT_SET: no dated row for key % at % (ADR-006, BR23)',
      p_key, p_event_date;
  end if;

  return v_row;
end $$;

create or replace function public.fn_config_numeric(
  p_key         text,
  p_event_date  date,
  p_location_id uuid default null
) returns numeric
  language plpgsql
  stable
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_row config_settings;
begin
  v_row := fn_config_value(p_key, p_event_date, p_location_id);

  -- A text or jsonb key asked for as a number arrives as null otherwise, and a null rate
  -- is the same failure CONFIG_NOT_SET exists to stop — one step further downstream.
  if v_row.value_numeric is null then
    raise exception 'CONFIG_WRONG_TYPE: key % resolved to a non-numeric row at %', p_key, p_event_date;
  end if;

  return v_row.value_numeric;
end $$;

-- No grant. See the header: these two are primitives for definer functions, not a read path.
revoke execute on function public.fn_config_value(text, date, uuid)   from public;
revoke execute on function public.fn_config_numeric(text, date, uuid) from public;
