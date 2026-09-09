-- Local test harness. NOT part of the schema and never applied to a Supabase project.
--
-- Supabase provides the `auth` schema and the anon / authenticated / service_role roles
-- before any of our migrations run. A bare Postgres container does not, so the
-- migrations cannot be applied — and therefore cannot be tested — without this.
-- It creates the smallest surface our migrations actually touch, and nothing else:
--
--   * roles anon, authenticated, service_role
--   * schema auth
--   * auth.users, with the columns `schema_smoke_test.sql` inserts
--   * public.rls_auto_enable(), the "pre-existing project helper" that migration
--     0006 revokes execute on but no migration creates (see FINDINGS in
--     `rls_deny_all_test.sql`)
--
-- Run against an empty database, before the migrations:
--   psql "$DATABASE_URL" -f supabase/tests/local_harness.sql

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

grant usage on schema public to anon, authenticated, service_role;

create schema if not exists auth;

create table auth.users (
  id          uuid primary key,
  instance_id uuid,
  aud         varchar(255),
  role        varchar(255),
  email       varchar(255),
  created_at  timestamptz,
  updated_at  timestamptz
);

-- Stand-in for the Supabase helper, in the shape the real one has: the JWT subject out of
-- the `request.jwt.claims` GUC that PostgREST sets per request. It was a null-returning
-- stub while nothing read it; `^ref-05`'s policies do, and a stub that always returns null
-- makes every policy test vacuously pass. A test sets the caller with
--   set local request.jwt.claims = '{"sub":"<uuid>"}';
-- and resets it by setting the GUC to '' — outside a request there is no claim, which is
-- exactly what an anon session sees.
create function auth.uid() returns uuid language sql stable as $$
  select (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;

-- The helper migration 0006 revokes execute on. It exists in the live project but in no
-- migration, so a fresh apply has nothing to revoke from. Recreating it here lets the
-- migration chain be tested; it does not make the chain reproducible. That is the bug.
create function public.rls_auto_enable() returns event_trigger language plpgsql as $$
begin
  null;
end $$;
