-- Privacy lifecycle. Never run as the HTTP runtime role.
CREATE TABLE safeathome_private.deleted_cases (
  case_hash text PRIMARY KEY CHECK (case_hash ~ '^[a-f0-9]{64}$'),
  owner_hash text NOT NULL CHECK (owner_hash ~ '^[a-f0-9]{64}$'),
  revision bigint NOT NULL CHECK (revision BETWEEN 1 AND 9007199254740991),
  catalog_revision bigint NOT NULL CHECK (catalog_revision BETWEEN 0 AND 9007199254740991)
);
CREATE TABLE safeathome_private.closed_accounts (
  owner_hash text PRIMARY KEY CHECK (owner_hash ~ '^[a-f0-9]{64}$'),
  closed_at timestamptz NOT NULL,
  receipt_hash text UNIQUE CHECK (receipt_hash ~ '^[a-f0-9]{64}$'),
  receipt_expires_at timestamptz NOT NULL,
  auth_deleted_at timestamptz
);
CREATE TABLE safeathome_private.account_deletion_previews (
  owner_hash text PRIMARY KEY CHECK (owner_hash ~ '^[a-f0-9]{64}$'),
  token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[a-f0-9]{64}$'),
  fingerprint text NOT NULL CHECK (fingerprint ~ '^[a-f0-9]{64}$'),
  expires_at timestamptz NOT NULL
);
CREATE TABLE safeathome_private.auth_deletion_jobs (
  job_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_hash text NOT NULL UNIQUE REFERENCES safeathome_private.closed_accounts(owner_hash),
  raw_user_id text,
  completed_at timestamptz,
  next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_token uuid,
  lease_until timestamptz,
  CHECK ((completed_at IS NULL AND raw_user_id IS NOT NULL) OR
    (completed_at IS NOT NULL AND raw_user_id IS NULL)),
  -- The privileged Auth worker must never trust a runtime-provided target that
  -- differs from the owner authorized by RLS and the closed-account foreign key.
  CHECK (raw_user_id IS NULL OR owner_hash=encode(sha256(convert_to(raw_user_id, 'UTF8')), 'hex')),
  CHECK ((lease_token IS NULL) = (lease_until IS NULL))
);

DO $$
DECLARE name text;
BEGIN
  FOREACH name IN ARRAY ARRAY['deleted_cases','closed_accounts','account_deletion_previews','auth_deletion_jobs'] LOOP
    EXECUTE format('ALTER TABLE safeathome_private.%I ENABLE ROW LEVEL SECURITY', name);
    EXECUTE format('ALTER TABLE safeathome_private.%I FORCE ROW LEVEL SECURITY', name);
    EXECUTE format('CREATE POLICY own_lifecycle ON safeathome_private.%I TO safeathome_app
      USING (owner_hash = encode(sha256(convert_to(current_setting(''safeathome.user_id'', true), ''UTF8'')), ''hex''))
      WITH CHECK (owner_hash = encode(sha256(convert_to(current_setting(''safeathome.user_id'', true), ''UTF8'')), ''hex''))', name);
  END LOOP;
  -- The fixed maintenance functions run only for this migration owner. FORCE
  -- RLS also supports a non-superuser migration owner; runtime cannot inherit it.
  FOREACH name IN ARRAY ARRAY['repository_quota','cases','matches','packets','form_answers','evidence','exports',
    'deleted_cases','closed_accounts','account_deletion_previews','auth_deletion_jobs'] LOOP
    EXECUTE format('CREATE POLICY lifecycle_operator ON safeathome_private.%I TO %I USING (true) WITH CHECK (true)', name, current_user);
  END LOOP;
END $$;

-- A receipt is a random 256-bit capability, supplied as a hash for one local
-- transaction. It reveals status only through the repository's fixed query.
CREATE POLICY receipt_lookup ON safeathome_private.closed_accounts FOR SELECT TO safeathome_app
  USING (receipt_hash = current_setting('safeathome.receipt_hash', true)
    AND receipt_expires_at > clock_timestamp());
CREATE POLICY receipt_preview ON safeathome_private.account_deletion_previews FOR SELECT TO safeathome_app
  USING (token_hash = current_setting('safeathome.receipt_hash', true)
    AND expires_at > clock_timestamp());
ALTER POLICY case_owner ON safeathome_private.cases WITH CHECK (
  owner_id = current_setting('safeathome.user_id', true)
  AND NOT EXISTS (SELECT 1 FROM safeathome_private.closed_accounts
    WHERE owner_hash=encode(sha256(convert_to(owner_id, 'UTF8')), 'hex'))
);
REVOKE ALL ON safeathome_private.deleted_cases, safeathome_private.closed_accounts,
  safeathome_private.account_deletion_previews, safeathome_private.auth_deletion_jobs FROM PUBLIC;
GRANT SELECT, INSERT ON safeathome_private.deleted_cases TO safeathome_app;
GRANT SELECT ON safeathome_private.closed_accounts TO safeathome_app;
GRANT INSERT(owner_hash,closed_at,receipt_hash,receipt_expires_at) ON safeathome_private.closed_accounts TO safeathome_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON safeathome_private.account_deletion_previews TO safeathome_app;
GRANT INSERT(owner_hash,raw_user_id) ON safeathome_private.auth_deletion_jobs TO safeathome_app;
GRANT DELETE ON safeathome_private.cases, safeathome_private.packets,
  safeathome_private.form_answers, safeathome_private.evidence, safeathome_private.exports TO safeathome_app;

-- This fixed boolean lookup blocks globally retired IDs without granting a
-- runtime connection visibility of another owner's deletion receipt.
CREATE FUNCTION safeathome_private.case_id_was_deleted(value text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT EXISTS (SELECT 1 FROM safeathome_private.deleted_cases WHERE case_hash = value)
$$;
REVOKE ALL ON FUNCTION safeathome_private.case_id_was_deleted(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.case_id_was_deleted(text) TO safeathome_app;

-- A compact expired row keeps only the original IDs/key and expiry marker.
-- Its key can never silently become a new generation request.
ALTER TABLE safeathome_private.exports ALTER COLUMN metadata DROP NOT NULL;
ALTER TABLE safeathome_private.exports ALTER COLUMN bindings DROP NOT NULL;
ALTER TABLE safeathome_private.exports ADD COLUMN expires_at timestamptz;
UPDATE safeathome_private.exports SET expires_at = (metadata->>'expiresAt')::timestamptz;
ALTER TABLE safeathome_private.exports ALTER COLUMN expires_at SET NOT NULL;
ALTER TABLE safeathome_private.exports DROP CONSTRAINT exports_check;
ALTER TABLE safeathome_private.exports ADD CONSTRAINT exports_live_payload CHECK (
  (invalidated AND bytes IS NULL) OR
  (NOT invalidated AND metadata IS NOT NULL AND bindings IS NOT NULL AND bytes IS NOT NULL
    AND octet_length(bytes) BETWEEN 8 AND 33554432
    AND (metadata->>'byteLength')::numeric = octet_length(bytes))
);
ALTER TABLE safeathome_private.exports ADD CONSTRAINT exports_compacted_payload CHECK (
  (metadata IS NULL) = (bindings IS NULL)
);
ALTER TABLE safeathome_private.exports ADD CONSTRAINT exports_expiry_matches_metadata CHECK (
  metadata IS NULL OR expires_at = (metadata->>'expiresAt')::timestamptz
);
-- artifact_count now counts live binary payloads, not permanent retry receipts.
UPDATE safeathome_private.repository_quota SET artifact_count =
  (SELECT count(*) FROM safeathome_private.exports WHERE bytes IS NOT NULL);

CREATE FUNCTION safeathome_private.sweep_retention()
RETURNS TABLE(expired_exports bigint, released_bytes bigint, expired_previews bigint, expired_receipts bigint)
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE at_time timestamptz; freed bigint; active bigint;
BEGIN
  PERFORM 1 FROM safeathome_private.repository_quota WHERE singleton FOR UPDATE;
  at_time := clock_timestamp();
  SELECT count(*), COALESCE(sum(octet_length(bytes)),0), count(bytes)
    INTO expired_exports, freed, active FROM safeathome_private.exports
    WHERE (invalidated OR expires_at <= at_time) AND metadata IS NOT NULL;
  UPDATE safeathome_private.exports SET bytes=NULL, metadata=NULL, bindings=NULL,
    invalidated=true WHERE (invalidated OR expires_at <= at_time) AND metadata IS NOT NULL;
  UPDATE safeathome_private.repository_quota SET artifact_count=artifact_count-active,
    stored_bytes=stored_bytes-freed WHERE singleton;
  released_bytes := freed;
  -- Null freshness is never reusable. Keep its key/id but discard private text.
  UPDATE safeathome_private.packets SET packet=NULL WHERE packet IS NOT NULL AND
    (packet->>'recheckAfter' IS NULL OR (packet->>'recheckAfter')::timestamptz <= at_time);
  DELETE FROM safeathome_private.account_deletion_previews WHERE expires_at <= at_time;
  GET DIAGNOSTICS expired_previews = ROW_COUNT;
  UPDATE safeathome_private.closed_accounts SET receipt_hash=NULL
    WHERE receipt_hash IS NOT NULL AND receipt_expires_at <= at_time;
  GET DIAGNOSTICS expired_receipts = ROW_COUNT;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION safeathome_private.sweep_retention() FROM PUBLIC;

CREATE FUNCTION safeathome_private.claim_auth_deletion_jobs(batch_limit integer)
RETURNS TABLE(job_id uuid, user_id text, lease_token uuid)
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE item record;
BEGIN
  IF batch_limit < 1 OR batch_limit > 10 OR batch_limit IS NULL THEN RAISE EXCEPTION 'Invalid batch size'; END IF;
  PERFORM 1 FROM safeathome_private.repository_quota WHERE singleton FOR UPDATE;
  FOR item IN SELECT j.job_id, j.raw_user_id FROM safeathome_private.auth_deletion_jobs j
    WHERE j.completed_at IS NULL AND j.next_attempt_at <= clock_timestamp()
      AND (j.lease_until IS NULL OR j.lease_until <= clock_timestamp())
    ORDER BY j.job_id LIMIT batch_limit FOR UPDATE SKIP LOCKED LOOP
    job_id := item.job_id; user_id := item.raw_user_id; lease_token := gen_random_uuid();
    UPDATE safeathome_private.auth_deletion_jobs j SET lease_token=claim_auth_deletion_jobs.lease_token,
      lease_until=clock_timestamp()+interval '120 seconds' WHERE j.job_id=item.job_id;
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION safeathome_private.claim_auth_deletion_jobs(integer) FROM PUBLIC;

CREATE FUNCTION safeathome_private.finish_auth_deletion_job(id uuid, lease uuid, deleted boolean)
RETURNS boolean LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE owner text;
BEGIN
  PERFORM 1 FROM safeathome_private.repository_quota WHERE singleton FOR UPDATE;
  SELECT owner_hash INTO owner FROM safeathome_private.auth_deletion_jobs
    WHERE job_id=id AND lease_token=lease AND lease_until>clock_timestamp() AND completed_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  IF deleted THEN
    UPDATE safeathome_private.auth_deletion_jobs SET raw_user_id=NULL, completed_at=clock_timestamp(),
      lease_token=NULL, lease_until=NULL WHERE job_id=id;
    UPDATE safeathome_private.closed_accounts SET auth_deleted_at=clock_timestamp() WHERE owner_hash=owner;
  ELSE
    UPDATE safeathome_private.auth_deletion_jobs SET lease_token=NULL, lease_until=NULL,
      next_attempt_at=clock_timestamp()+interval '5 minutes' WHERE job_id=id;
  END IF;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION safeathome_private.finish_auth_deletion_job(uuid,uuid,boolean) FROM PUBLIC;

CREATE FUNCTION safeathome_private.pending_auth_deletion_count() RETURNS bigint
  LANGUAGE sql SET search_path = pg_catalog AS $$
  SELECT count(*) FROM safeathome_private.auth_deletion_jobs WHERE completed_at IS NULL
$$;
REVOKE ALL ON FUNCTION safeathome_private.pending_auth_deletion_count() FROM PUBLIC;
