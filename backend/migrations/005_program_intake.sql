CREATE TABLE safeathome_private.program_intake (
 case_id text NOT NULL REFERENCES safeathome_private.cases(case_id) ON DELETE CASCADE,
 program_id text NOT NULL CHECK (program_id IN ('scfhp-eaa','hpsm-eaa','rtp-home-repair')),
 record jsonb NOT NULL CHECK(jsonb_typeof(record)='object' AND record->>'schemaVersion'='2'
   AND record->>'caseId'=case_id AND record->>'programId'=program_id AND octet_length(record::text)<=16384),
 PRIMARY KEY(case_id,program_id)
);
ALTER TABLE safeathome_private.program_intake ENABLE ROW LEVEL SECURITY;
ALTER TABLE safeathome_private.program_intake FORCE ROW LEVEL SECURITY;
CREATE POLICY case_owner ON safeathome_private.program_intake TO safeathome_app
 USING(EXISTS(SELECT 1 FROM safeathome_private.cases c WHERE c.case_id=program_intake.case_id AND c.owner_id=current_setting('safeathome.user_id',true)))
 WITH CHECK(EXISTS(SELECT 1 FROM safeathome_private.cases c WHERE c.case_id=program_intake.case_id AND c.owner_id=current_setting('safeathome.user_id',true)));
DO $$ BEGIN EXECUTE format('CREATE POLICY lifecycle_operator ON safeathome_private.program_intake TO %I USING(true) WITH CHECK(true)',current_user); END $$;
REVOKE ALL ON safeathome_private.program_intake FROM PUBLIC;
GRANT SELECT,INSERT,UPDATE,DELETE ON safeathome_private.program_intake TO safeathome_app;
