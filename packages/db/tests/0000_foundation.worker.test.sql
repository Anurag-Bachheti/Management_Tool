-- run-as: opsflow_worker
-- The worker role bypasses row-level security. These tests prove what it is for
-- (cross-company jobs, deleting a company) and that deletion cleans up properly.

INSERT INTO users (id, email, display_name) VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'owner@initech.example', 'Initech Owner'),
  ('00000000-0000-0000-0000-0000000000d1', 'owner@hooli.example',   'Hooli Owner');
INSERT INTO organizations (id, name, slug) VALUES
  ('cccccccc-0000-0000-0000-000000000000', 'Initech', 'initech'),
  ('dddddddd-0000-0000-0000-000000000000', 'Hooli',   'hooli');
INSERT INTO memberships (id, org_id, user_id, role) VALUES
  ('cccccccc-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000c1', 'owner'),
  ('dddddddd-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d1', 'owner');
INSERT INTO invitations (org_id, email, role, invited_by, token_hash, expires_at) VALUES
  ('cccccccc-0000-0000-0000-000000000000', 'new@initech.example', 'employee',
   'cccccccc-0000-0000-0000-000000000001', sha256('w-invite-1'), now() + interval '7 days');

SELECT pg_temp.expect_eq((SELECT count(*) FROM organizations), 2, 'the worker sees every company (it bypasses RLS)');

DELETE FROM organizations WHERE id = 'cccccccc-0000-0000-0000-000000000000';
SELECT pg_temp.expect_eq((SELECT count(*) FROM memberships WHERE org_id = 'cccccccc-0000-0000-0000-000000000000'), 0,
                         'deleting a company deletes its memberships');
SELECT pg_temp.expect_eq((SELECT count(*) FROM invitations WHERE org_id = 'cccccccc-0000-0000-0000-000000000000'), 0,
                         'deleting a company deletes its invitations');
SELECT pg_temp.expect_eq((SELECT count(*) FROM organizations), 1, 'the other company is untouched');
SELECT pg_temp.expect_eq((SELECT count(*) FROM users), 2, 'user logins survive company deletion');

SELECT pg_temp.expect_error($$ DELETE FROM users WHERE id = '00000000-0000-0000-0000-0000000000d1' $$,
  '23503', 'a user with a membership cannot be deleted by accident');
