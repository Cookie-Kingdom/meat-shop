-- Card ^ref-38 — the three things daily_reports was missing.
--
-- Three statements, Findings 1, 3 and 4 from TDD-branch-daily-open.md. Nothing else moves.
-- The tables themselves were created in ...0004; this is not a create, it is the gap
-- between what that migration wrote and what ADR-007 and ADR-014 need.
--
-- APPLY ORDER HAZARD, carried over from ^ref-19 and still true: ...0007 and ...0008 are in
-- this repo and NOT applied to the live project. ^ref-63 owns the one-apply-path question.
-- Do not hand-apply this ahead of them and do not interleave — run the chain through
-- supabase/tests/migrations_apply_test.sh against Docker until ^ref-63 lands.

-- Finding 1 — the third clock (ADR-007).
--
-- report_date is the business date and shift_started_at is the event clock (the ER calls
-- it "what makes report_date decidable"). There was no created_at, and API_DATA_MODEL.md
-- §3's ER omitted it too — doc and schema agreeing with each other and both disagreeing
-- with the ADR, which means neither was an observation of a decision anybody made.
--
-- This is the opposite of ^ref-18's case. There, ADR-007's prose was over-broad and the
-- schema was right, so the ADR was narrowed. Here the ADR was right and the schema was
-- short. Do NOT widen ADR-007 off the back of this migration.
--
-- A row that cannot say when it was physically written cannot be reconciled against
-- audit_log when a back-dated open is disputed, which is what three clocks are for.
alter table daily_reports add column created_at timestamptz not null default now();

-- Finding 3 — shift_started_at is the column the whole rule rests on.
--
-- Null shift_started_at makes ADR-014 undecidable for that row: there is no shift open to
-- run the day from. fn_open_daily_report is the table's only writer and always sets now(),
-- and the table is empty in every environment, so this is free now and a data migration
-- later.
alter table daily_reports alter column shift_started_at set not null;

-- Finding 4 — the one-open-day invariant, which is the MECHANISM and not a nicety.
--
-- ADR-014's "a 01:00 entry belongs to the previous day" is not arithmetic. There is no
-- shift-boundary time anywhere in this schema, and business_day_shift_rule is a `text`
-- config key describing the rule in words with no number in it. The rule is true because a
-- child row attaches to the branch's OPEN report and there is exactly one of those. A
-- 01:00 sale finds yesterday's report still open and lands on it. That is the entire
-- implementation of ADR-014, and it is correct only if "exactly one" is enforced here.
--
-- ...0004:57 created daily_reports_open as a PLAIN index on (location_id, report_date)
-- where status <> 'CLOSED'. R5's unique (location_id, report_date) stops the same branch
-- opening the same date twice; nothing stopped Monday and Tuesday being open together.
--
-- THE PREDICATE IS A CONTRACT. `status = 'OPEN'`, never `status <> 'CLOSED'`: UNLOCKED is
-- a past day reopened under R28/ADR-013 and must be able to coexist with today's open day.
-- A <> 'CLOSED' predicate would make unlocking yesterday impossible the moment today is
-- open — precisely the situation in which somebody wants to. ^ref-08 builds the unlock
-- path against this predicate; changing it breaks unlock, not this card.
--
-- The existing daily_reports_open index is left alone. It is a lookup index on a different
-- key and predicate, and dropping it is a second decision this card was not asked to make.
create unique index daily_reports_one_open
  on daily_reports (location_id) where status = 'OPEN';

comment on index daily_reports_one_open is
  'ADR-014 implemented. Exactly one OPEN report per branch is what makes a 01:00 entry land '
  'on the previous day — the open row IS the business-day boundary, not a clock. Predicate '
  'is status = ''OPEN'' so an UNLOCKED past day (R28, ADR-013) can coexist with today.';
