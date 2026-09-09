-- Card ^ref-11 — fn_set_config. A new dated config row, never an update. Ever.
--
-- ADR-006's shape: the previous row is not closed off, it is simply older. Anything that
-- writes to an existing row — an effective_to, a current_value, an UPDATE — silently
-- rewrites whatever a closed period already reported (BR23).
--
-- IDEMPOTENCY RIDES THE NATURAL UNIQUE KEY. R4 names an rpc_calls table plus an
-- idempotency_key column; no migration creates either, and none of the four config tables
-- has anywhere to store a key. What they all have is a unique key that already includes
-- the date. So:
--
--   same key/scope/date, SAME value      → returns the existing id, writes nothing. A
--                                          retry from a dropped connection has to look
--                                          exactly like the first call succeeded (R4).
--   same key/scope/date, DIFFERENT value → CONFIG_DUPLICATE_DATE. That is not a retry, it
--                                          is a same-day correction, and append-only has
--                                          no answer for one. Refusing is the safe
--                                          direction — nothing is silently rewritten — but
--                                          it is an Owner-facing rule nobody has agreed
--                                          to yet. Open Question in TDD-config-layer.md.
--
-- p_idempotency_key is still required and still rejected when null, so the RPC contract
-- and the TypeScript wrapper shape stay uniform across every write in the system (ADR-005).
-- It is not stored, because there is no column to store it in.
--
-- Covered by supabase/tests/config_writers_test.sql (TC-11 … TC-17).

create or replace function public.fn_set_config(
  p_idempotency_key   uuid,
  p_key               text,
  p_effective_from    date,
  p_value_numeric     numeric default null,
  p_value_text        text    default null,
  p_value_json        jsonb   default null,
  p_scope_location_id uuid    default null,
  p_note              text    default null
) returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_id    uuid;
  v_row   config_settings;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  v_actor := fn_require_owner();

  if coalesce(btrim(p_key), '') = '' then
    raise exception 'CONFIG_KEY_REQUIRED: a config row with no key resolves for nobody';
  end if;
  if p_effective_from is null then
    raise exception 'CONFIG_EFFECTIVE_FROM_REQUIRED: an undated row cannot be resolved by event date (R12)';
  end if;

  -- config_settings_one_value enforces this at the row level, which is the right guard and
  -- a terrible error message. Name the columns instead, so the Owner sees which two they
  -- sent rather than a constraint name.
  if num_nonnulls(p_value_numeric, p_value_text, p_value_json) <> 1 then
    raise exception 'CONFIG_ONE_VALUE: exactly one of numeric/text/json, got numeric=%, text=%, json=%',
      p_value_numeric, p_value_text, p_value_json;
  end if;

  insert into config_settings (
    key, scope_location_id, value_numeric, value_text, value_json,
    effective_from, created_by, note)
  values (
    p_key, p_scope_location_id, p_value_numeric, p_value_text, p_value_json,
    p_effective_from, v_actor, p_note)
  -- The index expression, spelled the way the index spells it, or inference fails.
  on conflict (key, coalesce(scope_location_id, '00000000-0000-0000-0000-000000000000'::uuid),
               effective_from) do nothing
  returning id into v_id;

  if v_id is not null then
    return v_id;
  end if;

  -- The slot is taken. Whether this is a retry or a correction is decided by the value.
  select * into v_row
    from config_settings
   where key = p_key
     and scope_location_id is not distinct from p_scope_location_id
     and effective_from = p_effective_from;

  if v_row.value_numeric is not distinct from p_value_numeric
     and v_row.value_text is not distinct from p_value_text
     and v_row.value_json is not distinct from p_value_json then
    return v_row.id;
  end if;

  raise exception 'CONFIG_DUPLICATE_DATE: key % already has a different value at % — append-only has no same-day correction (BR23)',
    p_key, p_effective_from;
end $$;

revoke execute on function public.fn_set_config(uuid, text, date, numeric, text, jsonb, uuid, text) from public, anon, authenticated;
grant  execute on function public.fn_set_config(uuid, text, date, numeric, text, jsonb, uuid, text) to authenticated;
