-- Test helpers, prepended to every *.test.sql file by run-schema-tests.sh.
-- They live in pg_temp, so they vanish when the test transaction rolls back.
\pset tuples_only on
\pset format unaligned
SET client_min_messages = notice;

-- PASS if the condition is true, otherwise stop the run.
CREATE FUNCTION pg_temp.expect(ok boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL  %', label; END IF;
  RAISE NOTICE 'PASS  %', label;
END $$;

-- PASS if actual equals expected.
CREATE FUNCTION pg_temp.expect_eq(actual bigint, expected bigint, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'FAIL  %: expected %, got %', label, expected, actual;
  END IF;
  RAISE NOTICE 'PASS  %', label;
END $$;

-- PASS if the statement fails with exactly this SQLSTATE (e.g. 23505 unique, 42501 RLS).
-- The failed statement is rolled back on its own; the test run continues.
CREATE FUNCTION pg_temp.expect_error(stmt text, state text, label text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE succeeded boolean := false;
BEGIN
  BEGIN
    EXECUTE stmt;
    succeeded := true;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> state THEN
      RAISE EXCEPTION 'FAIL  %: expected SQLSTATE %, got % (%)', label, state, SQLSTATE, SQLERRM;
    END IF;
  END;
  IF succeeded THEN RAISE EXCEPTION 'FAIL  %: statement succeeded but should fail', label; END IF;
  RAISE NOTICE 'PASS  %', label;
END $$;

-- Request contexts, exactly as the API will set them.
CREATE FUNCTION pg_temp.as_nobody() RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.org_id', '', false), set_config('app.user_id', '', false); $$;
CREATE FUNCTION pg_temp.as_user(u uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.org_id', '', false), set_config('app.user_id', u::text, false); $$;
CREATE FUNCTION pg_temp.as_org(o uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.org_id', o::text, false); $$;

-- Creates an organization and its owner the way the API's signup flow will:
-- set app.org_id to the new id first, so the inserts pass row-level security.
CREATE FUNCTION pg_temp.create_org(o uuid, slug text, owner_user uuid, owner_membership uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.org_id', o::text, false);
  INSERT INTO organizations (id, name, slug) VALUES (o, initcap(slug), slug);
  INSERT INTO memberships (id, org_id, user_id, role) VALUES (owner_membership, o, owner_user, 'owner');
END $$;
