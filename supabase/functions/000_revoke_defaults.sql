-- Card ^ref-64 — undo the default grants. THIS FILE DEFINES NO FUNCTION.
--
-- It sits in `functions/` because of *when* it must run, not because of what it is.
-- `apply_state_folders()` globs functions/ then views/ then policies/ (R33), and within a
-- folder the glob is alphabetical — so `000_` here is the first statement of the whole
-- state apply, before any `create or replace function` and long before any view. Every
-- per-file `grant` that follows is therefore the last word. A `policies/000_grants.sql`
-- would run *last* and revoke them all again; that is the only reason this is not there.
--
-- THERE ARE TWO DEFAULT GRANTS, FROM TWO DIFFERENT PLACES, AND THE CARD ONLY KNEW ABOUT
-- ONE OF THEM.
--
--   1. `pg_default_acl`, which Supabase ships: a grant to `anon` and `authenticated` BY
--      NAME on every relation and function `postgres` creates in `public`. This is the
--      one the card found. `revoke … from public` removes the implicit PUBLIC privilege
--      and does NOT remove a named-role grant, so every revoke in this folder was real
--      against Docker — which has no default ACLs — and inert against the live project.
--
--   2. Plain PostgreSQL: `EXECUTE` on a new function is granted to `PUBLIC`, always,
--      everywhere. `anon` is a member of PUBLIC, so it holds EXECUTE through that route
--      even where no named grant exists. This one is not a Supabase behaviour and it is
--      not visible in `information_schema.routine_privileges` either. It surfaced when
--      sweep 1e went red against Docker on the five trigger functions and the harness's
--      `rls_auto_enable`, none of which had a revoke line — a trigger fires as the table
--      owner, so nobody had thought one was needed. Three of the five are created in
--      migrations and this sweep is their revoke; the two in fn_audit_row.sql are created
--      after it and got a line of their own.
--
-- So the revoke names all three roles. Dropping `public` from the list is what a reviewer
-- would call tidying, and it re-opens every trigger function to `anon`.
--
-- WHAT EACH HALF ACTUALLY COVERS. Measured, not assumed (^ref-64):
--
--   * The sweep covers everything that already exists when this file runs — the trigger
--     functions created inside migrations …0003 and …0004 (fn_rollup_smoke_log_input,
--     fn_require_lot_for_meat, fn_stock_ledger_append_only) and, live, every function and
--     relation that arrived carrying Supabase's named-role default grant.
--
--   * `alter default privileges` covers case 1 only, for objects created LATER. ADP REVOKE
--     removes an entry from an existing default ACL, which is exactly what Supabase's
--     named grant is. It CANNOT remove case 2: PostgreSQL's built-in `EXECUTE to PUBLIC`
--     on a new function is not a default-ACL entry and no ADP statement can pre-empt it.
--     On postgres:17, after the two ADP statements below, `pg_default_acl` holds ZERO rows
--     and a freshly created function is still executable by `anon` — the row is dropped
--     because the result equals the built-in default, and the built-in default is the
--     problem. Relations are unaffected: tables and views have no built-in PUBLIC grant.
--
-- SO EVERY FUNCTION FILE STILL CARRIES ITS OWN REVOKE LINE, including the ones granted to
-- nobody and including trigger functions (see the foot of fn_audit_row.sql). This file
-- does not make that unnecessary and must not be read as if it did. What it does is make
-- the live project start from the same place Docker does. Sweep 1e is what catches the
-- next file that forgets its line — it is not a belt-and-braces assert, it is the only
-- thing standing between a new function and `anon`.
--
-- Nothing in this repo creates an extension in `public` (checked, ^ref-64), so the
-- schema-wide sweep has no third-party function to catch in the blast radius.
--
-- Asserted by rls_deny_all_test.sql sweeps 1b, 1e, 1f and 1g, run against BOTH targets.
-- Delete this file and 1e goes red against live and stays green against Docker — which is
-- the defect the card is about, turned into a test.

revoke execute on all functions in schema public from public, anon, authenticated;
revoke all      on all tables    in schema public from public, anon, authenticated;

-- `for role postgres`: the role that owns everything this repo creates, in both targets —
-- Docker connects as `postgres`, and the live pooler user maps to it. A default ACL is
-- recorded per granting role, so naming the wrong one writes a rule that never fires.
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on tables from public, anon, authenticated;
