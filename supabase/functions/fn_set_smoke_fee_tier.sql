-- Card ^ref-11 — fn_set_smoke_fee_tier. A whole band set at one effective_from (D02).
--
-- A BAND SET IS ONLY MEANINGFUL AS A SET. A gap is a property of two adjacent bands, not
-- of either one, so a per-band setter cannot see one: it would accept [0,100) today and
-- [150,∞) tomorrow and leave a 50 kg hole nobody notices until a dispatch falls in it.
-- The whole array is validated before any of it is inserted, so an invalid third band
-- writes none of the three.
--
-- BANDS ARE HALF-OPEN, [min, max). Band n's max_weight_kg must EQUAL band n+1's
-- min_weight_kg, so a 100.00 kg dispatch against [0,100) and [100,∞) lands in the SECOND
-- band. This is the same class of decision as R16's `>` vs `>=`, it changes the fee at
-- exactly the boundary weight, and it is written down here rather than left for whoever
-- writes fn_close_lot (^ref-29) to guess. Still flagged for Owner confirmation.
--
-- The top band must be open (max_weight_kg null), or a dispatch above the last boundary
-- falls off the table and gets no fee at all — silently, as a zero.
--
-- p_tiers is a jsonb array of
--   {"min_weight_kg": 0, "max_weight_kg": 100, "rate_thb": 12.50, "rate_basis": "PER_KG"}
-- with max_weight_kg null on the top band. jsonb rather than a composite type because a
-- composite type is a migration, and this card needs none.
--
-- Covered by supabase/tests/config_writers_test.sql (TC-18 … TC-24).

create or replace function public.fn_set_smoke_fee_tier(
  p_idempotency_key uuid,
  p_effective_from  date,
  p_tiers           jsonb
) returns integer
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor    uuid;
  v_band     jsonb;
  v_i        integer := 0;
  v_n        integer;
  v_min      numeric;
  v_max      numeric;
  v_rate     numeric;
  v_basis    text;
  v_prev_max numeric;
  v_prev_open boolean := false;
  v_existing jsonb;
  v_incoming jsonb;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  v_actor := fn_require_owner();

  if p_effective_from is null then
    raise exception 'CONFIG_EFFECTIVE_FROM_REQUIRED: an undated band set cannot be resolved by event date (R12)';
  end if;
  if p_tiers is null or jsonb_typeof(p_tiers) <> 'array' then
    raise exception 'TIER_SET_INVALID: p_tiers must be a jsonb array of bands, got %',
      coalesce(jsonb_typeof(p_tiers), 'null');
  end if;

  v_n := jsonb_array_length(p_tiers);
  if v_n = 0 then
    raise exception 'TIER_SET_EMPTY: a band set with no bands prices nothing';
  end if;

  ------------------------------------------------------------------ validate the whole set
  for v_band in select value from jsonb_array_elements(p_tiers)
                 order by (value ->> 'min_weight_kg')::numeric
  loop
    v_i     := v_i + 1;
    v_min   := (v_band ->> 'min_weight_kg')::numeric;
    v_max   := (v_band ->> 'max_weight_kg')::numeric;   -- null = open-ended top band
    v_rate  := (v_band ->> 'rate_thb')::numeric;
    v_basis :=  v_band ->> 'rate_basis';

    if v_min is null then
      raise exception 'TIER_MIN_REQUIRED: band % has no min_weight_kg', v_i;
    end if;
    if v_min < 0 then
      raise exception 'TIER_MIN_NEGATIVE: band % starts at %', v_i, v_min;
    end if;
    if v_rate is null or v_rate < 0 then
      raise exception 'TIER_RATE_INVALID: band % has rate_thb %', v_i, coalesce(v_rate::text, 'null');
    end if;
    if v_basis is null or v_basis not in ('PER_KG', 'FLAT') then
      raise exception 'TIER_RATE_BASIS: band % has rate_basis %, expected PER_KG or FLAT',
        v_i, coalesce(v_basis, 'null');
    end if;
    if v_max is not null and v_max <= v_min then
      raise exception 'TIER_BAND_INVERTED: band % is [%, %)', v_i, v_min, v_max;
    end if;

    if v_i = 1 then
      -- Anchored at zero, or a dispatch below the first boundary has no band.
      if v_min <> 0 then
        raise exception 'TIER_NOT_ANCHORED: the set starts at % — a dispatch under it has no band', v_min;
      end if;
    else
      -- An open band anywhere but the top swallows every band above it.
      if v_prev_open then
        raise exception 'TIER_OVERLAP: band % is open-ended and is not the top band', v_i - 1;
      end if;
      if v_prev_max < v_min then
        raise exception 'TIER_GAP: nothing prices a weight between % and %', v_prev_max, v_min;
      end if;
      if v_prev_max > v_min then
        raise exception 'TIER_OVERLAP: bands % and % both price % kg', v_i - 1, v_i, v_min;
      end if;
    end if;

    v_prev_max  := v_max;
    v_prev_open := v_max is null;
  end loop;

  if not v_prev_open then
    raise exception 'TIER_NOT_OPEN_ENDED: the top band ends at % — a heavier dispatch would fall off the table',
      v_prev_max;
  end if;

  -------------------------------------------------------- retry, or a same-day correction
  -- Same shape as fn_set_config: idempotency rides the natural unique key
  -- (effective_from, min_weight_kg), and the set is compared as a set.
  select jsonb_agg(jsonb_build_object(
           'min', min_weight_kg, 'max', max_weight_kg,
           'rate', rate_thb, 'basis', rate_basis) order by min_weight_kg)
    into v_existing
    from smoke_fee_tiers
   where effective_from = p_effective_from;

  if v_existing is not null then
    select jsonb_agg(jsonb_build_object(
             'min',  (value ->> 'min_weight_kg')::numeric(12,2),
             'max',  (value ->> 'max_weight_kg')::numeric(12,2),
             'rate', (value ->> 'rate_thb')::numeric(12,2),
             'basis', value ->> 'rate_basis')
             order by (value ->> 'min_weight_kg')::numeric)
      into v_incoming
      from jsonb_array_elements(p_tiers);

    if v_existing = v_incoming then
      return v_n;   -- a retry looks exactly like the first call succeeded (R4)
    end if;

    raise exception 'CONFIG_DUPLICATE_DATE: a different band set already exists at % — append-only has no same-day correction (BR23)',
      p_effective_from;
  end if;

  ------------------------------------------------------ all bands land, or none of them do
  insert into smoke_fee_tiers (min_weight_kg, max_weight_kg, rate_thb, rate_basis,
                               effective_from, created_by)
  select (value ->> 'min_weight_kg')::numeric,
         (value ->> 'max_weight_kg')::numeric,
         (value ->> 'rate_thb')::numeric,
          value ->> 'rate_basis',
         p_effective_from,
         v_actor
    from jsonb_array_elements(p_tiers);

  return v_n;
end $$;

revoke execute on function public.fn_set_smoke_fee_tier(uuid, date, jsonb) from public;
grant  execute on function public.fn_set_smoke_fee_tier(uuid, date, jsonb) to authenticated;
