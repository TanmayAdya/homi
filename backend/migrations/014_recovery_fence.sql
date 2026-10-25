-- Control state is deployment metadata, outside portable application archives.
-- Restoring application data must never restore permission to serve it.
CREATE SCHEMA safeathome_recovery;
REVOKE ALL ON SCHEMA safeathome_recovery FROM PUBLIC;
CREATE TABLE safeathome_recovery.control (
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  database_id uuid NOT NULL DEFAULT gen_random_uuid(),
  generation uuid NOT NULL DEFAULT gen_random_uuid(),
  state text NOT NULL DEFAULT 'open' CHECK(state IN ('open','frozen','quarantine','retired')),
  staged jsonb,
  checkpoint_hash text CHECK(checkpoint_hash IS NULL OR checkpoint_hash ~ '^[a-f0-9]{64}$'),
  promoted_target uuid,
  CHECK(staged IS NULL OR jsonb_typeof(staged)='object')
);
INSERT INTO safeathome_recovery.control(singleton) VALUES(true);
REVOKE ALL ON safeathome_recovery.control FROM PUBLIC, safeathome_app;
GRANT USAGE ON SCHEMA safeathome_recovery TO safeathome_app;
CREATE FUNCTION safeathome_recovery.is_open() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT COALESCE((SELECT state='open' FROM safeathome_recovery.control WHERE singleton),false)
$$;
REVOKE ALL ON FUNCTION safeathome_recovery.is_open() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_recovery.is_open() TO safeathome_app;

-- SESSION_USER remains the login even inside helper SECURITY DEFINER calls.
-- This also closes cached SQL plans; schema-USAGE revocation alone is not a
-- sufficient data fence for a connection that prepared queries beforehand.
CREATE FUNCTION safeathome_recovery.operator_or_open() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT state='open' OR pg_has_role(session_user,c.relowner,'USAGE')
  FROM safeathome_recovery.control x,pg_class c
  WHERE x.singleton AND c.oid='safeathome_recovery.control'::regclass
$$;
REVOKE ALL ON FUNCTION safeathome_recovery.operator_or_open() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_recovery.operator_or_open() TO safeathome_app;

-- Every application mutation changes the checkpoint generation, including
-- independent annotations, sharing, binary replacements and worker completions.
-- Global quota -> control lock order also serializes freeze with pending writers.
CREATE FUNCTION safeathome_recovery.guard_mutation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE mode text; operator boolean;
BEGIN
  PERFORM 1 FROM safeathome_private.repository_quota WHERE singleton FOR UPDATE;
  SELECT state INTO mode FROM safeathome_recovery.control WHERE singleton FOR UPDATE;
  SELECT pg_has_role(session_user,c.relowner,'USAGE') INTO operator
    FROM pg_class c WHERE c.oid='safeathome_recovery.control'::regclass;
  IF mode IS NULL OR mode IN ('frozen','retired') OR (mode='quarantine' AND NOT operator)
    THEN RAISE EXCEPTION 'Repository is unavailable for maintenance' USING ERRCODE='55000'; END IF;
  UPDATE safeathome_recovery.control SET generation=gen_random_uuid(),staged=NULL,checkpoint_hash=NULL WHERE singleton;
  RETURN NULL;
END $$;

-- Definer functions can be owned by a BYPASSRLS operator. Fence their public
-- entry points too; relying on table policies alone would leave read-only
-- invitation reviews or private-data reads open in that configuration.
ALTER FUNCTION safeathome_private.shared_operation(text,jsonb) RENAME TO shared_operation_pre_recovery;
REVOKE ALL ON FUNCTION safeathome_private.shared_operation_pre_recovery(text,jsonb) FROM safeathome_app;
CREATE FUNCTION safeathome_private.shared_operation(action text,args jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF NOT safeathome_recovery.operator_or_open() THEN RETURN jsonb_build_object('status','not_found'); END IF;
  RETURN safeathome_private.shared_operation_pre_recovery(action,args);
END $$;
REVOKE ALL ON FUNCTION safeathome_private.shared_operation(text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.shared_operation(text,jsonb) TO safeathome_app;

ALTER FUNCTION safeathome_private.email_invitation_operation(text,jsonb,text) RENAME TO email_invitation_pre_recovery;
REVOKE ALL ON FUNCTION safeathome_private.email_invitation_pre_recovery(text,jsonb,text) FROM safeathome_app;
CREATE FUNCTION safeathome_private.email_invitation_operation(action text,args jsonb,mailbox_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF NOT safeathome_recovery.operator_or_open() THEN RETURN jsonb_build_object('status','not_found'); END IF;
  RETURN safeathome_private.email_invitation_pre_recovery(action,args,mailbox_hash);
END $$;
REVOKE ALL ON FUNCTION safeathome_private.email_invitation_operation(text,jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.email_invitation_operation(text,jsonb,text) TO safeathome_app;

ALTER FUNCTION safeathome_private.collaboration_operation(text,jsonb,jsonb) RENAME TO collaboration_pre_recovery;
REVOKE ALL ON FUNCTION safeathome_private.collaboration_pre_recovery(text,jsonb,jsonb) FROM safeathome_app;
CREATE FUNCTION safeathome_private.collaboration_operation(action text,args jsonb,rules jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF NOT safeathome_recovery.operator_or_open() THEN RETURN jsonb_build_object('status','not_found'); END IF;
  RETURN safeathome_private.collaboration_pre_recovery(action,args,rules);
END $$;
REVOKE ALL ON FUNCTION safeathome_private.collaboration_operation(text,jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.collaboration_operation(text,jsonb,jsonb) TO safeathome_app;

ALTER FUNCTION safeathome_private.sensitive_operation(text,jsonb,jsonb) RENAME TO sensitive_pre_recovery;
REVOKE ALL ON FUNCTION safeathome_private.sensitive_pre_recovery(text,jsonb,jsonb) FROM safeathome_app;
CREATE FUNCTION safeathome_private.sensitive_operation(action text,args jsonb,categories jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF NOT safeathome_recovery.operator_or_open() THEN RETURN jsonb_build_object('status','not_found'); END IF;
  RETURN safeathome_private.sensitive_pre_recovery(action,args,categories);
END $$;
REVOKE ALL ON FUNCTION safeathome_private.sensitive_operation(text,jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.sensitive_operation(text,jsonb,jsonb) TO safeathome_app;
REVOKE ALL ON FUNCTION safeathome_recovery.guard_mutation() FROM PUBLIC, safeathome_app;
DO $$
DECLARE name text;
BEGIN
  FOR name IN SELECT tablename FROM pg_tables WHERE schemaname='safeathome_private' LOOP
    EXECUTE format('CREATE POLICY recovery_access ON safeathome_private.%I AS RESTRICTIVE TO PUBLIC
      USING(safeathome_recovery.operator_or_open()) WITH CHECK(safeathome_recovery.operator_or_open())',name);
    EXECUTE format('CREATE TRIGGER recovery_fence BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON safeathome_private.%I
      FOR EACH STATEMENT EXECUTE FUNCTION safeathome_recovery.guard_mutation()',name);
  END LOOP;
END $$;
