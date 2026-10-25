-- Additive email-bound invitations. Pending recipient IDs are random invitation
-- UUIDs, not accounts. Only the verified mailbox can replace that placeholder.
ALTER TABLE safeathome_private.case_shares ADD COLUMN invited_email text
  CHECK(invited_email IS NULL OR length(invited_email) BETWEEN 3 AND 254);
ALTER TABLE safeathome_private.case_shares ADD COLUMN recipient_email_hash text
  CHECK (recipient_email_hash IS NULL OR (recipient_email_hash ~ '^[a-f0-9]{64}$' AND NOT accepted AND NOT revoked));

CREATE FUNCTION safeathome_private.clear_invitation_email() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF NEW.accepted OR NEW.revoked THEN NEW.recipient_email_hash:=NULL; END IF;
  IF NEW.revoked THEN NEW.invited_email:=NULL; END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION safeathome_private.clear_invitation_email() FROM PUBLIC;
CREATE TRIGGER clear_invitation_email BEFORE UPDATE ON safeathome_private.case_shares
  FOR EACH ROW EXECUTE FUNCTION safeathome_private.clear_invitation_email();

-- An email invitation must never fall through the old UUID-only redemption,
-- even if a caller happens to have the placeholder UUID as their account ID.
ALTER FUNCTION safeathome_private.shared_operation(text,jsonb) RENAME TO shared_operation_uuid;
REVOKE ALL ON FUNCTION safeathome_private.shared_operation_uuid(text,jsonb) FROM safeathome_app;
CREATE FUNCTION safeathome_private.shared_operation(action text,args jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF action IN ('review-invitation','accept-invitation') AND EXISTS(
    SELECT 1 FROM safeathome_private.case_shares WHERE invitation_hash=args->>'tokenHash' AND recipient_email_hash IS NOT NULL)
    THEN RETURN jsonb_build_object('status','not_found'); END IF;
  RETURN safeathome_private.shared_operation_uuid(action,args);
END $$;
REVOKE ALL ON FUNCTION safeathome_private.shared_operation(text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.shared_operation(text,jsonb) TO safeathome_app;

-- The mailbox hash is trusted provider context supplied by the HTTP adapter,
-- never a request field. This function never exposes case content or the hash.
CREATE FUNCTION safeathome_private.email_invitation_operation(action text, args jsonb, mailbox_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor text:=current_setting('safeathome.user_id',true); item safeathome_private.case_shares;
  at_time timestamptz;
BEGIN
  IF actor IS NULL OR actor='' OR mailbox_hash IS NULL OR mailbox_hash !~ '^[a-f0-9]{64}$'
    OR action NOT IN ('review-invitation','accept-invitation')
    THEN RETURN jsonb_build_object('status','not_found'); END IF;
  PERFORM 1 FROM safeathome_private.repository_quota WHERE singleton FOR UPDATE;
  SELECT * INTO item FROM safeathome_private.case_shares WHERE invitation_hash=args->>'tokenHash'
    AND recipient_email_hash=mailbox_hash AND NOT accepted AND NOT revoked;
  IF NOT FOUND OR actor=item.owner_id THEN RETURN jsonb_build_object('status','not_found'); END IF;
  PERFORM 1 FROM safeathome_private.cases WHERE case_id=item.case_id AND owner_id=item.owner_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT * INTO item FROM safeathome_private.case_shares WHERE membership_id=item.membership_id FOR UPDATE;
  at_time:=clock_timestamp();
  IF item.accepted OR item.revoked OR item.invitation_hash IS DISTINCT FROM args->>'tokenHash'
    OR item.recipient_email_hash IS DISTINCT FROM mailbox_hash OR item.projection IS NULL
    OR item.invitation_expires_at<=at_time OR item.expires_at<=at_time
    OR EXISTS(SELECT 1 FROM safeathome_private.closed_accounts WHERE owner_hash IN
      (encode(sha256(convert_to(actor,'UTF8')),'hex'),encode(sha256(convert_to(item.owner_id,'UTF8')),'hex')))
    THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF action='accept-invitation' THEN
    IF item.permission_revision<>(args->>'expectedPermissionRevision')::integer
      THEN RETURN jsonb_build_object('status','conflict'); END IF;
    IF item.permission_revision>=1000 OR NOT safeathome_private.share_recipient_has_capacity(actor)
      THEN RETURN jsonb_build_object('status','quota_exceeded'); END IF;
    UPDATE safeathome_private.case_shares SET recipient_id=actor,accepted=true,invitation_hash=NULL,recipient_email_hash=NULL,
      permission_revision=permission_revision+1,audit=safeathome_private.share_audit(audit,'accepted')
      WHERE membership_id=item.membership_id RETURNING * INTO item;
  ELSE item.recipient_id:=actor; END IF;
  RETURN jsonb_build_object('status','ok','row',jsonb_build_object('membership_id',item.membership_id,
    'case_id',item.case_id,'owner_id',item.owner_id,'recipient_id',item.recipient_id,'definition',item.definition,
    'permission_revision',item.permission_revision,'expires_at',item.expires_at,'invitation_expires_at',item.invitation_expires_at,
    'accepted',item.accepted,'revoked',item.revoked));
END $$;
REVOKE ALL ON FUNCTION safeathome_private.email_invitation_operation(text,jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.email_invitation_operation(text,jsonb,text) TO safeathome_app;
