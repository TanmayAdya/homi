-- Private, bounded UTF-8 review JSON. One current record per named room and a
-- separate legacy bathroom slot. No raw camera images, native archives or URLs.
CREATE TABLE safeathome_private.case_scan_models (
 case_id text NOT NULL REFERENCES safeathome_private.cases(case_id) ON DELETE CASCADE,
 room_key text NOT NULL CHECK (room_key='legacy' OR (room_key LIKE 'room:%' AND length(room_key) BETWEEN 6 AND 205)),
 record bytea NOT NULL CHECK (octet_length(record) BETWEEN 1 AND 786432),
 PRIMARY KEY(case_id,room_key)
);
ALTER TABLE safeathome_private.case_scan_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE safeathome_private.case_scan_models FORCE ROW LEVEL SECURITY;
CREATE POLICY case_owner ON safeathome_private.case_scan_models TO safeathome_app
 USING(EXISTS(SELECT 1 FROM safeathome_private.cases c WHERE c.case_id=case_scan_models.case_id AND c.owner_id=current_setting('safeathome.user_id',true)))
 WITH CHECK(EXISTS(SELECT 1 FROM safeathome_private.cases c WHERE c.case_id=case_scan_models.case_id AND c.owner_id=current_setting('safeathome.user_id',true)));
DO $$ BEGIN EXECUTE format('CREATE POLICY lifecycle_operator ON safeathome_private.case_scan_models TO %I USING(true) WITH CHECK(true)',current_user); END $$;
REVOKE ALL ON safeathome_private.case_scan_models FROM PUBLIC;
GRANT SELECT,INSERT,UPDATE,DELETE ON safeathome_private.case_scan_models TO safeathome_app;
