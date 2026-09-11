#!/usr/bin/env bash
# Card ^ref-72 T1 — bring up the stack in compose.yml, apply the schema in the harness's order,
# and seed it the way reset.sh seeds meat-shop-demo: the four users through GoTrue's admin API,
# then supabase/demo/seed.sql and seed_check.sql. No third seed.
#
#   JWT_SECRET=… SERVICE_ROLE_KEY=… DEMO_USER_PASSWORD=… bash supabase/tests/stack/up.sh
#
# e2e/run.sh mints all three, calls this, and takes the stack down afterwards.

set -uo pipefail
cd "$(dirname "$0")/../../.."

for v in JWT_SECRET SERVICE_ROLE_KEY DEMO_USER_PASSWORD; do
  [ -n "${!v:-}" ] || { echo "FAIL  $v is not set"; exit 2; }
done
export JWT_SECRET

COMPOSE=(docker compose -f supabase/tests/stack/compose.yml)
PSQL=("${COMPOSE[@]}" exec -T db psql -U postgres -d meatshop -q -v ON_ERROR_STOP=1)
API="http://127.0.0.1:${E2E_API_PORT:-54380}"

# A run killed before its trap leaves a stack behind, and init.sql only runs on an empty volume.
"${COMPOSE[@]}" down -v >/dev/null 2>&1
# --wait returns once GoTrue is healthy, which is after its own migrations have run.
out=$("${COMPOSE[@]}" up -d --wait --quiet-pull 2>&1) ||
  { echo "FAIL  stack up"; echo "$out" | sed 's/^/      /' | tail -8; exit 1; }
echo "PASS  stack up"

for f in supabase/migrations/*.sql supabase/functions/*.sql supabase/views/*.sql supabase/policies/*.sql; do
  [ -e "$f" ] || continue
  out=$("${PSQL[@]}" < "$f" 2>&1) ||
    { echo "FAIL  applying $(basename "$f")"; echo "$out" | sed 's/^/      /' | head -5; exit 1; }
done
# PostgREST came up before the schema did, so it reloads its cache now.
"${PSQL[@]}" -c "notify pgrst, 'reload schema'" >/dev/null
echo "PASS  schema applied"

for key in owner chef salaeng minburi; do
  body=$(curl -s -w '\n%{http_code}' -X POST "$API/auth/v1/admin/users" \
    -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"demo-$key@demo.local\",\"password\":\"$DEMO_USER_PASSWORD\",\"email_confirm\":true}")
  code=${body##*$'\n'}
  [ "$code" = 200 ] || { echo "FAIL  user demo-$key: HTTP $code"; echo "${body%$'\n'*}" | head -3; exit 1; }
done
echo "PASS  four users through GoTrue"

out=$("${PSQL[@]}" < supabase/demo/seed.sql 2>&1) ||
  { echo "FAIL  seed.sql"; echo "$out" | sed 's/^/      /' | head -5; exit 1; }
out=$("${PSQL[@]}" < supabase/demo/seed_check.sql 2>&1 || true)
grep -q "DEMO_SEED_CHECK_PASSED" <<<"$out" ||
  { echo "FAIL  seed_check.sql"; echo "$out" | sed 's/^/      /' | head -8; exit 1; }
echo "PASS  seed.sql and seed_check.sql"

# E2E fixtures, after the seed's own check and through the real writers. The seed leaves both
# branches empty (D8), so each admin counts 10.00 kg of opening meat at their own branch, as
# postgrest_test.sh does. And the day may close at any hour, so a daytime run reaches BR 09's
# close; the 21:00 rule itself stays covered in day_close_test.sql (UAT-14).
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
    perform fn_record_opening_balance(gen_random_uuid(), 'SMOKED_MEAT', b.id, 10.00, current_date,
                                      p_lot_code => 'OPEN-' || b.code, p_smoke_date => current_date - 7);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub',
    (select id from auth.users where email = 'demo-owner@demo.local'))::text, true);
  perform fn_set_config(gen_random_uuid(), 'business_day_close_earliest', current_date - 30,
                        p_value_text => '00:00');
end $$;
SQL
) || { echo "FAIL  E2E fixtures"; echo "$out" | sed 's/^/      /' | head -5; exit 1; }
echo "PASS  E2E fixtures"
