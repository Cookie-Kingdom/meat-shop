-- Card ^ref-22 — the boolean arm of ^ref-11's config resolution.
--
-- config_settings holds value_numeric, value_text and value_json and exactly one of them is
-- non-null (config_settings_one_value). ^ref-11 shipped fn_config_numeric as "the only typed
-- wrapper" because numeric was the only type any call site needed. F5 is the first card that
-- needs a boolean — partial_receipt_allowed and receipt_variance_requires_reason are both
-- flagged `boolean` in API_DATA_MODEL.md's config table and there is no value_boolean column
-- for them to live in.
--
-- WHY A FUNCTION RATHER THAN A CAST AT THE CALL SITE. fn_confirm_transport_receipt reads two
-- boolean keys, and the cast ladder below is six lines: an Owner may have entered `true`,
-- `"true"` or `1` depending on which screen wrote the row, and a call site that only handles
-- the shape it happened to meet first fails on the other two. Written twice it is two places
-- to get wrong; written per call site across F8, F9 and F11 it is a dozen. Same argument
-- fn_config_numeric made, one type along.
--
-- ^ref-11's file is deliberately not edited. This is a new key type, not a correction to
-- that card, and the two stay separately attributable.
--
-- The posture is fn_config_numeric's, for fn_config_numeric's reason: EXECUTE is granted to
-- NOBODY. config_settings holds prices and R20 keeps an L3 session out of them, so a grant
-- here would be a read path around the deny-all posture ^ref-12 built deliberately. Every
-- legitimate caller is a SECURITY DEFINER fn_* and can call it; a session cannot.
--
-- CONFIG_NOT_SET propagates from fn_config_value and is never defaulted to false. A missing
-- flag read as false is a rule silently switched off — the exact failure ADR-006 and BR23
-- exist to prevent, and worse for a flag than for a rate, because a false rate is visibly
-- zero and a false flag looks like a decision.

create or replace function public.fn_config_boolean(
  p_key         text,
  p_event_date  date,
  p_location_id uuid default null
) returns boolean
  language plpgsql
  stable
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_row config_settings;
begin
  -- NO_ACTOR is inherited from fn_config_value, not repeated: this is the first statement of
  -- the body and it reaches nothing before that guard fires (^ref-64).
  v_row := fn_config_value(p_key, p_event_date, p_location_id);

  if v_row.value_text is not null then
    begin
      return v_row.value_text::boolean;
    exception when invalid_text_representation then
      raise exception 'CONFIG_WRONG_TYPE: key % is text % at %, which is not a boolean',
        p_key, v_row.value_text, p_event_date;
    end;
  end if;

  if v_row.value_json is not null then
    if jsonb_typeof(v_row.value_json) <> 'boolean' then
      raise exception 'CONFIG_WRONG_TYPE: key % is json % at %, which is not a boolean',
        p_key, v_row.value_json, p_event_date;
    end if;
    return (v_row.value_json #>> '{}')::boolean;
  end if;

  -- 1 and 0 are how a numeric-only writer would have stored a flag. Anything else is a
  -- number that someone has decided means true, and guessing which way is how a rule
  -- silently inverts.
  if v_row.value_numeric in (0, 1) then
    return v_row.value_numeric = 1;
  end if;

  raise exception 'CONFIG_WRONG_TYPE: key % resolved to a non-boolean row at %',
    p_key, p_event_date;
end $$;

-- No grant. See the header: a primitive for definer functions, not a read path.
revoke execute on function public.fn_config_boolean(text, date, uuid) from public, anon, authenticated;
