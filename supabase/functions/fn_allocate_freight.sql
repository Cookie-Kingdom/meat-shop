-- Card ^ref-23 — fn_allocate_freight. The fare on the vehicle becomes a cost on each lot
-- (R24, ADR-012, BR16, D04.1).
--
-- THE REMAINDER IS THE ONLY PART OF THIS THAT IS NOT ARITHMETIC. Three shares of a 100 THB
-- run across three 1 kg lines are 33.33 each and sum to 99.99. R24 says the rounded shares
-- must sum back to run_cost_thb TO THE SATANG, and that the remainder lands on the largest
-- line. A satang short on every run is a cost of goods that drifts a few hundred baht a
-- year and reconciles against nothing — the kind of error F13 surfaces two quarters later
-- as "the numbers are close but they never tie".
--
-- Ties break on the smallest id, and that tiebreak is not a nicety. This function is
-- re-runnable, so an order that depended on row order would move a satang between two lots
-- on every recompute — a lot cost that changes when nobody changed anything (TC-30).
--
-- THE METHOD IS READ OFF THE RUN, NEVER FROM CONFIG AT CALL TIME. That is the whole of R29:
-- fn_create_transport_run snapshotted it at run creation, and a config change made
-- afterwards must not move a number that is already closed (BR23, TC-06).
--
-- ZERO IS TWO DIFFERENT FACTS, DEPENDING ON THE ROUTE. run_cost_thb defaults to 0, and on a
-- CENTRAL_TO_BRANCH run that 0 is correct and required (R25) — the branch leg carries no
-- freight and its lines' shares stay null. On any other route, 0 means nobody typed the fare
-- in, and allocating it would write 0.00 on every line, sum back to 0.00 exactly, and pass
-- R24's reconciliation while being wrong (Finding 6). One returns quietly, the other raises.
--
-- MANUAL REFUSES. The Owner types the shares on OW 02 and this function's job would be to
-- assert they sum to the fare, not to invent them. MANUAL falling through to the automatic
-- path silently produces a BY_LOT_WEIGHT split wearing a MANUAL label.
--
-- A ROUND TRIP IS CHARGED ONCE (BR16, D04.1). The fare on the run IS the round-trip fare
-- when is_round_trip is set; there is no doubling and no halving anywhere in this function.
-- The way this schema honours the rule is that one run row holds one fare. A return leg
-- booked as its own CM_TO_FOODIVA run with its own fare is two charges and is correct — two
-- vehicles went.
--
-- THE RECONCILIATION IS ASSERTED HERE, NOT ONLY IN A TEST. A rule checked only in the suite
-- is checked on a developer's machine and not in Chiang Mai. The mutation that proves the
-- assert is live: delete the remainder term from the UPDATE below and TC-29 stops failing on
-- a wrong number — it fails on FREIGHT_RECONCILE_FAILED, which is TC-35.
--
-- p_idempotency_key IS TAKEN AND NOT STORED, and that is deliberate rather than an omission.
-- Every write RPC carries one so the TypeScript wrapper shape is uniform (ADR-005), but this
-- function inserts nothing: it recomputes every share on the run from the run's own fare and
-- weights and overwrites them. A replay writes the same numbers, which is what idempotent
-- means. There is no second row it could create, so there is nothing for a stored key to
-- prevent. Re-running deliberately IS supported — the fare or the line set may legitimately
-- change before the run is closed, and this function is the only writer of
-- freight_share_thb.
--
-- Covered by supabase/tests/transport_test.sql (TC-29 ... TC-36).

create or replace function public.fn_allocate_freight(
  p_idempotency_key uuid,
  p_run_id          uuid
) returns numeric
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
  v_run   transport_runs;
  v_n     bigint;
  v_total numeric(12,2);
  v_check numeric(12,2);
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  v_actor := fn_require_owner();

  select * into v_run from transport_runs where id = p_run_id for update;
  if not found then
    raise exception 'RUN_NOT_FOUND: no transport run %', p_run_id;
  end if;

  -- R25. Not an error, and not an allocation either: the branch leg is free, so there is
  -- nothing to split and the shares stay null rather than becoming a row of honest-looking
  -- zeroes (TC-33).
  if v_run.route = 'CENTRAL_TO_BRANCH' then
    return 0;
  end if;

  if v_run.run_cost_thb = 0 then
    raise exception 'RUN_FARE_NOT_SET: run % is a % run with no fare — 0 is the branch leg''s answer, not this one (Finding 6, R25)',
      p_run_id, v_run.route;
  end if;

  if v_run.alloc_method = 'MANUAL' then
    raise exception 'MANUAL_ALLOC_NOT_AUTOMATIC: run % snapshotted MANUAL — the Owner enters the shares and they are asserted, not invented (ADR-012)',
      p_run_id;
  end if;

  select count(*), coalesce(sum(dispatched_weight_kg), 0)
    into v_n, v_total
    from transport_lines
   where run_id = p_run_id;

  if v_n = 0 then
    raise exception 'RUN_HAS_NO_LINES: run % carries a % THB fare and nothing to split it across',
      p_run_id, v_run.run_cost_thb;
  end if;

  ------------------------------------------------------------------------------ the split
  -- One statement, so the shares and the remainder are computed against the same snapshot
  -- of the lines. rn = 1 is the largest line by dispatched weight, ties broken by the
  -- smallest id — the deterministic home for the satang R24 leaves over.
  with computed as (
    select id,
           case when v_run.alloc_method = 'BY_LOT_WEIGHT'
                then round(v_run.run_cost_thb * dispatched_weight_kg / v_total, 2)
                else round(v_run.run_cost_thb / v_n, 2)
           end as share,
           row_number() over (order by dispatched_weight_kg desc, id) as rn
      from transport_lines
     where run_id = p_run_id
  ),
  totalled as (
    select id, share, rn, sum(share) over () as sum_share from computed
  )
  update transport_lines t
     set freight_share_thb = tt.share
                           + case when tt.rn = 1 then v_run.run_cost_thb - tt.sum_share else 0 end
    from totalled tt
   where tt.id = t.id;

  ---------------------------------------------------------------------- R24, in the database
  select coalesce(sum(freight_share_thb), 0) into v_check
    from transport_lines where run_id = p_run_id;

  if v_check <> v_run.run_cost_thb then
    raise exception 'FREIGHT_RECONCILE_FAILED: shares sum to % against a fare of % on run % (R24)',
      v_check, v_run.run_cost_thb, p_run_id;
  end if;

  return v_run.run_cost_thb;
end $$;

revoke execute on function public.fn_allocate_freight(uuid, uuid) from public, anon, authenticated;
grant  execute on function public.fn_allocate_freight(uuid, uuid) to authenticated;
