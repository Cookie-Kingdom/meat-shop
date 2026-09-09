-- Card ^ref-39 — the branch opens its day. Nothing at a branch can be recorded until it has.
--
-- sales_lines, waste_records, thaw_records, rice_records, physical_counts and
-- branch_expenses all carry daily_report_id NOT NULL, so F10 and F11 are entirely
-- downstream of this one function.
--
-- THE OPEN ROW IS THE BUSINESS-DAY BOUNDARY (ADR-014). Not a clock and not a config number.
-- "A 01:00 entry belongs to the previous day" is true because a child row attaches to the
-- branch's one OPEN report, and daily_reports_one_open (migration ...0009) is what makes
-- "one" real. There is deliberately no shift-boundary time computed anywhere here: adding
-- one would invent a decision nobody made, and it would be wrong every time a shift starts
-- late — the day would flip at the boundary even though the branch opened after it.
--
-- NO LEDGER ROW. Opening a day moves no stock. This is the tempting mistake here the same
-- way it was at ^ref-19 — the location and the date are both in hand — and TC-19 counts
-- stock_ledger across a successful open and asserts it did not move.
--
-- NO AUDIT INSERT AND NO created_by PARAMETER. opened_by is resolved from the actor inside
-- fn_require_branch; ^ref-06's generic trigger writes the audit_log row in this same
-- transaction (R32). A second insert here would audit every shift open twice (TC-20).
--
-- NO RICE ROW. "Carries sticky rice forward" (M7A.5) does not mean this function writes to
-- rice_records. fn_record_rice (^ref-48, F11) is that table's only writer, and two writers
-- on one table is how carried_in_cooked_kg starts disagreeing with itself. The figure is
-- READ and RETURNED; ^ref-48 persists it.
--
-- `status` is not named in the insert. It takes its OPEN default, so the lifecycle's first
-- transition lives in one place and fn_close_daily_report (^ref-45) owns the second.
--
-- Covered by supabase/tests/branch_daily_test.sql (TC-10 ... TC-32) and
-- supabase/tests/branch_daily_concurrency_test.sh (TC-33, TC-34).

create or replace function public.fn_open_daily_report(
  p_idempotency_key uuid,
  p_location_id     uuid,
  p_report_date     date
) returns json
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_actor      uuid;
  v_row        daily_reports;
  v_id         uuid;
  v_kind       location_kind;
  v_rice_model rice_model;
  v_carried    numeric(12,2);
  v_open_date  date;
begin
  if p_idempotency_key is null then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED: every write RPC carries a client-generated key (R4)';
  end if;

  -- Actor, role and membership, in that order and before anything is looked up. A caller
  -- who is not assigned to this branch learns nothing about it — not even that it exists.
  v_actor := fn_require_branch(p_location_id);

  -- No default, for the reason ^ref-11 refused to default p_event_date: a function that
  -- defaults its own business date is inherited silently by every call site and is wrong on
  -- the one shift a year that starts at 00:30 — which is the one that matters (D3).
  if p_report_date is null then
    raise exception 'REPORT_DATE_REQUIRED: the business date is the caller''s to state (ADR-014, D3)';
  end if;

  -- A future date is a typo, and R5's unique key would make it permanent — the branch could
  -- never open that date again for real.
  if p_report_date > current_date then
    raise exception 'REPORT_DATE_FUTURE: cannot open %, which is after today', p_report_date;
  end if;

  -- The FK alone accepts CENTRAL and CHEF_HOUSE, and neither runs a branch shift. Asked
  -- after membership so the answer leaks nothing to a non-member.
  select kind, rice_model into v_kind, v_rice_model from locations where id = p_location_id;
  if v_kind <> 'BRANCH' then
    raise exception 'LOCATION_KIND_INVALID: % is a %, not a BRANCH', p_location_id, v_kind;
  end if;

  ------------------------------------------------------------------------- the retry check
  -- Finding 5: this card needs NO idempotency column. ^ref-19 needed one because
  -- po_deliveries.seq is derived and no natural key could carry a retry. Here R5's
  -- unique (location_id, report_date) IS the payload — a retry sends the same branch and
  -- the same date by construction, and there is no second field for a replay to disagree
  -- about. p_idempotency_key stays required and stays rejected when null so the RPC shape
  -- and the typed wrapper stay uniform across every write function (ADR-005, R38).
  select * into v_row from daily_reports
   where location_id = p_location_id and report_date = p_report_date;
  if found then
    -- A return, not a raise (R4).
    if v_row.status = 'OPEN' then
      v_id := v_row.id;
    else
      -- Not idempotency, and it must not be treated as it. Returning a CLOSED row would let
      -- a replayed call reverse a close that R13 gated on ready-stock being zero. The
      -- ...0004 `on conflict do update set status = 'OPEN'` shape is the same bug written
      -- shorter. Reopening a settled day is the unlock path (^ref-08, R28, ADR-013).
      raise exception 'REPORT_ALREADY_CLOSED: % at % is % — reopening is the unlock path (R28)',
        p_report_date, p_location_id, v_row.status;
    end if;
  else
    begin
      insert into daily_reports (location_id, report_date, shift_started_at, opened_by)
      -- shift_started_at is now(), NEVER a parameter (D4). A typed shift time is a back-date
      -- with no reason attached, and ^ref-06's trigger would record the write without
      -- recording that the time was chosen. Open Question 2 in the TDD.
      values (p_location_id, p_report_date, now(), v_actor)
      on conflict (location_id, report_date) do nothing
      returning id into v_id;

      if v_id is null then
        -- A concurrent caller won the same (location, date). Re-select and answer as a
        -- retry — TC-33. `do nothing` returns no row, which is not an error here.
        select id into v_id from daily_reports
         where location_id = p_location_id and report_date = p_report_date;
      end if;
    exception
      -- daily_reports_one_open. A DIFFERENT date is already open for this branch, which
      -- `on conflict (location_id, report_date)` cannot absorb — different key.
      when unique_violation then
        select report_date into v_open_date from daily_reports
         where location_id = p_location_id and status = 'OPEN';
        -- Never auto-close it. BR21 and ADR-014 both say close is pressed by a human, and
        -- R13 makes it a gate with a real precondition (ready stock zero). Naming the date
        -- puts the branch in front of the close screen, which is where they need to be.
        raise exception 'REPORT_STILL_OPEN: % is still open at this branch — close it first (BR21, R13)',
          v_open_date;
    end;
  end if;

  --------------------------------------------------------------------- the carry-forward
  -- M7A.5. THE MOST RECENT RICE ROW, NOT YESTERDAY'S. A branch that sold no rice on Tuesday
  -- must not have Monday's remainder vanish on Wednesday. Same shape as R12's config
  -- resolution and for the same reason.
  select cooked_remaining_kg into v_carried
    from rice_records
   where location_id = p_location_id
     and event_date  < p_report_date
   order by event_date desc
   limit 1;

  -- No coalesce, here or at the call site. null means "nobody has recorded rice at this
  -- branch yet"; 0 means "the branch has no rice left". Collapsing the two is exactly the
  -- failure BR23 and ADR-006 exist to prevent, and BR 01 renders them differently (TC-27).
  select * into v_row from daily_reports where id = v_id;

  return json_build_object(
    'daily_report_id',      v_row.id,
    'report_date',          v_row.report_date,
    'shift_started_at',     v_row.shift_started_at,
    'carried_in_cooked_kg', v_carried,
    -- Read from locations so ^ref-41's BR 01 checklist can render the M7A or M7B form
    -- without a second round trip. May be null: the CHECK allows a BRANCH row with no
    -- model. Returned as null rather than raising — the day still has to open, and the
    -- screen shows the config gap instead of guessing a model (Open Question 5).
    'rice_model',           v_rice_model
  );
end $$;

revoke execute on function public.fn_open_daily_report(uuid, uuid, date) from public, anon, authenticated;
grant  execute on function public.fn_open_daily_report(uuid, uuid, date) to authenticated;
