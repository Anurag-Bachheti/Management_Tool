-- =============================================================================
-- OpsFlow · docs/schema/target-v1.tests.sql (reference tests for target-v1.sql)
-- Proves the database itself enforces the rules the app relies on.
-- Run against a freshly migrated database with:  ./run_tests.sh
-- Any failure raises and stops psql (ON_ERROR_STOP); the last line prints ALL PASSED.
-- =============================================================================
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
SET client_min_messages = notice;

-- ---------- test helpers (dropped at the end) --------------------------------
CREATE SCHEMA t;
GRANT USAGE ON SCHEMA t TO opsflow_app, opsflow_worker;

CREATE FUNCTION t.expect_error(stmt text, state text, label text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE succeeded boolean := false;
BEGIN
  BEGIN
    EXECUTE stmt;
    succeeded := true;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> state THEN
      RAISE EXCEPTION 'FAIL %: expected SQLSTATE %, got % (%)', label, state, SQLSTATE, SQLERRM;
    END IF;
  END;
  IF succeeded THEN
    RAISE EXCEPTION 'FAIL %: statement succeeded but should have been rejected', label;
  END IF;
  RAISE NOTICE 'PASS  %', label;
END $$;

CREATE FUNCTION t.expect_commit_error(stmt text, state text, label text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE succeeded boolean := false;
BEGIN
  BEGIN
    EXECUTE stmt;
    SET CONSTRAINTS ALL IMMEDIATE;      -- fire deferred checks now, as COMMIT would
    succeeded := true;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> state THEN
      RAISE EXCEPTION 'FAIL %: expected SQLSTATE %, got % (%)', label, state, SQLSTATE, SQLERRM;
    END IF;
  END;
  IF succeeded THEN
    RAISE EXCEPTION 'FAIL %: transaction would have committed but should have been rejected', label;
  END IF;
  RAISE NOTICE 'PASS  %', label;
END $$;

CREATE FUNCTION t.expect_eq(actual bigint, expected bigint, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'FAIL %: expected %, got %', label, expected, actual;
  END IF;
  RAISE NOTICE 'PASS  %', label;
END $$;

CREATE FUNCTION t.expect_ok(stmt text, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE stmt;
  RAISE NOTICE 'PASS  %', label;
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO opsflow_app, opsflow_worker;

-- ---------- seed two tenants (system role bypasses RLS) ----------------------
SET ROLE opsflow_worker;

INSERT INTO users (id, email, display_name) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'priya@acme.example',   'Priya Nair'),
  ('00000000-0000-0000-0000-0000000000a2', 'anurag@acme.example',  'Anurag Mehta'),
  ('00000000-0000-0000-0000-0000000000a3', 'rahul@acme.example',   'Rahul Sharma'),
  ('00000000-0000-0000-0000-0000000000b1', 'owner@globex.example', 'Globex Owner');

INSERT INTO organizations (id, name, slug) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000000', 'Acme Technologies', 'acme'),
  ('bbbbbbbb-0000-0000-0000-000000000000', 'Globex', 'globex');

INSERT INTO departments (id, org_id, name) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000d1', 'aaaaaaaa-0000-0000-0000-000000000000', 'Engineering');

INSERT INTO memberships (id, org_id, user_id, role, manager_id, department_id) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'owner',    NULL, NULL),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'manager',  'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-0000000000d1'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a3', 'employee', 'aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-0000000000d1'),
  ('bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'owner',    NULL, NULL),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'bbbbbbbb-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a3', 'employee', NULL, NULL);

INSERT INTO leave_types (id, org_id, name, category, deducts_balance, annual_quota) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000f1', 'aaaaaaaa-0000-0000-0000-000000000000', 'Paid leave', 'leave', true, 18),
  ('bbbbbbbb-0000-0000-0000-0000000000f1', 'bbbbbbbb-0000-0000-0000-000000000000', 'Paid leave', 'leave', true, 12);

INSERT INTO tasks (org_id, number, title, created_by) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000000', 1, 'Globex secret task', 'bbbbbbbb-0000-0000-0000-000000000001');

RESET ROLE;

-- =============================================================================
-- A. Tenant isolation (row-level security)
-- =============================================================================
SET ROLE opsflow_app;

SET app.org_id = '';
SET app.user_id = '';
SELECT t.expect_eq((SELECT count(*) FROM memberships), 0, 'no user, no tenant: memberships invisible');
SELECT t.expect_eq((SELECT count(*) FROM tasks), 0,       'no user, no tenant: tasks invisible');

-- Signed in as Rahul, no org chosen yet (login, org switcher, tenant check)
SET app.user_id = '00000000-0000-0000-0000-0000000000a3';
SELECT t.expect_eq((SELECT count(*) FROM memberships), 2,   'user sees only their own memberships, across both orgs');
SELECT t.expect_eq((SELECT count(*) FROM organizations), 2, 'user sees the orgs they belong to');
SELECT t.expect_eq((SELECT count(*) FROM tasks), 0,         'user context alone reveals no tenant data');
WITH u AS (UPDATE memberships SET job_title = 'self-promoted' RETURNING 1)
SELECT t.expect_eq(count(*), 0, 'user context cannot modify memberships') FROM u;
SELECT t.expect_error($$INSERT INTO organizations (id, name, slug) VALUES (gen_random_uuid(), 'Rogue', 'rogue')$$,
  '42501', 'org creation without app.org_id = new id is refused');
SET app.org_id = 'cccccccc-0000-0000-0000-000000000000';
SELECT t.expect_ok($$INSERT INTO organizations (id, name, slug)
  VALUES ('cccccccc-0000-0000-0000-000000000000', 'Initech', 'initech')$$,
  'org creation works under RLS when app.org_id is the new org id');
SET app.org_id = '';

SET app.org_id = 'aaaaaaaa-0000-0000-0000-000000000000';
SELECT t.expect_eq((SELECT count(*) FROM memberships), 3,   'org A sees only its 3 members (not Rahul''s org B row)');
SELECT t.expect_eq((SELECT count(*) FROM organizations), 1, 'org A sees only its own organization row');
SELECT t.expect_eq((SELECT count(*) FROM tasks WHERE title = 'Globex secret task'), 0, 'org A cannot read org B task');
WITH u AS (UPDATE tasks SET title = 'pwned' RETURNING 1)
SELECT t.expect_eq(count(*), 0, 'org A UPDATE cannot touch org B rows') FROM u;
WITH d AS (DELETE FROM tasks RETURNING 1)
SELECT t.expect_eq(count(*), 0, 'org A DELETE cannot touch org B rows') FROM d;
SELECT t.expect_error($$INSERT INTO tasks (org_id, number, title, created_by)
  VALUES ('bbbbbbbb-0000-0000-0000-000000000000', 99, 'planted', 'bbbbbbbb-0000-0000-0000-000000000001')$$,
  '42501', 'org A cannot INSERT a row into org B');
SELECT t.expect_error($$DELETE FROM organizations$$,
  '42501', 'app role cannot delete organizations (worker job only)');

-- =============================================================================
-- B. Cross-tenant references are impossible (composite foreign keys)
-- =============================================================================
SELECT t.expect_error($$INSERT INTO tasks (org_id, number, title, created_by, assignee_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 1, 'Assign across tenants',
          'aaaaaaaa-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000001')$$,
  '23503', 'task in org A cannot be assigned to an org B member');
SELECT t.expect_error($$INSERT INTO leave_requests (org_id, member_id, leave_type_id, start_date, end_date, days)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'bbbbbbbb-0000-0000-0000-0000000000f1', '2026-11-02', '2026-11-02', 1)$$,
  '23503', 'leave request cannot use another org''s leave type');

-- =============================================================================
-- C. People rules
-- =============================================================================
SELECT t.expect_error($$UPDATE memberships SET role = 'owner' WHERE id = 'aaaaaaaa-0000-0000-0000-000000000002'$$,
  '23505', 'an org has exactly one owner');
SELECT t.expect_error($$UPDATE memberships SET manager_id = id WHERE id = 'aaaaaaaa-0000-0000-0000-000000000003'$$,
  '23514', 'a member cannot be their own manager');
SELECT t.expect_error($$UPDATE memberships SET status = 'deactivated' WHERE id = 'aaaaaaaa-0000-0000-0000-000000000003'$$,
  '23514', 'deactivation requires deactivated_at');
SELECT t.expect_error($$UPDATE organizations SET timezone = 'Mars/Olympus_Mons'$$,
  '22023', 'unknown time zone rejected');

-- =============================================================================
-- D. Leave requests
-- =============================================================================
SELECT t.expect_ok($$WITH r AS (
    INSERT INTO leave_requests (id, org_id, member_id, leave_type_id, start_date, end_date, days, approver_id)
    VALUES ('aaaaaaaa-0000-0000-0000-00000000aa01', 'aaaaaaaa-0000-0000-0000-000000000000',
            'aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-0000000000f1',
            '2026-10-22', '2026-10-23', 2, 'aaaaaaaa-0000-0000-0000-000000000002')
    RETURNING org_id, id)
  INSERT INTO leave_request_allocations (org_id, request_id, period_year, days) SELECT org_id, id, 2026, 2 FROM r$$,
  'valid 2-day request accepted with its allocation');

SELECT t.expect_commit_error($$INSERT INTO leave_requests (org_id, member_id, leave_type_id, start_date, end_date, days)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', '2026-11-16', '2026-11-16', 1)$$,
  '23514', 'a request without allocations cannot commit');

SELECT t.expect_commit_error($$WITH r AS (
    INSERT INTO leave_requests (org_id, member_id, leave_type_id, start_date, end_date, days)
    VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
            'aaaaaaaa-0000-0000-0000-0000000000f1', '2026-11-16', '2026-11-18', 3)
    RETURNING org_id, id)
  INSERT INTO leave_request_allocations (org_id, request_id, period_year, days) SELECT org_id, id, 2026, 2 FROM r$$,
  '23514', 'allocations must add up to the request''s days');

SELECT t.expect_ok($$WITH r AS (
    INSERT INTO leave_requests (id, org_id, member_id, leave_type_id, start_date, end_date, days)
    VALUES ('aaaaaaaa-0000-0000-0000-00000000aa02', 'aaaaaaaa-0000-0000-0000-000000000000',
            'aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-0000000000f1',
            '2026-12-30', '2027-01-01', 3)
    RETURNING org_id, id)
  INSERT INTO leave_request_allocations (org_id, request_id, period_year, days)
  SELECT org_id, id, y, d FROM r, (VALUES (2026::smallint, 2.0), (2027::smallint, 1.0)) AS a(y, d)$$,
  'request spanning 31 Dec splits into 2 days for 2026 and 1 for 2027');

SELECT t.expect_error($$INSERT INTO leave_requests (org_id, member_id, leave_type_id, start_date, end_date, days)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', '2026-10-23', '2026-10-26', 2)$$,
  '23P01', 'overlapping live request rejected (shares 23 Oct)');

SELECT t.expect_error($$INSERT INTO leave_requests (org_id, member_id, leave_type_id, start_date, end_date, start_half, end_half, days)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', '2026-11-09', '2026-11-10', 'first', 'full', 1.5)$$,
  '23514', 'multi-day request cannot start with the first half only');

SELECT t.expect_error($$INSERT INTO leave_requests (org_id, member_id, leave_type_id, start_date, end_date, start_half, end_half, days)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', '2026-11-09', '2026-11-09', 'first', 'second', 0.5)$$,
  '23514', 'single-day request halves must agree');

SELECT t.expect_error($$INSERT INTO leave_requests (org_id, member_id, leave_type_id, start_date, end_date, days)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', '2026-11-09', '2026-11-09', 0.3)$$,
  '23514', 'days must be a multiple of 0.5');

SELECT t.expect_error($$UPDATE leave_requests SET status = 'approved', decided_at = now(),
  decided_by = 'aaaaaaaa-0000-0000-0000-000000000003' WHERE id = 'aaaaaaaa-0000-0000-0000-00000000aa01'$$,
  '23514', 'nobody approves their own leave');

SELECT t.expect_error($$UPDATE leave_requests SET status = 'rejected', decided_at = now(),
  decided_by = 'aaaaaaaa-0000-0000-0000-000000000002' WHERE id = 'aaaaaaaa-0000-0000-0000-00000000aa01'$$,
  '23514', 'rejection requires a note');

SELECT t.expect_ok($$UPDATE leave_requests SET status = 'approved', decided_at = now(),
  decided_by = 'aaaaaaaa-0000-0000-0000-000000000002' WHERE id = 'aaaaaaaa-0000-0000-0000-00000000aa01'$$,
  'manager approves');

SELECT t.expect_ok($$UPDATE leave_requests SET status = 'cancelled', cancelled_at = now()
  WHERE id = 'aaaaaaaa-0000-0000-0000-00000000aa01'$$, 'approved request cancelled');

SELECT t.expect_ok($$WITH r AS (
    INSERT INTO leave_requests (org_id, member_id, leave_type_id, start_date, end_date, days)
    VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
            'aaaaaaaa-0000-0000-0000-0000000000f1', '2026-10-23', '2026-10-26', 2)
    RETURNING org_id, id)
  INSERT INTO leave_request_allocations (org_id, request_id, period_year, days) SELECT org_id, id, 2026, 2 FROM r$$,
  'cancelled request frees its dates for a new one');

SELECT t.expect_error($$INSERT INTO leave_types (org_id, name, category, deducts_balance)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'Remote', 'wfh', true)$$,
  '23514', 'WFH type can never use a balance');

-- =============================================================================
-- E. Leave ledger (append-only balance)
-- =============================================================================
SELECT t.expect_ok($$INSERT INTO leave_ledger (org_id, member_id, leave_type_id, period_year, kind, delta)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', 2026, 'accrual', 18)$$, 'annual accrual recorded');

SELECT t.expect_error($$INSERT INTO leave_ledger (org_id, member_id, leave_type_id, period_year, kind, delta)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', 2026, 'accrual', 18)$$,
  '23505', 'retried accrual job cannot grant the same year twice');

SELECT t.expect_ok($$INSERT INTO leave_ledger (org_id, member_id, leave_type_id, period_year, kind, delta, request_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', 2026, 'debit', -2, 'aaaaaaaa-0000-0000-0000-00000000aa02')$$,
  'approval debits 2 days from the 2026 balance');
SELECT t.expect_ok($$INSERT INTO leave_ledger (org_id, member_id, leave_type_id, period_year, kind, delta, request_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', 2027, 'debit', -1, 'aaaaaaaa-0000-0000-0000-00000000aa02')$$,
  'and 1 day from the 2027 balance');
SELECT t.expect_error($$INSERT INTO leave_ledger (org_id, member_id, leave_type_id, period_year, kind, delta, request_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', 2026, 'debit', -2, 'aaaaaaaa-0000-0000-0000-00000000aa02')$$,
  '23505', 'a request is debited at most once per leave year');
SELECT t.expect_error($$INSERT INTO leave_ledger (org_id, member_id, leave_type_id, period_year, kind, delta, request_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', 2028, 'debit', -1, 'aaaaaaaa-0000-0000-0000-00000000aa02')$$,
  '23503', 'a debit can only hit a year the request was allocated to');
SELECT t.expect_error($$INSERT INTO leave_ledger (org_id, member_id, leave_type_id, period_year, kind, delta, request_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', 2026, 'debit', 2, 'aaaaaaaa-0000-0000-0000-00000000aa02')$$,
  '23514', 'a debit must be negative');

SELECT t.expect_error($$INSERT INTO leave_ledger (org_id, member_id, leave_type_id, period_year, kind, delta)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'aaaaaaaa-0000-0000-0000-0000000000f1', 2026, 'adjustment', 1)$$,
  '23514', 'manual adjustment needs a note and an author');

SELECT t.expect_eq((SELECT sum(delta)::bigint FROM leave_ledger
                    WHERE member_id = 'aaaaaaaa-0000-0000-0000-000000000003' AND period_year = 2026), 16,
                   'balance = SUM(delta) = 18 - 2');

SELECT t.expect_error($$UPDATE leave_ledger SET delta = 100$$,
  '42501', 'ledger rows cannot be updated');
SELECT t.expect_error($$DELETE FROM leave_ledger$$,
  '42501', 'ledger rows cannot be deleted by the app');

-- =============================================================================
-- F. Tasks, tickets, counters, calendar, notifications
-- =============================================================================
WITH c AS (
  INSERT INTO org_counters (org_id, scope, next_value)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'task', 2)
  ON CONFLICT (org_id, scope) DO UPDATE SET next_value = org_counters.next_value + 1
  RETURNING next_value - 1 AS number)
SELECT t.expect_eq(number, 1, 'first task number is 1') FROM c;
WITH c AS (
  INSERT INTO org_counters (org_id, scope, next_value)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'task', 2)
  ON CONFLICT (org_id, scope) DO UPDATE SET next_value = org_counters.next_value + 1
  RETURNING next_value - 1 AS number)
SELECT t.expect_eq(number, 2, 'second task number is 2') FROM c;

SELECT t.expect_ok($$INSERT INTO tasks (org_id, number, title, description, created_by, assignee_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 1, 'Update landing page', 'Replace hero copy',
          'aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000003')$$,
  'task created in org A with number 1 (org B also has a task 1)');
SELECT t.expect_error($$INSERT INTO tasks (org_id, number, title, created_by)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 1, 'Duplicate number', 'aaaaaaaa-0000-0000-0000-000000000002')$$,
  '23505', 'task numbers are unique per org');
SELECT t.expect_error($$UPDATE tasks SET status = 'done' WHERE number = 1$$,
  '23514', 'done requires completed_at');
SELECT t.expect_error($$UPDATE tasks SET status = 'blocked' WHERE number = 1$$,
  '23514', 'blocked requires a reason');
SELECT t.expect_eq((SELECT count(*) FROM tasks WHERE search @@ plainto_tsquery('simple', 'landing')), 1,
                   'full-text search finds the task');

SELECT t.expect_error($$INSERT INTO events (org_id, title, created_by, starts_at, ends_at, start_date, end_date)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'Mixed shape', 'aaaaaaaa-0000-0000-0000-000000000002',
          '2026-10-21 10:00+05:30', '2026-10-21 11:00+05:30', '2026-10-21', '2026-10-21')$$,
  '23514', 'event is either timed or all-day, never both');
SELECT t.expect_error($$INSERT INTO events (org_id, title, created_by, starts_at, ends_at)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'Backwards', 'aaaaaaaa-0000-0000-0000-000000000002',
          '2026-10-21 11:00+05:30', '2026-10-21 10:00+05:30')$$,
  '23514', 'event cannot end before it starts');

SELECT t.expect_ok($$INSERT INTO notifications (org_id, recipient_id, kind, title, source_event_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'leave.approved', 'Your leave was approved', 'aaaaaaaa-0000-0000-0000-0000000e0001')$$,
  'notification delivered');
SELECT t.expect_error($$INSERT INTO notifications (org_id, recipient_id, kind, title, source_event_id)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000003',
          'leave.approved', 'Your leave was approved', 'aaaaaaaa-0000-0000-0000-0000000e0001')$$,
  '23505', 'retried notification job does not notify twice');

SELECT t.expect_ok($$INSERT INTO activity_events (org_id, actor_id, entity_type, entity_id, action)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000002',
          'task', gen_random_uuid(), 'created')$$, 'activity recorded');
SELECT t.expect_error($$UPDATE activity_events SET action = 'rewritten'$$,
  '42501', 'activity log cannot be rewritten');

WITH c AS (INSERT INTO scheduled_runs (org_id, job_name, period_key)
           VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'tasks.due_reminder', '2026-10-12')
           ON CONFLICT DO NOTHING RETURNING 1)
SELECT t.expect_eq(count(*), 1, 'first cron tick claims the 12 Oct reminder run') FROM c;
WITH c AS (INSERT INTO scheduled_runs (org_id, job_name, period_key)
           VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'tasks.due_reminder', '2026-10-12')
           ON CONFLICT DO NOTHING RETURNING 1)
SELECT t.expect_eq(count(*), 0, 'retried or overlapping tick does not run it again') FROM c;

RESET ROLE;

-- =============================================================================
-- G. Deleting a tenant removes everything it owns, and nothing else
-- =============================================================================
SET ROLE opsflow_worker;
SELECT t.expect_eq((SELECT count(*) FROM leave_ledger), 3, 'org A has ledger rows before deletion');
SELECT t.expect_ok($$DELETE FROM organizations WHERE id = 'aaaaaaaa-0000-0000-0000-000000000000'$$,
  'org A deleted (cascades through ledger and activity log)');
SELECT t.expect_eq((SELECT count(*) FROM memberships WHERE org_id = 'aaaaaaaa-0000-0000-0000-000000000000'), 0,
  'org A memberships gone');
SELECT t.expect_eq((SELECT count(*) FROM leave_ledger), 0, 'org A ledger gone');
SELECT t.expect_eq((SELECT count(*) FROM tasks WHERE org_id = 'bbbbbbbb-0000-0000-0000-000000000000'), 1,
  'org B untouched');
SELECT t.expect_eq((SELECT count(*) FROM users), 4, 'user accounts survive org deletion');
RESET ROLE;

SET client_min_messages = warning;
DROP SCHEMA t CASCADE;
\echo ALL PASSED
