-- Private assessment provenance and editable canonical-image overlays.
CREATE TABLE safeathome_private.assessment_metadata (
 case_id text PRIMARY KEY REFERENCES safeathome_private.cases(case_id) ON DELETE CASCADE,
 record jsonb NOT NULL CHECK (jsonb_typeof(record)='object' AND record->>'schemaVersion'='2'
   AND record->>'caseId'=case_id AND octet_length(record::text)<=524288
   AND jsonb_array_length(record->'history')<=500)
);
CREATE TABLE safeathome_private.evidence_annotations (
 case_id text NOT NULL, evidence_id text NOT NULL,
 record jsonb NOT NULL CHECK (jsonb_typeof(record)='object' AND record->>'schemaVersion'='2'
   AND record->>'caseId'=case_id AND record->>'evidenceId'=evidence_id
   AND octet_length(record::text)<=16384 AND jsonb_array_length(record->'marks')<=20),
 PRIMARY KEY(case_id,evidence_id),
 FOREIGN KEY(case_id,evidence_id) REFERENCES safeathome_private.evidence(case_id,evidence_id) ON DELETE CASCADE
);
DO $$ DECLARE name text; BEGIN
 FOREACH name IN ARRAY ARRAY['assessment_metadata','evidence_annotations'] LOOP
  EXECUTE format('ALTER TABLE safeathome_private.%I ENABLE ROW LEVEL SECURITY',name);
  EXECUTE format('ALTER TABLE safeathome_private.%I FORCE ROW LEVEL SECURITY',name);
  EXECUTE format('CREATE POLICY case_owner ON safeathome_private.%I TO safeathome_app USING(EXISTS(SELECT 1 FROM safeathome_private.cases c WHERE c.case_id=%I.case_id AND c.owner_id=current_setting(''safeathome.user_id'',true))) WITH CHECK(EXISTS(SELECT 1 FROM safeathome_private.cases c WHERE c.case_id=%I.case_id AND c.owner_id=current_setting(''safeathome.user_id'',true)))',name,name,name);
  EXECUTE format('CREATE POLICY lifecycle_operator ON safeathome_private.%I TO %I USING(true) WITH CHECK(true)',name,current_user);
  EXECUTE format('REVOKE ALL ON safeathome_private.%I FROM PUBLIC',name);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON safeathome_private.%I TO safeathome_app',name);
 END LOOP;
END $$;
