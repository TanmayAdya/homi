-- Apply inside one transaction as a dedicated migration owner, never the runtime login.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'safeathome_app') THEN
    CREATE ROLE safeathome_app NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'safeathome_app'
    AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
    RAISE EXCEPTION 'Unsafe existing application role';
  END IF;
END $$;

CREATE SCHEMA safeathome_private;
REVOKE ALL ON SCHEMA safeathome_private FROM PUBLIC;
GRANT USAGE ON SCHEMA safeathome_private TO safeathome_app;

CREATE TABLE safeathome_private.repository_quota (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  case_count bigint NOT NULL DEFAULT 0 CHECK (case_count BETWEEN 0 AND 64),
  asset_count bigint NOT NULL DEFAULT 0 CHECK (asset_count BETWEEN 0 AND 64),
  artifact_count bigint NOT NULL DEFAULT 0 CHECK (artifact_count BETWEEN 0 AND 16),
  stored_bytes bigint NOT NULL DEFAULT 0 CHECK (stored_bytes BETWEEN 0 AND 67108864)
);
INSERT INTO safeathome_private.repository_quota(singleton) VALUES (true);

CREATE TABLE safeathome_private.cases (
  case_id text PRIMARY KEY CHECK (length(case_id) BETWEEN 1 AND 200),
  owner_id text NOT NULL CHECK (length(owner_id) BETWEEN 1 AND 200),
  revision bigint NOT NULL CHECK (revision BETWEEN 1 AND 9007199254740991),
  catalog_revision bigint NOT NULL DEFAULT 0 CHECK (catalog_revision BETWEEN 0 AND 9007199254740991),
  snapshot jsonb NOT NULL CHECK (jsonb_typeof(snapshot) = 'object'
    AND snapshot->>'schemaVersion' = '1' AND snapshot->>'caseId' = case_id
    AND (snapshot->>'revision')::numeric = revision)
);
CREATE INDEX cases_owner_idx ON safeathome_private.cases(owner_id);
CREATE TABLE safeathome_private.matches (
  case_id text PRIMARY KEY REFERENCES safeathome_private.cases(case_id),
  response jsonb NOT NULL CHECK (jsonb_typeof(response) = 'object')
);
CREATE TABLE safeathome_private.packets (
  case_id text NOT NULL REFERENCES safeathome_private.cases(case_id),
  generation_key text NOT NULL CHECK (generation_key ~ '^[A-Za-z0-9_-]{8,128}$'),
  packet_id text NOT NULL UNIQUE,
  context_fingerprint text NOT NULL,
  packet jsonb CHECK (packet IS NULL OR jsonb_typeof(packet) = 'object'),
  PRIMARY KEY (case_id, generation_key)
);
CREATE TABLE safeathome_private.form_answers (
  case_id text NOT NULL REFERENCES safeathome_private.cases(case_id),
  program_id text NOT NULL,
  answer_revision bigint NOT NULL CHECK (answer_revision BETWEEN 1 AND 9007199254740991),
  record jsonb NOT NULL CHECK (jsonb_typeof(record) = 'object'
    AND record->>'caseId' = case_id AND record->>'programId' = program_id
    AND (record->>'answerRevision')::numeric = answer_revision),
  PRIMARY KEY(case_id, program_id)
);
CREATE TABLE safeathome_private.evidence (
  case_id text NOT NULL REFERENCES safeathome_private.cases(case_id),
  evidence_id text NOT NULL,
  finding_id text NOT NULL,
  revision bigint NOT NULL CHECK (revision BETWEEN 1 AND 9007199254740991),
  prepared_at text NOT NULL,
  descriptor jsonb,
  bytes bytea,
  PRIMARY KEY(case_id, evidence_id),
  CHECK ((descriptor IS NULL AND bytes IS NULL) OR
    (descriptor IS NOT NULL AND bytes IS NOT NULL AND jsonb_typeof(descriptor) = 'object'
     AND descriptor->>'caseId' = case_id AND descriptor->>'evidenceId' = evidence_id
     AND descriptor->>'findingId' = finding_id AND (descriptor->>'evidenceRevision')::numeric = revision
     AND descriptor->>'preparedAt' = prepared_at AND octet_length(bytes) BETWEEN 8 AND 25165824
     AND (descriptor->>'byteLength')::numeric = octet_length(bytes)))
);
CREATE TABLE safeathome_private.exports (
  artifact_id text PRIMARY KEY,
  case_id text NOT NULL REFERENCES safeathome_private.cases(case_id),
  generation_key text NOT NULL CHECK (generation_key ~ '^[A-Za-z0-9_-]{8,128}$'),
  bindings jsonb NOT NULL CHECK (jsonb_typeof(bindings) = 'object'),
  metadata jsonb NOT NULL CHECK (jsonb_typeof(metadata) = 'object'
    AND metadata->>'artifactId' = artifact_id AND metadata->>'caseId' = case_id),
  bytes bytea,
  invalidated boolean NOT NULL DEFAULT false,
  last_checked_at text NOT NULL,
  UNIQUE(case_id, generation_key),
  CHECK ((invalidated AND bytes IS NULL) OR
    (NOT invalidated AND bytes IS NOT NULL AND octet_length(bytes) BETWEEN 8 AND 33554432
      AND (metadata->>'byteLength')::numeric = octet_length(bytes)))
);

-- FORCE protects table-owner connections too; runtime startup separately rejects
-- superusers, BYPASSRLS, table owners, and migration-role membership.
ALTER TABLE safeathome_private.cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE safeathome_private.cases FORCE ROW LEVEL SECURITY;
CREATE POLICY case_owner ON safeathome_private.cases TO safeathome_app
  USING (owner_id = current_setting('safeathome.user_id', true))
  WITH CHECK (owner_id = current_setting('safeathome.user_id', true));
DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['matches','packets','form_answers','evidence','exports'] LOOP
    EXECUTE format('ALTER TABLE safeathome_private.%I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('ALTER TABLE safeathome_private.%I FORCE ROW LEVEL SECURITY', table_name);
    EXECUTE format('CREATE POLICY case_owner ON safeathome_private.%I TO safeathome_app
      USING (EXISTS (SELECT 1 FROM safeathome_private.cases c WHERE c.case_id = %I.case_id
        AND c.owner_id = current_setting(''safeathome.user_id'', true)))
      WITH CHECK (EXISTS (SELECT 1 FROM safeathome_private.cases c WHERE c.case_id = %I.case_id
        AND c.owner_id = current_setting(''safeathome.user_id'', true)))', table_name, table_name, table_name);
  END LOOP;
END $$;
ALTER TABLE safeathome_private.repository_quota ENABLE ROW LEVEL SECURITY;
ALTER TABLE safeathome_private.repository_quota FORCE ROW LEVEL SECURITY;
CREATE POLICY application_quota ON safeathome_private.repository_quota TO safeathome_app
  USING (true) WITH CHECK (true);
REVOKE ALL ON ALL TABLES IN SCHEMA safeathome_private FROM PUBLIC;
GRANT SELECT, UPDATE ON safeathome_private.repository_quota TO safeathome_app;
GRANT SELECT, INSERT, UPDATE ON safeathome_private.cases, safeathome_private.packets,
  safeathome_private.form_answers, safeathome_private.evidence, safeathome_private.exports TO safeathome_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON safeathome_private.matches TO safeathome_app;
