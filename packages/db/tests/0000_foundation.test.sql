-- run-as: opsflow_app
-- Tests for migration 0000_foundation, run as the API's own role, so row-level
-- security applies exactly as it will in production.
--
-- Cast: two companies. Acme (owner Priya) and Globex (owner Zed).
-- Rahul is an employee at both, which is what makes the user-context tests meaningful.

INSERT INTO users (id, email, display_name) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'priya@acme.example',  'Priya'),
  ('00000000-0000-0000-0000-0000000000a2', 'rahul@acme.example',  'Rahul'),
  ('00000000-0000-0000-0000-0000000000b1', 'zed@globex.example',  'Zed');

SELECT pg_temp.create_org('aaaaaaaa-0000-0000-0000-000000000000', 'acme',
                          '00000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001');
INSERT INTO memberships (id, org_id, user_id, role) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000000',
   '00000000-0000-0000-0000-0000000000a2', 'employee');

SELECT pg_temp.create_org('bbbbbbbb-0000-0000-0000-000000000000', 'globex',
                          '00000000-0000-0000-0000-0000000000b1', 'bbbbbbbb-0000-0000-0000-000000000001');
INSERT INTO memberships (id, org_id, user_id, role) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000000',
   '00000000-0000-0000-0000-0000000000a2', 'employee');

-- ---------------------------------------------------------------------------
-- 1. No context: a request that set nothing sees nothing
-- ---------------------------------------------------------------------------
SELECT pg_temp.as_nobody();
SELECT pg_temp.expect_eq((SELECT count(*) FROM organizations), 0, 'no context: organizations invisible');
SELECT pg_temp.expect_eq((SELECT count(*) FROM memberships),   0, 'no context: memberships invisible');
SELECT pg_temp.expect_eq((SELECT count(*) FROM invitations),   0, 'no context: invitations invisible');

-- ---------------------------------------------------------------------------
-- 2. Tenant isolation: inside Acme, Globex does not exist
-- ---------------------------------------------------------------------------
SELECT pg_temp.as_org('aaaaaaaa-0000-0000-0000-000000000000');
SELECT pg_temp.expect_eq((SELECT count(*) FROM organizations), 1, 'Acme sees only its own organization');
SELECT pg_temp.expect_eq((SELECT count(*) FROM memberships),   2, 'Acme sees only its 2 members');
SELECT pg_temp.expect_eq((SELECT count(*) FROM memberships
                          WHERE org_id = 'bbbbbbbb-0000-0000-0000-000000000000'), 0,
                         'Acme cannot read Globex members even when asking for them by org_id');

WITH changed AS (UPDATE memberships SET job_title = 'hacked'
                 WHERE org_id = 'bbbbbbbb-0000-0000-0000-000000000000' RETURNING 1)
SELECT pg_temp.expect_eq(count(*), 0, 'Acme cannot update Globex rows') FROM changed;

WITH removed AS (DELETE FROM memberships
                 WHERE org_id = 'bbbbbbbb-0000-0000-0000-000000000000' RETURNING 1)
SELECT pg_temp.expect_eq(count(*), 0, 'Acme cannot delete Globex rows') FROM removed;

SELECT pg_temp.expect_error($$
  INSERT INTO memberships (org_id, user_id, role)
  VALUES ('bbbbbbbb-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'admin')
$$, '42501', 'Acme cannot insert a member into Globex');

SELECT pg_temp.expect_error($$
  UPDATE memberships SET org_id = 'bbbbbbbb-0000-0000-0000-000000000000'
  WHERE id = 'aaaaaaaa-0000-0000-0000-000000000002'
$$, '42501', 'Acme cannot move its own member into Globex');

-- ---------------------------------------------------------------------------
-- 3. Cross-company references are impossible (composite foreign keys)
-- ---------------------------------------------------------------------------
SELECT pg_temp.expect_error($$
  INSERT INTO invitations (org_id, email, role, invited_by, token_hash, expires_at)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'new@acme.example', 'employee',
          'bbbbbbbb-0000-0000-0000-000000000001', sha256('x'), now() + interval '7 days')
$$, '23503', 'an Acme invitation cannot be sent by a Globex member');

-- ---------------------------------------------------------------------------
-- 4. User context (login and org switcher): own rows only, read-only
-- ---------------------------------------------------------------------------
SELECT pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');   -- Rahul, no company chosen
SELECT pg_temp.expect_eq((SELECT count(*) FROM memberships),   2, 'Rahul sees his own 2 memberships, one per company');
SELECT pg_temp.expect_eq((SELECT count(*) FROM organizations), 2, 'Rahul sees the 2 companies he belongs to');
SELECT pg_temp.expect_eq((SELECT count(*) FROM memberships
                          WHERE user_id <> '00000000-0000-0000-0000-0000000000a2'), 0,
                         'Rahul sees no one else''s membership');
SELECT pg_temp.expect_eq((SELECT count(*) FROM invitations), 0, 'user context shows no invitations');

WITH changed AS (UPDATE memberships SET role = 'admin' RETURNING 1)
SELECT pg_temp.expect_eq(count(*), 0, 'user context cannot change memberships, not even his own') FROM changed;

SELECT pg_temp.as_org('aaaaaaaa-0000-0000-0000-000000000000');    -- Rahul picks Acme
SELECT pg_temp.expect_eq((SELECT count(*) FROM memberships
                          WHERE org_id = 'bbbbbbbb-0000-0000-0000-000000000000'), 0,
                         'once a company is chosen, his other company disappears');

-- ---------------------------------------------------------------------------
-- 5. Creating an organization works under RLS, but only for the new org's own id
-- ---------------------------------------------------------------------------
SELECT pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
SELECT pg_temp.expect_error($$
  INSERT INTO organizations (id, name, slug) VALUES ('cccccccc-0000-0000-0000-000000000000', 'Rogue', 'rogue')
$$, '42501', 'cannot create an org without setting app.org_id to its id');
SELECT pg_temp.as_org('cccccccc-0000-0000-0000-000000000000');
SELECT pg_temp.expect_error($$
  INSERT INTO organizations (id, name, slug) VALUES ('dddddddd-0000-0000-0000-000000000000', 'Other', 'other')
$$, '42501', 'cannot create a different org than the one in app.org_id');
SELECT pg_temp.create_org('cccccccc-0000-0000-0000-000000000000', 'initech',
                          '00000000-0000-0000-0000-0000000000a1', 'cccccccc-0000-0000-0000-000000000001');
SELECT pg_temp.expect_eq((SELECT count(*) FROM organizations), 1, 'creating an org with its own id succeeds');

-- ---------------------------------------------------------------------------
-- 6. People rules
-- ---------------------------------------------------------------------------
SELECT pg_temp.as_org('aaaaaaaa-0000-0000-0000-000000000000');
SELECT pg_temp.expect_error($$
  UPDATE memberships SET role = 'owner' WHERE id = 'aaaaaaaa-0000-0000-0000-000000000002'
$$, '23505', 'exactly one owner per company');
SELECT pg_temp.expect_error($$
  UPDATE memberships SET status = 'deactivated', deactivated_at = now()
  WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001'
$$, '23514', 'the owner cannot be deactivated');
SELECT pg_temp.expect_error($$
  UPDATE memberships SET status = 'deactivated' WHERE id = 'aaaaaaaa-0000-0000-0000-000000000002'
$$, '23514', 'deactivating a member requires deactivated_at');
SELECT pg_temp.expect_error($$
  INSERT INTO memberships (org_id, user_id, role)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'employee')
$$, '23505', 'a person has at most one membership per company');
SELECT pg_temp.expect_error($$
  INSERT INTO users (email, display_name) VALUES ('PRIYA@acme.example', 'Duplicate')
$$, '23505', 'emails are unique regardless of capitals');
SELECT pg_temp.expect_error($$
  INSERT INTO users (email, display_name) VALUES ('newperson@acme.example', '   ')
$$, '23514', 'a display name cannot be only spaces');

-- ---------------------------------------------------------------------------
-- 7. Invitations
-- ---------------------------------------------------------------------------
INSERT INTO invitations (id, org_id, email, role, invited_by, token_hash, expires_at) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000001a1', 'aaaaaaaa-0000-0000-0000-000000000000', 'neha@acme.example',
   'employee', 'aaaaaaaa-0000-0000-0000-000000000001', sha256('invite-1'), now() + interval '7 days');
SELECT pg_temp.expect_error($$
  INSERT INTO invitations (org_id, email, role, invited_by, token_hash, expires_at)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'NEHA@acme.example', 'admin',
          'aaaaaaaa-0000-0000-0000-000000000001', sha256('invite-2'), now() + interval '7 days')
$$, '23505', 'one open invitation per email per company, regardless of capitals');
SELECT pg_temp.expect_error($$
  INSERT INTO invitations (org_id, email, role, invited_by, token_hash, expires_at)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'boss@acme.example', 'owner',
          'aaaaaaaa-0000-0000-0000-000000000001', sha256('invite-3'), now() + interval '7 days')
$$, '23514', 'nobody can be invited as owner');

-- YOUR TURN 1: after revoking Neha's invitation, inviting her again must succeed.
--   a) UPDATE invitations SET revoked_at = now() WHERE id = '...01a1';
--   b) INSERT a new invitation for neha@acme.example (new token_hash, e.g. sha256('invite-4'))
--   c) SELECT pg_temp.expect_eq((SELECT count(*) FROM invitations WHERE email = 'neha@acme.example'), 2, '...');
UPDATE invitations SET revoked_at = now() WHERE id = 'aaaaaaaa-0000-0000-0000-0000000001a1';
INSERT INTO invitations (org_id, email, role, invited_by, token_hash, expires_at)
VALUES ('aaaaaaaa-0000-0000-0000-000000000000', 'neha@acme.example', 'employee',
        'aaaaaaaa-0000-0000-0000-000000000001', sha256('invite-4'), now() + interval '7 days');
SELECT pg_temp.expect_eq((SELECT count(*) FROM invitations WHERE email = 'neha@acme.example'), 2,
                         'a revoked invitation can be sent again');

-- ---------------------------------------------------------------------------
-- 8. Organization rules and automatic columns
-- ---------------------------------------------------------------------------
SELECT pg_temp.expect_error($$ UPDATE organizations SET timezone = 'Mars/Olympus_Mons' $$,
  '22023', 'unknown time zones are rejected');
SELECT pg_temp.expect_error($$ UPDATE organizations SET slug = 'Bad Slug!' $$,
  '23514', 'slugs must be lowercase letters, digits and hyphens');
SELECT pg_temp.expect_error($$ UPDATE organizations SET working_days = '{1,9}' $$,
  '23514', 'working days must be weekdays 1-7');

UPDATE memberships SET updated_at = '2000-01-01', job_title = 'Engineer'
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000002';
SELECT pg_temp.expect((SELECT updated_at > '2000-01-01' FROM memberships
                       WHERE id = 'aaaaaaaa-0000-0000-0000-000000000002'),
                      'updated_at is set by the database, even if the app sends another value');

-- YOUR TURN 2: a session cannot expire before it was created.
--   INSERT into sessions with expires_at = now() - interval '1 hour' inside
--   pg_temp.expect_error(...) and expect SQLSTATE 23514.
--   (user_id: Priya's id; token_hash: sha256('session-1'))
SELECT pg_temp.expect_error($$
  INSERT INTO sessions (user_id, token_hash, expires_at)
  VALUES ('00000000-0000-0000-0000-0000000000a1', sha256('session-1'), now() - interval '1 hour')
$$, '23514', 'a session cannot expire before it was created');

-- ---------------------------------------------------------------------------
-- 9. What the API role is not allowed to do at all
-- ---------------------------------------------------------------------------
SELECT pg_temp.expect_error($$ DELETE FROM organizations $$,
  '42501', 'the API role cannot delete organizations');
SELECT pg_temp.expect_error($$ CREATE TABLE sneaky (id int) $$,
  '42501', 'the API role cannot create tables');
SELECT pg_temp.expect_error($$ SELECT count(*) FROM drizzle.schema_migrations $$,
  '42501', 'the API role cannot read migration records');
