-- =============================================================================
-- OpsFlow · infra/db/bootstrap-roles.sql
-- Creates the three database roles and the opsflow database. Run ONCE per
-- Postgres server, as a superuser, before the first migration.
--   Locally:     Docker Compose runs it automatically on first start
--                (infra/compose/postgres-init/00-dev-roles.sh).
--   Production:  run it by hand with psql (it uses \connect), then set
--                passwords outside version control:
--                  ALTER ROLE opsflow_owner  PASSWORD '...';
--                  ALTER ROLE opsflow_app    PASSWORD '...';
--                  ALTER ROLE opsflow_worker PASSWORD '...';
-- =============================================================================

-- Owns every table. Migrations run as this role. It does NOT bypass RLS, and
-- tables use FORCE ROW LEVEL SECURITY, so even the owner cannot read tenant
-- rows without setting app.org_id. DDL is unaffected by RLS.
CREATE ROLE opsflow_owner LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOBYPASSRLS;

-- The API's only connection role. Every query runs inside withUser() (sets
-- app.user_id) or withTenant() (sets app.user_id and app.org_id). No BYPASSRLS,
-- not the table owner. Login, the org switcher, invitation acceptance and org
-- creation all work under RLS (see 0001_init.sql, section 11).
CREATE ROLE opsflow_app LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOBYPASSRLS;

-- Used ONLY by the worker process, never by the API: the outbox relay, cron
-- scans across orgs, and org deletion. Its credentials exist only in the worker's
-- deployment. Job handlers that touch tenant data still run as opsflow_app inside
-- withTenant(), so only the cross-tenant claim and scan steps bypass RLS.
CREATE ROLE opsflow_worker LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB BYPASSRLS;

-- The database is owned by opsflow_owner so migrations can create trusted
-- extensions (citext, btree_gist, pg_trgm) without superuser.
CREATE DATABASE opsflow OWNER opsflow_owner;

-- On PG15+, schema public is owned by the database owner, so opsflow_owner
-- already controls it. Remove the default USAGE every role gets; 0001 grants
-- it back to the two application roles only.
\connect opsflow
REVOKE ALL ON SCHEMA public FROM PUBLIC;
