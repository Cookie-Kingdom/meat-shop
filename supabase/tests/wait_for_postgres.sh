# Sourced, not run. Every supabase/tests/*_test.sh runner calls wait_for_postgres right after
# its `docker run` (^fix-startup-race). The file name deliberately does not match *_test.sh,
# so the sibling loop in migrations_apply_test.sh never executes it as a test.
#
# WHY TCP. The postgres image runs initdb, starts a TEMPORARY server to run its init scripts,
# then stops that server and starts the real one. The temporary server listens on the unix
# socket only (listen_addresses=''), and it has already created POSTGRES_DB by the time it
# stops. So `select 1` on our own database over the socket can succeed against the temporary
# server, and the runner's next psql call is dropped by the restart. That surfaced as
# `FAIL local_harness.sql` with no visible error, about one run in two on a fast disk. Only
# the final server listens on TCP, so a query over 127.0.0.1 cannot pass early.
#
# The password is the one every runner passes as POSTGRES_PASSWORD. The image's pg_hba trusts
# the socket but asks for a password over TCP.
#
# Usage, from the repo root (every runner has already done `cd "$(dirname "$0")/../.."`):
#   . supabase/tests/wait_for_postgres.sh
#   wait_for_postgres "$CONTAINER" || exit 1

wait_for_postgres() {
  local container="$1"
  for _ in $(seq 1 60); do
    docker exec -e PGPASSWORD=postgres "$container" \
      psql -h 127.0.0.1 -U postgres -d meatshop -Atqc 'select 1' >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "FAIL  postgres:17 never answered a query over TCP within 60s"
  return 1
}
