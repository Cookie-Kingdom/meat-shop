-- Card ^ref-62 — fn_config_date. The third typed reader over fn_config_value.
--
-- Exists for fn_config_boolean's reason, one type along: `config_settings` has
-- value_numeric, value_text and value_json and no date column, so `opening_cutoff_date` —
-- the go-live cut-off ADR-021 turned into a config value — has nowhere to live but text.
-- Someone has to cast it, and the choice is here or inside fn_record_opening_balance.
--
-- Here, because a cast inside a business function is a config rule with no name: the day
-- ^ref-61's readiness view wants to show the same date, it re-derives the same cast and the
-- two can disagree about what a malformed value means. One function, one place it can rot.
--
-- A malformed date is CONFIG_WRONG_TYPE, not a null and not a caught-and-defaulted today().
-- ADR-023 and BR23: an unset or unusable Owner value is a named refusal that reaches the
-- screen, never a figure the system made up. fn_config_value already raises CONFIG_NOT_SET
-- when no dated row resolves; this adds the case where a row resolves and cannot be read as
-- a date.
--
-- NO_ACTOR is inherited from fn_config_value, not repeated: the call is the first statement
-- of the body and nothing is reached before that guard fires (^ref-64).
--
-- EXECUTE is granted to NOBODY, the same posture as its two siblings and for the same
-- reason: config_settings holds prices, R20 says an L3 session never reads one, and a grant
-- here would be a read path around the deny-all posture that ^ref-12 built deliberately.
-- SECURITY DEFINER callers run as the owner, so every fn_record_* can call this; a session
-- cannot. Named in sweep 1f of rls_deny_all_test.sql, which is a list and not a pattern.

create or replace function public.fn_config_date(
  p_key         text,
  p_event_date  date,
  p_location_id uuid default null
) returns date
  language plpgsql
  stable
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_row config_settings;
begin
  v_row := fn_config_value(p_key, p_event_date, p_location_id);

  if v_row.value_text is not null then
    begin
      return v_row.value_text::date;
    exception when invalid_datetime_format or datetime_field_overflow then
      raise exception 'CONFIG_WRONG_TYPE: key % is text % at %, which is not a date',
        p_key, v_row.value_text, p_event_date;
    end;
  end if;

  if v_row.value_json is not null then
    if jsonb_typeof(v_row.value_json) <> 'string' then
      raise exception 'CONFIG_WRONG_TYPE: key % is json % at %, which is not a date',
        p_key, v_row.value_json, p_event_date;
    end if;
    begin
      return (v_row.value_json #>> '{}')::date;
    exception when invalid_datetime_format or datetime_field_overflow then
      raise exception 'CONFIG_WRONG_TYPE: key % is json % at %, which is not a date',
        p_key, v_row.value_json, p_event_date;
    end;
  end if;

  -- value_numeric. There is no reading of a number as a date that is not a guess: 20261001
  -- and an epoch day count are both plausible and mean different years. Guessing which is
  -- how a cut-off silently moves.
  raise exception 'CONFIG_WRONG_TYPE: key % resolved to a non-date row at %',
    p_key, p_event_date;
end $$;

revoke execute on function public.fn_config_date(text, date, uuid) from public, anon, authenticated;
