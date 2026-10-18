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
--   - column-level SELECT elsewhere, excluding every column whose name matches the sensitive pattern.
-- Sessions default to read-only with a 15s statement timeout. A client can switch read-only off,
-- but holding only SELECT it still cannot change anything.

\set ON_ERROR_STOP on

BEGIN;

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

-- Rebuild column-level SELECT grants from the current schema.
DO $$
DECLARE
  blocked  constant text[] := ARRAY['user_sessions', 'customer_portal_tokens', 'smb_credentials', 'leads_api_tokens',
                                     'push_subscriptions', 'google_integrations', 'chatflow_connections'];
  sensitive constant text := '(password|passwd|token|secret|api_?key|_hash$|^hashed_|encrypted|credential|private_key|bank|iban|id_number|otp)';
  t record;
  cols text;
BEGIN
  FOR t IN SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
             AND c.relname <> ALL (blocked)
           ORDER BY c.relname LOOP
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
END
$$;

COMMIT;

SELECT count(DISTINCT table_name) AS readable_tables, count(*) AS readable_columns
  FROM information_schema.column_privileges
 WHERE grantee = 'wa_agent_ro' AND privilege_type = 'SELECT';
