-- Independent, bounded selected-data publication. No raw owner RLS is widened.
CREATE TABLE safeathome_private.share_sensitive (
  membership_id text PRIMARY KEY REFERENCES safeathome_private.case_shares(membership_id) ON DELETE CASCADE,
  case_id text NOT NULL REFERENCES safeathome_private.cases(case_id) ON DELETE CASCADE,
  owner_id text NOT NULL,
  record jsonb NOT NULL CHECK (jsonb_typeof(record)='object' AND octet_length(record::text)<=65536)
);
ALTER TABLE safeathome_private.share_sensitive ENABLE ROW LEVEL SECURITY;
ALTER TABLE safeathome_private.share_sensitive FORCE ROW LEVEL SECURITY;
CREATE POLICY sensitive_owner ON safeathome_private.share_sensitive TO safeathome_app
  USING (owner_id=current_setting('safeathome.user_id',true))
  WITH CHECK (owner_id=current_setting('safeathome.user_id',true) AND EXISTS (
    SELECT 1 FROM safeathome_private.case_shares s WHERE s.membership_id=share_sensitive.membership_id
      AND s.case_id=share_sensitive.case_id AND s.owner_id=share_sensitive.owner_id));
DO $$ BEGIN
  EXECUTE format('CREATE POLICY lifecycle_operator ON safeathome_private.share_sensitive TO %I USING (true) WITH CHECK (true)', current_user);
END $$;
REVOKE ALL ON safeathome_private.share_sensitive FROM PUBLIC;
GRANT SELECT,INSERT,UPDATE,DELETE ON safeathome_private.share_sensitive TO safeathome_app;

CREATE FUNCTION safeathome_private.clear_sensitive_scope() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF NEW.revoked OR NOT NEW.accepted OR NEW.projection IS NULL OR NEW.definition->>'role'<>'helper'
    OR NEW.definition IS DISTINCT FROM OLD.definition
    OR NEW.permission_revision<>OLD.permission_revision
  THEN DELETE FROM safeathome_private.share_sensitive WHERE membership_id=NEW.membership_id; END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION safeathome_private.clear_sensitive_scope() FROM PUBLIC;
CREATE TRIGGER clear_sensitive_scope AFTER UPDATE ON safeathome_private.case_shares
  FOR EACH ROW EXECUTE FUNCTION safeathome_private.clear_sensitive_scope();

-- Internal operator-only helper. It emits a fixed field allowlist, never a raw
-- case, profile, image byte, form, PDF, annotation or unselected intake record.
CREATE FUNCTION safeathome_private.sensitive_available(item safeathome_private.case_shares, categories jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE parent safeathome_private.cases; f jsonb; m jsonb; q jsonb; a jsonb; intake record;
  photos jsonb; measurements jsonb:='[]'; answers jsonb:='[]'; mid text;
BEGIN
  SELECT * INTO parent FROM safeathome_private.cases WHERE case_id=item.case_id;
  SELECT COALESCE(jsonb_agg(descriptor ORDER BY evidence_id),'[]') INTO photos
    FROM safeathome_private.evidence WHERE case_id=item.case_id AND bytes IS NOT NULL AND octet_length(bytes)<=8388608
      AND descriptor IS NOT NULL AND item.definition->'scope'->'findingIds' ? finding_id;
  FOR f IN SELECT value FROM jsonb_array_elements(parent.snapshot->'findings') LOOP
    IF NOT item.definition->'scope'->'findingIds' ? (f->>'id') OR f->>'reviewState'<>'confirmed' THEN CONTINUE; END IF;
    FOR m IN SELECT value FROM jsonb_array_elements(f->'measurements') LOOP
      -- A named type within a stable finding is the additive identity map. An
      -- ambiguous legacy duplicate is excluded; array positions are never IDs.
      IF (SELECT count(*) FROM jsonb_array_elements(f->'measurements') d WHERE d->>'type'=m->>'type')<>1 THEN CONTINUE; END IF;
      mid:='measurement-'||encode(sha256(convert_to(('['||to_jsonb(f->>'id')::text||','||to_jsonb(m->>'type')::text||']'),'UTF8')),'hex');
      measurements:=measurements||jsonb_build_array(jsonb_build_object('id',mid,'findingId',f->>'id','type',m->'type',
        'value',m->'value','unit',m->'unit','method',m->'method','confirmed',m->'confirmed'));
    END LOOP;
  END LOOP;
  FOR intake IN SELECT program_id,record FROM safeathome_private.program_intake WHERE case_id=item.case_id LOOP
    IF NOT item.definition->'scope'->'programIds' ? intake.program_id OR (intake.record->>'caseRevision')::bigint<>parent.revision
      OR intake.record->>'questionnaireVersion' IS DISTINCT FROM categories->intake.program_id->>'questionnaireVersion' THEN CONTINUE; END IF;
    FOR q IN SELECT value FROM jsonb_array_elements(categories->intake.program_id->'questions') LOOP
      SELECT value INTO a FROM jsonb_array_elements(intake.record->'answers') WHERE value->>'key'=q->>'key';
      IF a IS NOT NULL THEN answers:=answers||jsonb_build_array(jsonb_build_object('id',q->>'id','programId',intake.program_id,
        'key',q->>'key','label',q->>'label','category',q->>'category','questionnaireVersion',intake.record->>'questionnaireVersion',
        'intakeRevision',intake.record->'intakeRevision','value',a->'value','reviewState',a->>'reviewState')); END IF;
    END LOOP;
  END LOOP;
  RETURN jsonb_build_object('photos',photos,'measurements',measurements,'answers',answers);
END $$;
REVOKE ALL ON FUNCTION safeathome_private.sensitive_available(safeathome_private.case_shares,jsonb) FROM PUBLIC;

CREATE FUNCTION safeathome_private.sensitive_operation(action text, args jsonb, categories jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor text:=current_setting('safeathome.user_id',true); grant_row safeathome_private.case_shares;
  parent safeathome_private.cases; owner_mode boolean; available jsonb; content jsonb; selected jsonb; scope jsonb;
  source_hash text; expiry timestamptz; allow_pdf boolean; photo record; key text; ident text; at_time timestamptz;
BEGIN
  IF actor IS NULL OR actor='' OR args->>'membershipId' IS NULL OR args->>'expectedPermissionRevision' IS NULL
    OR action NOT IN ('list-sensitive-options','preview-sensitive-sharing','publish-sensitive-sharing','read-sensitive-sharing',
      'preview-sensitive-photo','read-sensitive-photo','preview-sensitive-report','read-sensitive-report')
    THEN RETURN jsonb_build_object('status','not_found'); END IF;
  PERFORM 1 FROM safeathome_private.repository_quota WHERE singleton FOR UPDATE;
  SELECT * INTO grant_row FROM safeathome_private.case_shares WHERE membership_id=args->>'membershipId';
  IF NOT FOUND OR actor NOT IN (grant_row.owner_id,grant_row.recipient_id) THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT * INTO parent FROM safeathome_private.cases WHERE case_id=grant_row.case_id FOR UPDATE;
  IF NOT FOUND OR parent.owner_id IS DISTINCT FROM grant_row.owner_id THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT * INTO grant_row FROM safeathome_private.case_shares WHERE membership_id=args->>'membershipId' FOR UPDATE;
  owner_mode:=actor=grant_row.owner_id; at_time:=clock_timestamp();
  IF grant_row.revoked OR NOT grant_row.accepted OR grant_row.projection IS NULL OR grant_row.definition->>'role'<>'helper'
    OR grant_row.expires_at<=at_time OR EXISTS(SELECT 1 FROM safeathome_private.closed_accounts WHERE owner_hash IN
      (encode(sha256(convert_to(actor,'UTF8')),'hex'),encode(sha256(convert_to(grant_row.owner_id,'UTF8')),'hex'),
       encode(sha256(convert_to(grant_row.recipient_id,'UTF8')),'hex')))
    THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF action IN ('list-sensitive-options','preview-sensitive-sharing','publish-sensitive-sharing','preview-sensitive-photo','preview-sensitive-report')
    AND NOT owner_mode THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT record INTO scope FROM safeathome_private.share_sensitive WHERE membership_id=grant_row.membership_id FOR UPDATE;
  scope:=COALESCE(scope,'{}'::jsonb);
  -- Exact uncertain-save retry, not a replay after revocation or another update.
  IF action='publish-sensitive-sharing' AND scope->>'mutationId'=args->>'mutationId' THEN
    IF scope->>'requestHash'<>args->>'requestHash' THEN RETURN jsonb_build_object('status','conflict'); END IF;
  ELSIF grant_row.permission_revision<>(args->>'expectedPermissionRevision')::integer THEN
    RETURN jsonb_build_object('status','conflict');
  END IF;
  available:=safeathome_private.sensitive_available(grant_row,categories);
  IF action='list-sensitive-options' THEN
    RETURN jsonb_build_object('status','ok','data',jsonb_build_object('schemaVersion','3','membershipId',grant_row.membership_id,
      'caseId',parent.case_id,'permissionRevision',grant_row.permission_revision,'caseRevision',parent.revision,
      'catalogRevision',parent.catalog_revision,'content',available));
  END IF;
  IF action='preview-sensitive-photo' THEN
    IF parent.revision<>(args->>'expectedCaseRevision')::bigint OR parent.catalog_revision<>(args->>'expectedCatalogRevision')::bigint
      THEN RETURN jsonb_build_object('status','conflict'); END IF;
    IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(available->'photos') p WHERE p->>'evidenceId'=args->>'evidenceId'
      AND p->>'evidenceRevision'=args->>'expectedEvidenceRevision') THEN RETURN jsonb_build_object('status','not_found'); END IF;
  ELSE
    IF action IN ('preview-sensitive-sharing','publish-sensitive-sharing','preview-sensitive-report')
      AND NOT (action='publish-sensitive-sharing' AND COALESCE(scope->>'mutationId'=args->>'mutationId',false)) THEN
      IF parent.revision<>(args->>'expectedCaseRevision')::bigint OR parent.catalog_revision<>(args->>'expectedCatalogRevision')::bigint
        THEN RETURN jsonb_build_object('status','conflict'); END IF;
      selected:=args->'selection'; expiry:=(args->>'expiresAt')::timestamptz; allow_pdf:=(args->>'allowPdf')::boolean;
      IF expiry<=at_time OR expiry>at_time+interval '30 days' OR (grant_row.expires_at IS NOT NULL AND expiry>grant_row.expires_at)
        OR jsonb_typeof(selected)<>'object' THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
    ELSE
      IF scope='{}'::jsonb OR (scope->>'expiresAt')::timestamptz<=at_time THEN RETURN jsonb_build_object('status','not_found'); END IF;
      selected:=scope->'selection'; expiry:=(scope->>'expiresAt')::timestamptz; allow_pdf:=(scope->>'allowPdf')::boolean;
      IF parent.revision<>(scope->>'caseRevision')::bigint OR parent.catalog_revision<>(scope->>'catalogRevision')::bigint
        THEN RETURN jsonb_build_object('status','conflict'); END IF;
    END IF;
    content:='{}';
    FOR key,ident IN SELECT * FROM (VALUES ('photos','photoIds'),('measurements','measurementIds'),('answers','answerIds')) k(a,b) LOOP
      content:=content||jsonb_build_object(key,COALESCE((SELECT jsonb_agg(value) FROM jsonb_array_elements(available->key)
        WHERE selected->ident ? (value->>CASE WHEN key='photos' THEN 'evidenceId' ELSE 'id' END)),'[]'::jsonb));
      IF jsonb_array_length(content->key)<>jsonb_array_length(selected->ident) THEN RETURN jsonb_build_object('status','conflict'); END IF;
    END LOOP;
    IF jsonb_array_length(content->'photos')>6 OR jsonb_array_length(content->'measurements')>32 OR jsonb_array_length(content->'answers')>32
      THEN RETURN jsonb_build_object('status','quota_exceeded'); END IF;
    source_hash:=encode(sha256(convert_to(jsonb_build_array(parent.revision,parent.catalog_revision,selected,content,allow_pdf,args->>'expiresAt')::text,'UTF8')),'hex');
    -- Read paths use the exact publication timestamp representation.
    IF action IN ('read-sensitive-sharing','read-sensitive-photo','read-sensitive-report') OR
      (action='publish-sensitive-sharing' AND scope->>'mutationId'=args->>'mutationId') THEN
      source_hash:=encode(sha256(convert_to(jsonb_build_array(parent.revision,parent.catalog_revision,selected,content,allow_pdf,scope->>'expiresAt')::text,'UTF8')),'hex');
      IF source_hash IS DISTINCT FROM scope->>'sourceHash' THEN RETURN jsonb_build_object('status','conflict'); END IF;
    END IF;
    IF action IN ('read-sensitive-photo','read-sensitive-report') AND source_hash IS DISTINCT FROM args->>'sourceHash'
      THEN RETURN jsonb_build_object('status','conflict'); END IF;
    IF action IN ('publish-sensitive-sharing','preview-sensitive-report') AND source_hash IS DISTINCT FROM args->>'previewHash'
      THEN RETURN jsonb_build_object('status','conflict'); END IF;
    IF action='publish-sensitive-sharing' AND scope->>'mutationId' IS DISTINCT FROM args->>'mutationId' THEN
      IF grant_row.permission_revision>=1000 THEN RETURN jsonb_build_object('status','quota_exceeded'); END IF;
      scope:=jsonb_build_object('selection',selected,'allowPdf',allow_pdf,'expiresAt',args->>'expiresAt','content',content,
        'sourceHash',source_hash,'caseRevision',parent.revision,'catalogRevision',parent.catalog_revision,
        'publishedAt',to_char(at_time AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
        'mutationId',args->>'mutationId','requestHash',args->>'requestHash');
      IF octet_length(scope::text)>65536 THEN RETURN jsonb_build_object('status','quota_exceeded'); END IF;
      UPDATE safeathome_private.case_shares SET permission_revision=permission_revision+1,
        audit=safeathome_private.share_audit(audit,'changed') WHERE membership_id=grant_row.membership_id RETURNING * INTO grant_row;
      INSERT INTO safeathome_private.share_sensitive(membership_id,case_id,owner_id,record)
        VALUES(grant_row.membership_id,parent.case_id,grant_row.owner_id,scope)
        ON CONFLICT(membership_id) DO UPDATE SET record=EXCLUDED.record;
    END IF;
  END IF;
  IF action IN ('preview-sensitive-photo','read-sensitive-photo') THEN
    IF action='read-sensitive-photo' AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(content->'photos') p WHERE p->>'evidenceId'=args->>'evidenceId'
      AND p->>'evidenceRevision'=args->>'expectedEvidenceRevision') THEN RETURN jsonb_build_object('status','not_found'); END IF;
    -- Authorization, current binding and caps checked before fetching any bytes.
    SELECT descriptor,bytes INTO photo FROM safeathome_private.evidence WHERE case_id=parent.case_id
      AND evidence_id=args->>'evidenceId' AND revision=(args->>'expectedEvidenceRevision')::integer
      AND bytes IS NOT NULL AND octet_length(bytes)<=8388608;
    IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
    RETURN jsonb_build_object('status','ok','data',jsonb_build_object('schemaVersion','3','membershipId',grant_row.membership_id,
      'permissionRevision',grant_row.permission_revision,'descriptor',photo.descriptor,'photoBase64',replace(encode(photo.bytes,'base64'),E'\n','')));
  END IF;
  IF action IN ('read-sensitive-report','preview-sensitive-report') AND NOT allow_pdf THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF NOT owner_mode THEN UPDATE safeathome_private.case_shares SET audit=safeathome_private.share_audit(audit,'read') WHERE membership_id=grant_row.membership_id; END IF;
  RETURN jsonb_build_object('status','ok','data',jsonb_build_object('schemaVersion','3','caseId',parent.case_id,
    'membershipId',grant_row.membership_id,'permissionRevision',grant_row.permission_revision,'caseRevision',parent.revision,
    'catalogRevision',parent.catalog_revision,'content',content,'selection',selected,'allowPdf',allow_pdf,
    'expiresAt',CASE WHEN action IN ('preview-sensitive-sharing','preview-sensitive-report') THEN args->>'expiresAt' ELSE scope->>'expiresAt' END,
    'sourceHash',source_hash,'acknowledgedMutationId',CASE WHEN action='publish-sensitive-sharing' THEN args->>'mutationId' ELSE NULL END));
END $$;
REVOKE ALL ON FUNCTION safeathome_private.sensitive_operation(text,jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.sensitive_operation(text,jsonb,jsonb) TO safeathome_app;
