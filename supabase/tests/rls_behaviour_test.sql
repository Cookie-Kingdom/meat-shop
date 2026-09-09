-- Failure-case test: a real `authenticated` session is refused. The behavioural half of
-- the deny-all posture, split out of `rls_deny_all_test.sql` by card ^ref-64.
--
-- WHY IT IS ITS OWN FILE. `--db-url` in `migrations_apply_test.sh` now runs the posture
-- sweeps against the live project, because a posture asserted only against Docker asserts
-- nothing about the database that holds the data. This half cannot go with it: it writes a
-- fixture row to prove the write is refused, and `supabase/tests/*` is never pointed at a
-- real database. Splitting is cheaper than a `\if` guard inside one file, and the split is
-- along the line that already existed — read-only catalogue queries on one side, session
-- behaviour on the other.
--
-- NEITHER HALF PROVES THE POSTURE ALONE. The catalogue can say `authenticated` holds no
-- grant while a policy hands it rows anyway; a session can be refused today because a
-- fixture happens to be missing rather than because the grant is. Two files, one test.
--
-- Everything runs in a transaction that aborts on purpose, so nothing persists.
-- Run:  psql "$DATABASE_URL" -f supabase/tests/rls_behaviour_test.sql

do $$
declare
  v_ok boolean;
begin
  set local role authenticated;

  -- `locations`, not `profiles`: ^ref-05 grants SELECT on profiles behind a self-or-Owner
  -- policy, so a claimless session there gets zero rows rather than an error. Every other
  -- table is still refused outright, and that is what this half is checking.
  v_ok := false;
  begin
    perform 1 from locations limit 1;
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'ADR-004: authenticated could read locations';

  v_ok := false;
  begin
    insert into locations (code, name_th, kind) values ('XX1', 'ทดสอบ', 'CHEF_HOUSE');
  exception when others then
    v_ok := true;
  end;
  assert v_ok, 'ADR-004: authenticated could insert into locations';

  reset role;

  raise exception 'RLS_BEHAVIOUR_TEST_PASSED';   -- the only clean way back out
end $$;
