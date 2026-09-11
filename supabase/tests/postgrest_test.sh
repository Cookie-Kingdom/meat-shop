#!/usr/bin/env bash
# Card ^ref-71 — grants, RLS and the error shape over the real request path: a signed JWT ->
# PostgREST -> request.jwt.claims -> RLS. Every *_test.sql sets that GUC by hand, so none of
# them proves PostgREST sets it the same way (UAT-15, v0.2:441 "ตรวจ API"). Cases IT-H01…H07
# are in postgrest_test.mjs; the table is PLAN-integration-tests.md §^ref-71.
#
#   bash supabase/tests/postgrest_test.sh
#
# postgres:17 and PostgREST on a private Docker network. Only PostgREST's port is published,
# on 127.0.0.1. The JWT secret is minted per run and lives only in this process's environment.
# Both containers and the network are removed on exit, pass or fail.

set -uo pipefail
cd "$(dirname "$0")/../.."

DB=meatshop-postgrest-test-db
API=meatshop-postgrest-test-api
NET=meatshop-postgrest-test
# The tag supabase/docker/docker-compose.yml pins (11 Sep 2026): the PostgREST a self-hosted
# Supabase runs, and the one ^ref-72's stack extends.
IMAGE=postgrest/postgrest:v14.17
PSQL=(docker exec -i "$DB" psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1)

cleanup() {
  docker rm -f "$API" "$DB" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  true
}
trap cleanup EXIT
cleanup

docker network create "$NET" >/dev/null || { echo "FAIL  could not create network $NET"; exit 1; }
docker run -d --name "$DB" --network "$NET" --network-alias db \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=meatshop postgres:17 >/dev/null ||
  { echo "FAIL  could not start postgres:17"; exit 1; }
# Wait for the FINAL server over TCP, not the init server on the socket (^fix-startup-race).
. supabase/tests/wait_for_postgres.sh
wait_for_postgres "$DB" || exit 1

"${PSQL[@]}" < supabase/tests/local_harness.sql >/dev/null 2>&1 || { echo "FAIL  local_harness.sql"; exit 1; }

# The role PostgREST logs in as. Supabase supplies it and local_harness.sql does not; that file
# stays untouched, so it is created here. noinherit: it holds no privilege of its own, only the
# right to SET ROLE to whichever of anon / authenticated the request names. The password never
# leaves the private network, because the database port is not published.
"${PSQL[@]}" -c "create role authenticator login noinherit password 'authenticator';
                 grant anon, authenticated to authenticator;" >/dev/null 2>&1 ||
  { echo "FAIL  authenticator role"; exit 1; }

for f in supabase/migrations/*.sql supabase/functions/*.sql supabase/views/*.sql supabase/policies/*.sql; do
  [ -e "$f" ] || continue
  "${PSQL[@]}" < "$f" >/dev/null 2>&1 || { echo "FAIL  applying $(basename "$f")"; exit 1; }
done

# Fixtures, committed. The demo's own seed, so there is no third seed: four personas, two
# branches, lots A (central), B (smoking) and C (on the truck). The seed looks its users up in
# auth.users, which reset.sh fills through GoTrue and this file fills directly.
"${PSQL[@]}" -c "insert into auth.users (id, email)
                 select gen_random_uuid(), 'demo-' || k || '@demo.local'
                   from unnest(array['owner', 'chef', 'salaeng', 'minburi']) k;" >/dev/null 2>&1 ||
  { echo "FAIL  fixtures: auth.users"; exit 1; }
out=$("${PSQL[@]}" < supabase/demo/seed.sql 2>&1) ||
  { echo "FAIL  fixtures: seed.sql"; echo "$out" | sed 's/^/      /' | head -5; exit 1; }

# The seed leaves both branches empty on purpose. IT-H03 needs rows at both to keep apart, so
# each branch admin counts opening meat at their own branch and opens today's report, through
# the real writers.
out=$("${PSQL[@]}" 2>&1 <<'SQL'
do $$
declare
  b record;
begin
  for b in select ul.profile_id, l.id, l.code
             from user_locations ul join locations l on l.id = ul.location_id
            where l.kind = 'BRANCH'
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', b.profile_id)::text, true);
    perform fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', b.id, 5.00, current_date,
                                      p_lot_code => 'OPEN-' || b.code, p_smoke_date => current_date - 7);
    perform fn_open_daily_report(gen_random_uuid(), b.id, current_date);
  end loop;
end $$;
SQL
) || { echo "FAIL  fixtures: branch opening"; echo "$out" | sed 's/^/      /' | head -5; exit 1; }

# PostgREST starts after the schema, so its first schema-cache load already sees every function.
PGRST_JWT_SECRET=$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')
export PGRST_JWT_SECRET
docker run -d --name "$API" --network "$NET" -p 127.0.0.1::3000 \
  -e PGRST_DB_URI=postgres://authenticator:authenticator@db:5432/meatshop \
  -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon -e PGRST_JWT_SECRET \
  "$IMAGE" >/dev/null || { echo "FAIL  could not start $IMAGE"; exit 1; }

# The warning is Node reparsing result.ts as ESM, because package.json names no "type".
PGRST_URL="http://$(docker port "$API" 3000/tcp | head -1)" PG_CONTAINER="$DB" \
  node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON supabase/tests/postgrest_test.mjs
