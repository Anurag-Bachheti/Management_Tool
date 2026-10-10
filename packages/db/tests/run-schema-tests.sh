#!/usr/bin/env bash
# Runs the database schema tests against a throwaway database.
#   1. creates an empty opsflow_test database (your real opsflow database is untouched)
#   2. applies every migration in packages/db/migrations with drizzle-kit
#   3. runs each packages/db/tests/*.test.sql inside BEGIN ... ROLLBACK,
#      as the role named on its "-- run-as:" line (default opsflow_app)
#   4. drops opsflow_test again, even if a test fails
# Usage, from the repo root: pnpm db:test
set -euo pipefail
cd "$(dirname "$0")/../../.."                     # repo root

if [ -f .env ]; then set -a; . ./.env; set +a; fi
: "${MIGRATION_DATABASE_URL:?MIGRATION_DATABASE_URL is not set (see .env.example)}"

TEST_DB=opsflow_test
TESTS_DIR=packages/db/tests

compose() { docker compose --env-file .env -f infra/compose/docker-compose.yml "$@"; }
psql_as() {                                       # psql_as <role> <database> [psql args...]
  local role=$1 db=$2; shift 2
  compose exec -T postgres psql -U "$role" -d "$db" -X -q -v ON_ERROR_STOP=1 "$@"
}
drop_test_db() {
  psql_as postgres postgres -c "SET client_min_messages = warning" \
    -c "DROP DATABASE IF EXISTS $TEST_DB WITH (FORCE)" >/dev/null
}
trap drop_test_db EXIT

echo "→ Creating $TEST_DB"
drop_test_db
psql_as postgres postgres -c "CREATE DATABASE $TEST_DB OWNER opsflow_owner" >/dev/null
psql_as postgres "$TEST_DB" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC" >/dev/null

echo "→ Applying migrations"
MIGRATION_DATABASE_URL="${MIGRATION_DATABASE_URL%/*}/$TEST_DB" \
  pnpm --silent --filter @opsflow/db migrate >/dev/null

shopt -s nullglob
files=("$TESTS_DIR"/*.test.sql)
[ ${#files[@]} -gt 0 ] || { echo "No test files in $TESTS_DIR"; exit 1; }

for file in "${files[@]}"; do
  role=$(sed -n 's/^-- run-as: *//p' "$file" | head -n 1)
  role=${role:-opsflow_app}
  echo "→ $(basename "$file")  (as $role)"
  { echo 'BEGIN;'; cat "$TESTS_DIR/_helpers.sql" "$file"; echo 'ROLLBACK;'; } \
    | psql_as "$role" "$TEST_DB" 2>&1 \
    | sed -u -E -e 's/^(psql:[^ ]* )?NOTICE:  /   /' -e 's/^(psql:[^ ]* )?ERROR:  /   ERROR: /' -e '/^ *$/d' -e '/^CONTEXT:/d'
done

echo "✓ All schema tests passed"
