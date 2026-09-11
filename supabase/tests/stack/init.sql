-- Card ^ref-72 — what Supabase's own Postgres image creates before GoTrue and our migrations
-- run, for the local stack in compose.yml. Runs once, from /docker-entrypoint-initdb.d.
--
-- This is local_harness.sql's job with one difference: GoTrue owns the `auth` schema here, so
-- auth.users and auth.uid() are GoTrue's real ones (its migrations), not the harness stubs.
-- local_harness.sql stays as it is, because every *_test.sql depends on it.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
grant usage on schema public to anon, authenticated, service_role;

-- PostgREST logs in as this and SET ROLEs to whatever the JWT names (as in postgrest_test.sh).
create role authenticator login noinherit password 'authenticator';
grant anon, authenticated, service_role to authenticator;

-- GoTrue's own bootstrap, from supabase/auth hack/init_postgres.sql at v2.196.0.
create role supabase_auth_admin login noinherit createrole password 'auth';
create schema auth authorization supabase_auth_admin;
grant create on database meatshop to supabase_auth_admin;
alter role supabase_auth_admin set search_path = auth;
-- A policy that calls auth.uid() runs as the caller, so the caller needs the schema. The
-- hosted project grants this; the harness never had to, because its auth schema was postgres's.
grant usage on schema auth to anon, authenticated, service_role;

-- The helper migration 0006 revokes execute on (see local_harness.sql).
create function public.rls_auto_enable() returns event_trigger language plpgsql as $$
begin
  null;
end $$;
