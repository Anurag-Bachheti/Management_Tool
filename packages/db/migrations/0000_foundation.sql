-- Custom SQL migration file, put your code below! --

CREATE EXTENSION IF NOT EXISTS citext;

-- Part 2. Helper functions

-- The organization for the current transaction, set by the API with:
--   SELECT set_config('app.org_id', $1, true);
CREATE FUNCTION app_org_id() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT NULLIF(current_setting('app.org_id', true), '')::uuid
$$;

-- The signed-in user for the current transaction, set the same way.
CREATE FUNCTION app_user_id() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT NULLIF(current_setting('app.user_id', true), '')::uuid
$$;

-- Keeps updated_at correct on every UPDATE, even if the app forgets.
CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Rejects time zone names Postgres does not know ('Mars/Base').
CREATE FUNCTION validate_org_timezone() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM now() AT TIME ZONE NEW.timezone;
  RETURN NEW;
END $$;

-- Part 3. Identity (global: not tied to an organization, no RLS)
CREATE TABLE users (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email             citext NOT NULL UNIQUE CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  password_hash     text,
  display_name      text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 120),
  email_verified_at timestamptz,
  last_login_at     timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash   bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  ip           inet,
  user_agent   text CHECK (length(user_agent) <= 512),
  CHECK (expires_at > created_at)
);
CREATE INDEX sessions_user_live_idx ON sessions (user_id) WHERE revoked_at IS NULL;
CREATE INDEX sessions_expires_idx   ON sessions (expires_at);

CREATE TABLE email_tokens (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose    text NOT NULL CHECK (purpose IN ('verify_email', 'reset_password')),
  token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX email_tokens_user_idx ON email_tokens (user_id, purpose) WHERE used_at IS NULL;

-- Part 4. Organizations
CREATE TABLE organizations (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                   text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  slug                   text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'),
  timezone               text NOT NULL DEFAULT 'Asia/Kolkata',
  working_days           smallint[] NOT NULL DEFAULT '{1,2,3,4,5}'
                         CHECK (working_days <@ '{1,2,3,4,5,6,7}'::smallint[]
                                AND cardinality(working_days) BETWEEN 1 AND 7),
  leave_year_start_month smallint NOT NULL DEFAULT 1 CHECK (leave_year_start_month BETWEEN 1 AND 12),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER organizations_timezone_chk BEFORE INSERT OR UPDATE OF timezone ON organizations
  FOR EACH ROW EXECUTE FUNCTION validate_org_timezone();

  -- Part 5. Memberships (a user's employment in one organization)
CREATE TABLE memberships (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES users(id),
  role           text NOT NULL CHECK (role IN ('owner', 'admin', 'manager', 'employee')),
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deactivated')),
  employee_code  text CHECK (length(btrim(employee_code)) BETWEEN 1 AND 32),
  job_title      text CHECK (length(job_title) <= 120),
  phone          text CHECK (length(phone) <= 32),
  joined_on      date,
  deactivated_at timestamptz,
  version        integer NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, id),
  UNIQUE (org_id, user_id),
  CHECK ((status = 'deactivated') = (deactivated_at IS NOT NULL)),
  CHECK (role <> 'owner' OR status = 'active')
);
CREATE UNIQUE INDEX memberships_employee_code_uq ON memberships (org_id, lower(employee_code)) WHERE employee_code IS NOT NULL;
CREATE UNIQUE INDEX memberships_one_owner_uq     ON memberships (org_id) WHERE role = 'owner';
CREATE INDEX memberships_user_idx ON memberships (user_id);

-- Part 6. Invitations
CREATE TABLE invitations (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                 uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email                  citext NOT NULL,
  role                   text NOT NULL CHECK (role IN ('admin', 'manager', 'employee')),
  invited_by             uuid NOT NULL,
  token_hash             bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
  expires_at             timestamptz NOT NULL,
  accepted_at            timestamptz,
  accepted_membership_id uuid,
  revoked_at             timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CHECK (accepted_at IS NULL OR revoked_at IS NULL),
  CHECK ((accepted_at IS NULL) = (accepted_membership_id IS NULL)),
  FOREIGN KEY (org_id, invited_by)             REFERENCES memberships (org_id, id),
  FOREIGN KEY (org_id, accepted_membership_id) REFERENCES memberships (org_id, id)
);
CREATE UNIQUE INDEX invitations_open_uq ON invitations (org_id, email)
  WHERE accepted_at IS NULL AND revoked_at IS NULL;

  -- Part 7. updated_at triggers
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['users', 'organizations', 'memberships'] LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
      t || '_updated_at', t);
  END LOOP;
END $$;

-- Part 8. Row-level security
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON organizations
  USING (id = app_org_id()) WITH CHECK (id = app_org_id());

  DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['memberships', 'invitations'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (org_id = app_org_id()) WITH CHECK (org_id = app_org_id())', t);
  END LOOP;
END $$;

-- Read-only, user-context policies: before an org is chosen, a signed-in user
-- can see their own memberships and the orgs they belong to, and nothing else.
CREATE POLICY own_memberships ON memberships FOR SELECT
  USING (app_org_id() IS NULL AND user_id = app_user_id());
CREATE POLICY member_organizations ON organizations FOR SELECT
  USING (app_org_id() IS NULL
         AND EXISTS (SELECT 1 FROM memberships m
                     WHERE m.org_id = organizations.id AND m.user_id = app_user_id()));

-- Part 9. Guard: fail if any table with org_id lacks forced RLS
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(c.relname, ', ') INTO missing
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'org_id' AND NOT a.attisdropped
  WHERE c.relkind = 'r' AND NOT (c.relrowsecurity AND c.relforcerowsecurity);
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'tenant tables without forced RLS: %', missing;
  END IF;
END $$;

-- Part 10. Privileges
GRANT USAGE ON SCHEMA public TO opsflow_app, opsflow_worker;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO opsflow_app, opsflow_worker;
REVOKE DELETE ON organizations FROM opsflow_app;     -- deleting an org is a worker job
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO opsflow_app, opsflow_worker;