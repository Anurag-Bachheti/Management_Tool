#!/bin/sh
# Runs once, when the Postgres container starts with an empty data volume.
# Creates the OpsFlow roles and database, then sets local-only passwords from
# the environment (values come from the repo-root .env).
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -f /opsflow/bootstrap-roles.sql

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname opsflow \
  -v owner_pw="$OPSFLOW_OWNER_PASSWORD" \
  -v app_pw="$OPSFLOW_APP_PASSWORD" \
  -v worker_pw="$OPSFLOW_WORKER_PASSWORD" <<'EOSQL'
ALTER ROLE opsflow_owner  PASSWORD :'owner_pw';
ALTER ROLE opsflow_app    PASSWORD :'app_pw';
ALTER ROLE opsflow_worker PASSWORD :'worker_pw';
EOSQL
