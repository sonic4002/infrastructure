-- Read-only role for the WhatsApp agent (namespace wa-agent): role wa_agent_ro.
--
-- Idempotent. Every run resets the role's grants and rebuilds them from the current schema, so
-- re-run it after every migration: new tables and new columns stay unreadable until it runs again.
--
--   kubectl -n xoffice exec -i postgres-0 -- psql -U xoffice -d xoffice -v ON_ERROR_STOP=1 < xoffice/db/wa-agent-readonly.sql
--
-- To set or rotate the password, put "\set ro_password '<value>'" before the script on stdin (never
-- on the command line). The value should be a SCRAM-SHA-256 verifier, so the plain password never
-- reaches the server; the plain value is PROD_DB_RO_PASSWORD in secrets/wa-agent/01-secrets.yaml.
-- Without ro_password the existing password is kept (a newly created role cannot log in).
--
-- What the role gets:
--   - CONNECT on database xoffice, USAGE on schema public, SELECT only;
--   - nothing at all on the blocked tables below;
--   - column-level SELECT elsewhere, excluding every column whose name matches the sensitive pattern;
--   - rows of organization "המשרד A" only (wa_agent_org()), through row-level security policies named
--     wa_agent_org, FOR SELECT TO wa_agent_ro. A table is readable only if it has such a policy or is
--     in the open list (global lookup data). Tables with organization_id or smb_id are covered
--     automatically; any other new table stays unreadable until it is added to the rules below.
-- Sessions default to read-only with a 15s statement timeout. A client can switch read-only off,
-- but holding only SELECT it still cannot change anything.
--
-- RLS is enabled but never FORCEd: the app connects as xoffice, the table owner (and a superuser),
-- which bypasses RLS. The organization is fixed in the function wa_agent_org(), owned by xoffice,
-- not in a session setting the agent could change.

\set ON_ERROR_STOP on

BEGIN;

-- Enabling RLS locks each table exclusively; fail (and roll back) rather than queue the app behind us.
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'wa_agent_ro') THEN
    CREATE ROLE wa_agent_ro;
  END IF;
END
$$;

ALTER ROLE wa_agent_ro WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  INHERIT CONNECTION LIMIT 3 VALID UNTIL 'infinity';

\if :{?ro_password}
ALTER ROLE wa_agent_ro PASSWORD :'ro_password';
\endif

ALTER ROLE wa_agent_ro RESET ALL;
ALTER ROLE wa_agent_ro SET default_transaction_read_only = on;
ALTER ROLE wa_agent_ro SET statement_timeout = '15s';
ALTER ROLE wa_agent_ro SET idle_in_transaction_session_timeout = '30s';

-- Reset: no role memberships, no privileges on anything in the database.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT g.rolname FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
           WHERE m.member = 'wa_agent_ro'::regrole LOOP
    EXECUTE format('REVOKE %I FROM wa_agent_ro', r.rolname);
  END LOOP;
END
$$;

REVOKE ALL ON DATABASE xoffice FROM wa_agent_ro;
REVOKE ALL ON SCHEMA public FROM wa_agent_ro;
-- Table-level REVOKE also removes the column-level grants of the previous run.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM wa_agent_ro;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM wa_agent_ro;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM wa_agent_ro;
-- PUBLIC holds TEMP on the database by default; xoffice (the only other role) owns it and is unaffected.
REVOKE TEMPORARY ON DATABASE xoffice FROM PUBLIC;

GRANT CONNECT ON DATABASE xoffice TO wa_agent_ro;
GRANT USAGE ON SCHEMA public TO wa_agent_ro;

-- The organization the role may see: "המשרד A".
CREATE OR REPLACE FUNCTION public.wa_agent_org() RETURNS uuid
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  AS $$ SELECT 'b70ff10f-3e9e-4deb-a0f7-6ff7a8be147b'::uuid $$;

-- The sets the policies filter on. SECURITY DEFINER so a policy never reads another RLS table as
-- wa_agent_ro (no recursion between policies); the policies call them as (SELECT f()), so each
-- runs once per query. Each repeats the rule of its table's policy below.
CREATE OR REPLACE FUNCTION public.wa_agent_smb_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(id), '{}') FROM smbs WHERE organization_id = wa_agent_org() $$;

CREATE OR REPLACE FUNCTION public.wa_agent_worker_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(DISTINCT worker_id), '{}') FROM worker_organizations WHERE organization_id = wa_agent_org() $$;

-- People of the organization: its workers (any membership status) and its portal users.
CREATE OR REPLACE FUNCTION public.wa_agent_user_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(DISTINCT user_id), '{}') FROM (
          SELECT user_id FROM workers WHERE id = ANY (wa_agent_worker_ids())
          UNION ALL
          SELECT user_id FROM portal_users WHERE organization_id = wa_agent_org()) u
        WHERE user_id IS NOT NULL $$;

CREATE OR REPLACE FUNCTION public.wa_agent_task_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(id), '{}') FROM tasks WHERE organization_id = wa_agent_org() $$;

CREATE OR REPLACE FUNCTION public.wa_agent_time_entry_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(id), '{}') FROM time_entries WHERE smb_id = ANY (wa_agent_smb_ids()) $$;

CREATE OR REPLACE FUNCTION public.wa_agent_org_role_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(id), '{}') FROM org_roles WHERE organization_id = wa_agent_org() $$;

CREATE OR REPLACE FUNCTION public.wa_agent_worker_organization_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(id), '{}') FROM worker_organizations WHERE organization_id = wa_agent_org() $$;

CREATE OR REPLACE FUNCTION public.wa_agent_worker_invitation_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(id), '{}') FROM worker_invitations WHERE organization_id = wa_agent_org() $$;

CREATE OR REPLACE FUNCTION public.wa_agent_meeting_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(id), '{}') FROM meetings WHERE organization_id = wa_agent_org() $$;

CREATE OR REPLACE FUNCTION public.wa_agent_reminder_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(id), '{}') FROM reminders WHERE organization_id = wa_agent_org() $$;

CREATE OR REPLACE FUNCTION public.wa_agent_portal_user_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(id), '{}') FROM portal_users WHERE organization_id = wa_agent_org() $$;

CREATE OR REPLACE FUNCTION public.wa_agent_payment_record_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(id), '{}') FROM payment_records WHERE organization_id = wa_agent_org() $$;

CREATE OR REPLACE FUNCTION public.wa_agent_lead_board_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS $$ SELECT coalesce(array_agg(id), '{}') FROM lead_boards WHERE organization_id = wa_agent_org() $$;

DO $$
DECLARE
  f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname LIKE 'wa\_agent\_%' LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO xoffice', f.sig);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO wa_agent_ro', f.sig);
  END LOOP;
END
$$;

-- Indexes on policy filter columns the schema lacks (outside alembic, hence the wa_agent_ prefix).
CREATE INDEX IF NOT EXISTS wa_agent_ix_google_task_mappings_organization_id ON public.google_task_mappings (organization_id);
CREATE INDEX IF NOT EXISTS wa_agent_ix_project_members_organization_id ON public.project_members (organization_id);

-- Rebuild the policies and column-level SELECT grants from the current schema.
DO $$
DECLARE
  blocked  constant text[] := ARRAY['user_sessions', 'customer_portal_tokens', 'smb_credentials', 'leads_api_tokens',
                                     'push_subscriptions', 'google_integrations', 'chatflow_connections'];
  -- Global lookup data with no organization in it: readable in full, no policy.
  open_tables constant text[] := ARRAY['permissions', 'alembic_version'];
  sensitive constant text := '(password|passwd|token|secret|api_?key|_hash$|^hashed_|encrypted|credential|private_key|bank|iban|id_number|otp)';
  t record;
  cols text;
BEGIN
  FOR t IN SELECT tablename FROM pg_policies WHERE schemaname = 'public' AND policyname = 'wa_agent_org' LOOP
    EXECUTE format('DROP POLICY wa_agent_org ON public.%I', t.tablename);
  END LOOP;

  -- Rules for tables without their own organization_id: the organization itself, its people, and
  -- rows reached through a parent row (the parent's rule lives in its wa_agent_*_ids() function).
  FOR t IN WITH rules(relname, rule) AS (VALUES
             ('organizations',                'id = public.wa_agent_org()'),
             ('users',                        'id = ANY ((SELECT public.wa_agent_user_ids())::uuid[])'),
             ('workers',                      'id = ANY ((SELECT public.wa_agent_worker_ids())::uuid[])'),
             -- organization_id IS NULL: the system default templates.
             ('task_templates',               'organization_id = public.wa_agent_org() OR organization_id IS NULL'),
             ('task_comments',                'task_id = ANY ((SELECT public.wa_agent_task_ids())::uuid[])'),
             ('task_notifications',           'task_id = ANY ((SELECT public.wa_agent_task_ids())::uuid[])'),
             ('task_status_history',          'task_id = ANY ((SELECT public.wa_agent_task_ids())::uuid[])'),
             ('time_entry_audits',            'time_entry_id = ANY ((SELECT public.wa_agent_time_entry_ids())::uuid[])'),
             ('role_permissions',             'role_id = ANY ((SELECT public.wa_agent_org_role_ids())::uuid[])'),
             ('worker_permission_denials',    'worker_organization_id = ANY ((SELECT public.wa_agent_worker_organization_ids())::uuid[])'),
             ('invitation_audit_logs',        'invitation_id = ANY ((SELECT public.wa_agent_worker_invitation_ids())::uuid[])'),
             ('meeting_attendees',            'meeting_id = ANY ((SELECT public.wa_agent_meeting_ids())::uuid[])'),
             ('meeting_notifications',        'meeting_id = ANY ((SELECT public.wa_agent_meeting_ids())::uuid[])'),
             ('reminder_notifications',       'reminder_id = ANY ((SELECT public.wa_agent_reminder_ids())::uuid[])'),
             ('portal_user_field_visibility', 'portal_user_id = ANY ((SELECT public.wa_agent_portal_user_ids())::uuid[])'),
             ('portal_user_permissions',      'portal_user_id = ANY ((SELECT public.wa_agent_portal_user_ids())::uuid[])'),
             ('payment_record_lines',         'payment_record_id = ANY ((SELECT public.wa_agent_payment_record_ids())::uuid[])'),
             ('lead_board_grants',            'board_id = ANY ((SELECT public.wa_agent_lead_board_ids())::uuid[])'))
           SELECT c.oid, c.relname, c.relname = ANY (open_tables) AS is_open,
                  coalesce(r.rule,
                    CASE WHEN EXISTS (SELECT FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'organization_id' AND NOT a.attisdropped)
                           THEN 'organization_id = public.wa_agent_org()'
                         WHEN EXISTS (SELECT FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'smb_id' AND NOT a.attisdropped)
                           THEN 'smb_id = ANY ((SELECT public.wa_agent_smb_ids())::uuid[])'
                    END) AS rule
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace LEFT JOIN rules r ON r.relname = c.relname
            -- Only tables: views, materialized views and foreign tables cannot carry a policy.
            WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
              AND c.relname <> ALL (blocked)
            ORDER BY c.relname LOOP
    CONTINUE WHEN NOT t.is_open AND t.rule IS NULL;
    IF NOT t.is_open THEN
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t.relname);
      EXECUTE format('CREATE POLICY wa_agent_org ON public.%I FOR SELECT TO wa_agent_ro USING (%s)', t.relname, t.rule);
    END IF;
    SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped AND a.attname !~* sensitive;
    IF cols IS NOT NULL THEN
      EXECUTE format('GRANT SELECT (%s) ON public.%I TO wa_agent_ro', cols, t.relname);
    END IF;
  END LOOP;
END
$$;

-- Fail the run (and roll everything back) if anything sensitive is readable or anything is writable.
DO $$
DECLARE
  blocked  constant text[] := ARRAY['user_sessions', 'customer_portal_tokens', 'smb_credentials', 'leads_api_tokens',
                                     'push_subscriptions', 'google_integrations', 'chatflow_connections'];
  sensitive constant text := '(password|passwd|token|secret|api_?key|_hash$|^hashed_|encrypted|credential|private_key|bank|iban|id_number|otp)';
  bad text;
BEGIN
  SELECT string_agg(c.relname || '.' || a.attname, ', ') INTO bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_attribute a ON a.attrelid = c.oid
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped
     AND (c.relname = ANY (blocked) OR a.attname ~* sensitive)
     AND has_column_privilege('wa_agent_ro', c.oid, a.attnum, 'SELECT');
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'wa_agent_ro can read sensitive columns: %', bad;
  END IF;

  SELECT string_agg(c.relname, ', ') INTO bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
     AND has_table_privilege('wa_agent_ro', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER');
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'wa_agent_ro can write to: %', bad;
  END IF;

  IF has_database_privilege('wa_agent_ro', 'xoffice', 'CREATE, TEMPORARY')
     OR has_schema_privilege('wa_agent_ro', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'wa_agent_ro can create objects';
  END IF;

  -- Fail closed: anything readable is either open lookup data or filtered by a wa_agent_org policy.
  SELECT string_agg(DISTINCT c.relname, ', ') INTO bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_attribute a ON a.attrelid = c.oid
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped
     AND has_column_privilege('wa_agent_ro', c.oid, a.attnum, 'SELECT')
     AND c.relname <> ALL (ARRAY['permissions', 'alembic_version'])
     AND NOT (c.relrowsecurity AND EXISTS (SELECT FROM pg_policies p WHERE p.schemaname = 'public'
                                             AND p.tablename = c.relname AND p.policyname = 'wa_agent_org'));
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'wa_agent_ro can read tables without an organization policy: %', bad;
  END IF;

  -- The only policies are ours, and they apply to wa_agent_ro alone.
  SELECT string_agg(tablename || '.' || policyname, ', ') INTO bad
    FROM pg_policies
   WHERE schemaname = 'public' AND (policyname <> 'wa_agent_org' OR roles <> '{wa_agent_ro}'::name[] OR cmd <> 'SELECT');
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'unexpected policies: %', bad;
  END IF;

  -- The app must keep bypassing RLS: never FORCE, and the RLS tables stay owned by xoffice.
  SELECT string_agg(c.relname, ', ') INTO bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
     AND (c.relforcerowsecurity OR (c.relrowsecurity AND c.relowner <> 'xoffice'::regrole));
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'RLS would apply to the app on: %', bad;
  END IF;

  IF NOT EXISTS (SELECT FROM public.organizations WHERE id = public.wa_agent_org()) THEN
    RAISE EXCEPTION 'wa_agent_org() is not an organization';
  END IF;
END
$$;

COMMIT;

SELECT count(DISTINCT table_name) AS readable_tables, count(*) AS readable_columns
  FROM information_schema.column_privileges
 WHERE grantee = 'wa_agent_ro' AND privilege_type = 'SELECT';
