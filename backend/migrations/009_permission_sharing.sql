-- No owner/raw-case policy is widened. Only an allowlisted published projection
-- is visible to an active recipient. Every write uses quota -> case -> grant;
-- recipient operations use quota -> grant and never lock an owner case.
CREATE TABLE safeathome_private.case_shares (
  membership_id text PRIMARY KEY,
  case_id text NOT NULL REFERENCES safeathome_private.cases(case_id) ON DELETE CASCADE,
  owner_id text NOT NULL,
  recipient_id text NOT NULL CHECK (recipient_id <> owner_id),
  creation_key text NOT NULL CHECK (creation_key ~ '^[a-f0-9]{64}$'),
  invitation_hash text UNIQUE CHECK (invitation_hash ~ '^[a-f0-9]{64}$'),
  invitation_expires_at timestamptz NOT NULL,
  expires_at timestamptz,
  accepted boolean NOT NULL DEFAULT false,
  revoked boolean NOT NULL DEFAULT false,
  permission_revision integer NOT NULL DEFAULT 1 CHECK (permission_revision BETWEEN 1 AND 1000),
  definition jsonb NOT NULL,
  projection jsonb,
  notes jsonb NOT NULL DEFAULT '{"events":[]}',
  audit jsonb NOT NULL DEFAULT '{"events":[]}',
  CHECK (definition->>'role' IN ('viewer','helper') AND jsonb_typeof(definition->'scope')='object'),
  CHECK (projection IS NULL OR (projection->>'caseId'=case_id AND projection->>'schemaVersion'='3')),
  CHECK (jsonb_typeof(notes->'events')='array' AND jsonb_array_length(notes->'events') <= 50),
  CHECK (jsonb_typeof(audit->'events')='array' AND jsonb_array_length(audit->'events') <= 100),
  CHECK (octet_length(definition::text)+COALESCE(octet_length(projection::text),0)+octet_length(notes::text)+octet_length(audit::text) <= 98304),
  CHECK (NOT accepted OR invitation_hash IS NULL),
  CHECK (NOT revoked OR (invitation_hash IS NULL AND projection IS NULL AND notes='{"events":[]}'::jsonb))
);
CREATE INDEX shares_case ON safeathome_private.case_shares(case_id);
CREATE INDEX shares_recipient ON safeathome_private.case_shares(recipient_id);
ALTER TABLE safeathome_private.case_shares ENABLE ROW LEVEL SECURITY;
ALTER TABLE safeathome_private.case_shares FORCE ROW LEVEL SECURITY;
CREATE POLICY share_owner ON safeathome_private.case_shares TO safeathome_app
  USING (owner_id=current_setting('safeathome.user_id',true))
  WITH CHECK (owner_id=current_setting('safeathome.user_id',true) AND EXISTS (
    SELECT 1 FROM safeathome_private.cases c WHERE c.case_id=case_shares.case_id AND c.owner_id=case_shares.owner_id));
CREATE POLICY share_recipient ON safeathome_private.case_shares FOR SELECT TO safeathome_app
  USING (recipient_id=current_setting('safeathome.user_id',true) AND accepted AND NOT revoked
    AND projection IS NOT NULL AND (expires_at IS NULL OR expires_at>clock_timestamp()));
DO $$ BEGIN
  EXECUTE format('CREATE POLICY lifecycle_operator ON safeathome_private.case_shares TO %I USING (true) WITH CHECK (true)', current_user);
END $$;
REVOKE ALL ON safeathome_private.case_shares FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON safeathome_private.case_shares TO safeathome_app;
-- Recipient UPDATE/INSERT/DELETE is still denied by the owner-only write policy.

CREATE FUNCTION safeathome_private.share_audit(previous jsonb, kind text) RETURNS jsonb
LANGUAGE sql SET search_path=pg_catalog AS $$
  SELECT jsonb_build_object('events',COALESCE((SELECT jsonb_agg(value ORDER BY ord) FROM
    jsonb_array_elements(previous->'events') WITH ORDINALITY e(value,ord)
    WHERE ord>greatest(jsonb_array_length(previous->'events')-99,0)),'[]'::jsonb)
    ||jsonb_build_array(jsonb_build_object('type',kind,'actorId',current_setting('safeathome.user_id',true),
      'at',to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))))
$$;
REVOKE ALL ON FUNCTION safeathome_private.share_audit(jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.share_audit(jsonb,text) TO safeathome_app;

-- Bounded recipient discovery: at most 64 retained grants across owners. Only a
-- capacity boolean leaves this fixed function; it reveals no other owner's rows.
CREATE FUNCTION safeathome_private.share_recipient_has_capacity(recipient text) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT count(*)<64 FROM safeathome_private.case_shares WHERE recipient_id=recipient
$$;
REVOKE ALL ON FUNCTION safeathome_private.share_recipient_has_capacity(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.share_recipient_has_capacity(text) TO safeathome_app;

-- Audited privileged boundary: fixed tables, no dynamic SQL, fixed search_path,
-- identity only from the server transaction, both closure checks, row locks,
-- token hash and recipient binding, bounded notes, exact permission revision.
-- Never reads raw cases/photos/intake/forms/PDFs. No service credential is used.
CREATE FUNCTION safeathome_private.shared_operation(action text, args jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor text := current_setting('safeathome.user_id',true); item safeathome_private.case_shares;
  prior jsonb; result jsonb; at_time timestamptz;
BEGIN
  IF actor IS NULL OR actor='' THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF jsonb_typeof(args)<>'object' OR (action NOT IN ('review-invitation','list-shared-cases') AND
    (args->>'expectedPermissionRevision' IS NULL OR args->>'expectedPermissionRevision' !~ '^[1-9][0-9]{0,3}$')) THEN
    RETURN jsonb_build_object('status','invalid_request'); END IF;
  PERFORM 1 FROM safeathome_private.repository_quota WHERE singleton FOR UPDATE;
  at_time := clock_timestamp();
  IF EXISTS(SELECT 1 FROM safeathome_private.closed_accounts WHERE owner_hash=encode(sha256(convert_to(actor,'UTF8')),'hex')) THEN
    RETURN jsonb_build_object('status','not_found'); END IF;
  IF action='list-shared-cases' THEN
    SELECT COALESCE(jsonb_agg((to_jsonb(s)-'projection'-'notes'-'audit'-'invitation_hash'-'creation_key') ORDER BY membership_id),'[]'::jsonb) INTO result
      FROM safeathome_private.case_shares s WHERE recipient_id=actor AND accepted AND NOT revoked
      AND projection IS NOT NULL AND (expires_at IS NULL OR expires_at>at_time);
    RETURN jsonb_build_object('status','ok','rows',result);
  END IF;
  IF action IN ('review-invitation','accept-invitation') THEN
    SELECT * INTO item FROM safeathome_private.case_shares WHERE recipient_id=actor
      AND invitation_hash=args->>'tokenHash' AND NOT accepted AND NOT revoked FOR UPDATE;
    IF NOT FOUND OR item.invitation_expires_at<=clock_timestamp() THEN RETURN jsonb_build_object('status','not_found'); END IF;
  ELSIF action IN ('read-shared-case','add-shared-note') THEN
    SELECT * INTO item FROM safeathome_private.case_shares WHERE membership_id=args->>'membershipId'
      AND recipient_id=actor AND accepted AND NOT revoked AND projection IS NOT NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  ELSE RETURN jsonb_build_object('status','invalid_request'); END IF;
  IF (item.expires_at IS NOT NULL AND item.expires_at<=clock_timestamp()) OR
    EXISTS(SELECT 1 FROM safeathome_private.closed_accounts WHERE owner_hash=encode(sha256(convert_to(item.owner_id,'UTF8')),'hex')) THEN
    RETURN jsonb_build_object('status','not_found'); END IF;
  IF action<>'review-invitation' AND item.permission_revision<>(args->>'expectedPermissionRevision')::integer THEN
    RETURN jsonb_build_object('status','conflict'); END IF;
  IF action='accept-invitation' THEN
    UPDATE safeathome_private.case_shares SET accepted=true,invitation_hash=NULL,permission_revision=permission_revision+1,
      audit=safeathome_private.share_audit(audit,'accepted') WHERE membership_id=item.membership_id RETURNING * INTO item;
  ELSIF action='read-shared-case' THEN
    UPDATE safeathome_private.case_shares SET audit=safeathome_private.share_audit(audit,'read')
      WHERE membership_id=item.membership_id RETURNING * INTO item;
  ELSIF action='add-shared-note' THEN
    IF item.definition->>'role'<>'helper' OR item.definition->'scope'->>'allowHelperNotes'<>'true' THEN RETURN jsonb_build_object('status','not_found'); END IF;
    IF args->>'mutationId' IS NULL OR args->>'mutationId' !~ '^[0-9a-f-]{36}$' OR args->>'note' IS NULL
      OR length(args->>'note') NOT BETWEEN 1 AND 500 OR args->>'note'<>btrim(args->>'note')
      OR args->>'note' ~ '[[:cntrl:]]' THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
    SELECT value INTO prior FROM jsonb_array_elements(item.notes->'events') WHERE value->>'mutationId'=args->>'mutationId';
    IF prior IS NOT NULL THEN
      IF prior->>'note'<>args->>'note' OR prior->>'authorId'<>actor THEN RETURN jsonb_build_object('status','conflict'); END IF;
    ELSE
      IF jsonb_array_length(item.notes->'events')>=50 THEN RETURN jsonb_build_object('status','quota_exceeded'); END IF;
      UPDATE safeathome_private.case_shares SET notes=jsonb_build_object('events',notes->'events'||jsonb_build_array(
        jsonb_build_object('mutationId',args->>'mutationId','authorId',actor,'note',args->>'note',
          'recordedAt',to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')))),
        audit=safeathome_private.share_audit(audit,'note') WHERE membership_id=item.membership_id RETURNING * INTO item;
    END IF;
  END IF;
  RETURN jsonb_build_object('status','ok','row',to_jsonb(item));
END $$;
REVOKE ALL ON FUNCTION safeathome_private.shared_operation(text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.shared_operation(text,jsonb) TO safeathome_app;

-- A saved projection never silently follows new owner data. Any case or photo
-- revision change marks it stale until its owner explicitly republishes.
CREATE FUNCTION safeathome_private.stale_shared_projection() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  UPDATE safeathome_private.case_shares SET projection=jsonb_set(projection,'{stale}','true')
    WHERE case_id=NEW.case_id AND projection IS NOT NULL;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION safeathome_private.stale_shared_projection() FROM PUBLIC;
CREATE TRIGGER stale_shared_projection AFTER UPDATE OF revision,catalog_revision,progress ON safeathome_private.cases
  FOR EACH ROW EXECUTE FUNCTION safeathome_private.stale_shared_projection();

CREATE FUNCTION safeathome_private.stale_shared_history() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  UPDATE safeathome_private.case_shares SET projection=jsonb_set(projection,'{stale}','true')
    WHERE case_id=NEW.case_id AND projection IS NOT NULL;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION safeathome_private.stale_shared_history() FROM PUBLIC;
CREATE TRIGGER stale_shared_history AFTER INSERT OR UPDATE ON safeathome_private.request_history
  FOR EACH ROW EXECUTE FUNCTION safeathome_private.stale_shared_history();

-- Recipient closure erases only that account's grants, never another owner's case.
CREATE FUNCTION safeathome_private.erase_recipient_shares() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  DELETE FROM safeathome_private.case_shares WHERE encode(sha256(convert_to(recipient_id,'UTF8')),'hex')=NEW.owner_hash;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION safeathome_private.erase_recipient_shares() FROM PUBLIC;
CREATE TRIGGER erase_recipient_shares AFTER INSERT ON safeathome_private.closed_accounts
  FOR EACH ROW EXECUTE FUNCTION safeathome_private.erase_recipient_shares();

-- Expiry is checked on every operation, independently of maintenance. Retain a
-- compact retry/revocation receipt; discard expired published text and notes.
ALTER FUNCTION safeathome_private.sweep_retention() RENAME TO sweep_retention_before_sharing;
CREATE FUNCTION safeathome_private.sweep_retention()
RETURNS TABLE(expired_exports bigint,released_bytes bigint,expired_previews bigint,expired_receipts bigint)
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RETURN QUERY SELECT * FROM safeathome_private.sweep_retention_before_sharing();
  UPDATE safeathome_private.case_shares SET invitation_hash=NULL,projection=NULL,notes='{"events":[]}'
    WHERE (expires_at<=clock_timestamp() OR (NOT accepted AND invitation_expires_at<=clock_timestamp()))
      AND (projection IS NOT NULL OR invitation_hash IS NOT NULL);
END $$;
REVOKE ALL ON FUNCTION safeathome_private.sweep_retention() FROM PUBLIC;
