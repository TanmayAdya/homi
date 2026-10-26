-- Private manual reports, never evidence of agency receipt or a benefit decision.
-- Stop and drain older API instances before applying: account-deletion previews
-- must include this new private content before requests may append it.
CREATE TABLE safeathome_private.request_history (
  case_id text NOT NULL REFERENCES safeathome_private.cases(case_id) ON DELETE CASCADE,
  program_id text NOT NULL CHECK (length(program_id) BETWEEN 1 AND 200),
  request_revision bigint NOT NULL CHECK (request_revision BETWEEN 1 AND 50),
  record jsonb NOT NULL,
  PRIMARY KEY (case_id, program_id),
  CONSTRAINT request_history_record CHECK ((
    jsonb_typeof(record) = 'object'
    AND record->>'schemaVersion' = '1'
    AND record->>'provenance' = 'user_reported'
    AND record->>'caseId' = case_id
    AND record->>'programId' = program_id
    AND (record->>'requestRevision')::numeric = request_revision
    AND jsonb_typeof(record->'events') = 'array'
    AND jsonb_array_length(record->'events') = request_revision
    AND octet_length(record::text) <= 262144
  ) IS TRUE)
);
ALTER TABLE safeathome_private.request_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE safeathome_private.request_history FORCE ROW LEVEL SECURITY;
CREATE POLICY case_owner ON safeathome_private.request_history TO safeathome_app
  USING (EXISTS (SELECT 1 FROM safeathome_private.cases c
    WHERE c.case_id = request_history.case_id
      AND c.owner_id = current_setting('safeathome.user_id', true))
    AND NOT EXISTS (SELECT 1 FROM safeathome_private.closed_accounts
      WHERE owner_hash = encode(sha256(convert_to(current_setting('safeathome.user_id', true), 'UTF8')), 'hex')))
  WITH CHECK (EXISTS (SELECT 1 FROM safeathome_private.cases c
    WHERE c.case_id = request_history.case_id
      AND c.owner_id = current_setting('safeathome.user_id', true))
    AND NOT EXISTS (SELECT 1 FROM safeathome_private.closed_accounts
      WHERE owner_hash = encode(sha256(convert_to(current_setting('safeathome.user_id', true), 'UTF8')), 'hex')));
DO $$
BEGIN
  EXECUTE format('CREATE POLICY lifecycle_operator ON safeathome_private.request_history TO %I USING (true) WITH CHECK (true)', current_user);
END $$;
REVOKE ALL ON safeathome_private.request_history FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON safeathome_private.request_history TO safeathome_app;
