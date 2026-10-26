-- Forward-only extension. Canonical tasks/status remain in cases.progress.
-- The owner-only sidecar holds stable account assignments, proposals and receipts.
ALTER TABLE safeathome_private.cases ADD COLUMN collaboration jsonb;
ALTER TABLE safeathome_private.cases ADD CONSTRAINT collaboration_record CHECK (
  collaboration IS NULL OR (jsonb_typeof(collaboration)='object' AND collaboration->>'schemaVersion'='3'
    AND collaboration->>'caseId'=case_id AND (collaboration->>'revision')::integer BETWEEN 0 AND 256
    AND jsonb_array_length(collaboration->'events')=(collaboration->>'revision')::integer
    AND jsonb_array_length(collaboration->'assignments')<=128 AND jsonb_array_length(collaboration->'proposals')<=64
    AND octet_length(collaboration::text)<=196608) IS TRUE
);
ALTER TABLE safeathome_private.case_shares ADD COLUMN collaboration_scope jsonb NOT NULL
  DEFAULT '{"taskIds":[],"allowTaskProgress":false,"allowStatusProposals":false,"taskSnapshots":[]}';
ALTER TABLE safeathome_private.case_shares ADD CONSTRAINT collaboration_scope_record CHECK (
  jsonb_typeof(collaboration_scope)='object' AND jsonb_array_length(collaboration_scope->'taskIds')<=32
  AND jsonb_array_length(collaboration_scope->'taskSnapshots')=jsonb_array_length(collaboration_scope->'taskIds')
  AND jsonb_typeof(collaboration_scope->'allowTaskProgress')='boolean'
  AND jsonb_typeof(collaboration_scope->'allowStatusProposals')='boolean' AND octet_length(collaboration_scope::text)<=49152
);

CREATE FUNCTION safeathome_private.clear_collaboration_scope() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF NEW.revoked OR NEW.projection IS NULL OR OLD.definition->'scope' IS DISTINCT FROM NEW.definition->'scope'
    OR OLD.definition->>'role' IS DISTINCT FROM NEW.definition->>'role' THEN
    NEW.collaboration_scope := '{"taskIds":[],"allowTaskProgress":false,"allowStatusProposals":false,"taskSnapshots":[]}';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION safeathome_private.clear_collaboration_scope() FROM PUBLIC;
CREATE TRIGGER clear_collaboration_scope BEFORE UPDATE ON safeathome_private.case_shares
  FOR EACH ROW EXECUTE FUNCTION safeathome_private.clear_collaboration_scope();

-- Explicit DTO: imported referral notes, source events, form IDs and raw task
-- metadata never enter a collaborator projection. Names/labels require preview.
CREATE FUNCTION safeathome_private.public_shared_task(task jsonb, assignee text, stale boolean) RETURNS jsonb
LANGUAGE sql SET search_path=pg_catalog AS $$
  SELECT jsonb_build_object('id',task->'id','programId',task->'programId','findingId',task->'findingId',
    'title',task->'title','kind',task->'kind','state',task->'state','responsiblePerson',task->'responsiblePerson',
    'dueOn',task->'dueOn','revision',task->'revision','assigneeUserId',assignee,'needsReview',stale)
$$;
REVOKE ALL ON FUNCTION safeathome_private.public_shared_task(jsonb,text,boolean) FROM PUBLIC;

-- Canonical proposal fields are validated again at the privileged boundary.
CREATE FUNCTION safeathome_private.valid_shared_update(value jsonb) RETURNS boolean
LANGUAGE sql SET search_path=pg_catalog AS $$
 SELECT COALESCE(jsonb_typeof(value)='object' AND
   (SELECT count(*)=8 FROM jsonb_object_keys(value)) AND value ?& ARRAY['updateId','status','occurredOn','source','note','nextAction','responsibleParty','followUpOn']
   AND value->>'updateId' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
   AND value->>'status' IN ('preparing','submitted','received','needs_information','approved','denied','withdrawn')
   AND value->>'source' IN ('self_report','program_contact','document') AND value->>'occurredOn' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
   AND (value->'note'='null'::jsonb OR (jsonb_typeof(value->'note')='string' AND length(value->>'note') BETWEEN 1 AND 500 AND value->>'note'=btrim(value->>'note') AND value->>'note' !~ '[[:cntrl:]]'))
   AND (value->'nextAction'='null'::jsonb OR (jsonb_typeof(value->'nextAction')='string' AND length(value->>'nextAction') BETWEEN 1 AND 250 AND value->>'nextAction'=btrim(value->>'nextAction') AND value->>'nextAction' !~ '[[:cntrl:]]'))
   AND (value->>'responsibleParty' IS NULL OR value->>'responsibleParty' IN ('resident','caregiver','program','clinician','contractor','other'))
   AND ((value->>'nextAction' IS NULL)=(value->>'responsibleParty' IS NULL))
   AND (value->>'followUpOn' IS NULL OR value->>'nextAction' IS NOT NULL AND value->>'followUpOn' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),false)
$$;
REVOKE ALL ON FUNCTION safeathome_private.valid_shared_update(jsonb) FROM PUBLIC;

-- Audited narrow privilege boundary. The function has no arbitrary SQL, owner
-- impersonation or raw-case return. Lock order is quota -> case -> grant, shared
-- with revocation, closure and owner writes. Rules are trusted immutable server
-- configuration, never a JSON field supplied by an HTTP caller.
CREATE FUNCTION safeathome_private.collaboration_operation(action text,args jsonb,rules jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor text:=current_setting('safeathome.user_id',true); grant_row safeathome_private.case_shares;
  owner_case safeathome_private.cases; owner_mode boolean; work jsonb; task_record jsonb;
  prior jsonb; task jsonb; old_task jsonb; published jsonb; assignment jsonb; proposal jsonb;
  scope jsonb; snapshots jsonb; selected jsonb; operation jsonb; task_event jsonb; events jsonb;
  output_tasks jsonb:='[]'; output_proposals jsonb; output_scope jsonb; new_revision integer;
  timestamp_text text; kind text; stale boolean; acknowledged text:=NULL; changed_progress boolean:=false;
BEGIN
  IF actor IS NULL OR actor='' OR action NOT IN ('read-collaboration','configure-collaboration','update-shared-task','propose-shared-status','review-shared-status')
    OR jsonb_typeof(args)<>'object' OR args->>'membershipId' IS NULL OR args->>'expectedPermissionRevision' IS NULL
    THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
  PERFORM 1 FROM safeathome_private.repository_quota WHERE singleton FOR UPDATE;
  SELECT * INTO grant_row FROM safeathome_private.case_shares WHERE membership_id=args->>'membershipId';
  IF NOT FOUND OR actor NOT IN (grant_row.owner_id,grant_row.recipient_id) THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT * INTO owner_case FROM safeathome_private.cases WHERE case_id=grant_row.case_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT * INTO grant_row FROM safeathome_private.case_shares WHERE membership_id=args->>'membershipId' FOR UPDATE;
  owner_mode:=actor=grant_row.owner_id;
  IF EXISTS(SELECT 1 FROM safeathome_private.closed_accounts WHERE owner_hash IN
    (encode(sha256(convert_to(actor,'UTF8')),'hex'),encode(sha256(convert_to(grant_row.owner_id,'UTF8')),'hex'),encode(sha256(convert_to(grant_row.recipient_id,'UTF8')),'hex')))
    THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF (NOT owner_mode OR action NOT IN ('read-collaboration','review-shared-status')) AND
    (grant_row.revoked OR NOT grant_row.accepted OR grant_row.projection IS NULL OR grant_row.expires_at<=clock_timestamp())
    THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF (action IN ('configure-collaboration','review-shared-status') AND NOT owner_mode)
    OR (action IN ('update-shared-task','propose-shared-status') AND (owner_mode OR grant_row.definition->>'role'<>'helper'))
    THEN RETURN jsonb_build_object('status','not_found'); END IF;
  work:=COALESCE(owner_case.collaboration,jsonb_build_object('schemaVersion','3','caseId',owner_case.case_id,'revision',0,'assignments','[]'::jsonb,'proposals','[]'::jsonb,'events','[]'::jsonb));
  task_record:=COALESCE(owner_case.progress,jsonb_build_object('schemaVersion','3','caseId',owner_case.case_id,'revision',0,'programs','[]'::jsonb,'tasks','[]'::jsonb,'dismissedProposals','[]'::jsonb,'events','[]'::jsonb));
  scope:=grant_row.collaboration_scope;
  IF action<>'read-collaboration' THEN
    IF args->>'expectedCaseRevision' IS NULL OR args->>'expectedCaseRevision' !~ '^[1-9][0-9]{0,15}$'
      OR args->>'expectedCollaborationRevision' IS NULL OR args->>'expectedCollaborationRevision' !~ '^[0-9]{1,3}$'
      OR (action IN ('configure-collaboration','review-shared-status') AND (args->>'expectedProgressRevision' IS NULL OR args->>'expectedProgressRevision' !~ '^[0-9]{1,3}$'))
      THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
    IF args->>'mutationId' IS NULL OR args->>'mutationId' !~ '^[0-9a-f-]{36}$' OR args->>'requestHash' IS NULL OR args->>'requestHash' !~ '^[a-f0-9]{64}$'
      THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
    SELECT value INTO prior FROM jsonb_array_elements(work->'events') WHERE value->>'mutationId'=args->>'mutationId';
    IF prior IS NOT NULL THEN
      IF prior->>'requestHash'<>args->>'requestHash' OR prior->>'actorId'<>actor OR prior->>'membershipId'<>grant_row.membership_id
        THEN RETURN jsonb_build_object('status','conflict'); END IF;
      IF grant_row.permission_revision<>((args->>'expectedPermissionRevision')::integer + CASE WHEN action='configure-collaboration' THEN 1 ELSE 0 END)
        THEN RETURN jsonb_build_object('status','conflict'); END IF;
      acknowledged:=args->>'mutationId';
    END IF;
  END IF;
  IF acknowledged IS NULL AND grant_row.permission_revision<>(args->>'expectedPermissionRevision')::integer THEN RETURN jsonb_build_object('status','conflict'); END IF;
  IF action<>'read-collaboration' AND acknowledged IS NULL THEN
    IF owner_case.revision<>(args->>'expectedCaseRevision')::bigint OR (work->>'revision')::integer<>(args->>'expectedCollaborationRevision')::integer
      OR (args ? 'expectedProgressRevision' AND (task_record->>'revision')::integer<>(args->>'expectedProgressRevision')::integer)
      THEN RETURN jsonb_build_object('status','conflict'); END IF;
    IF jsonb_array_length(work->'events')>=256 THEN RETURN jsonb_build_object('status','quota_exceeded'); END IF;
    timestamp_text:=to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
    timestamp_text:=greatest(timestamp_text,COALESCE(work->'events'->-1->>'at',timestamp_text),COALESCE(task_record->'events'->-1->>'recordedAt',timestamp_text));
    IF action='configure-collaboration' THEN
      IF jsonb_typeof(args->'collaborationScope'->'taskIds')<>'array' OR jsonb_array_length(args->'collaborationScope'->'taskIds')>32
        OR jsonb_typeof(args->'assignedTaskIds')<>'array' OR jsonb_typeof(args->'collaborationScope'->'allowTaskProgress')<>'boolean'
        OR jsonb_typeof(args->'collaborationScope'->'allowStatusProposals')<>'boolean' THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
      IF grant_row.definition->>'role'<>'helper' AND (args->'collaborationScope'->>'allowTaskProgress'='true' OR args->'collaborationScope'->>'allowStatusProposals'='true'
        OR jsonb_array_length(args->'assignedTaskIds')<>0) THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
      IF jsonb_array_length(args->'assignedTaskIds')<>0 AND args->'collaborationScope'->>'allowTaskProgress'<>'true' THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
      snapshots:='[]';
      FOR selected IN SELECT value FROM jsonb_array_elements(args->'collaborationScope'->'taskIds') LOOP
        SELECT value INTO task FROM jsonb_array_elements(task_record->'tasks') WHERE value->'id'=selected;
        IF task IS NULL OR (task->>'programId' IS NOT NULL AND NOT grant_row.definition->'scope'->'programIds' ? (task->>'programId'))
          OR (task->>'findingId' IS NOT NULL AND NOT grant_row.definition->'scope'->'findingIds' ? (task->>'findingId'))
          THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
        snapshots:=snapshots||jsonb_build_array(jsonb_build_object('task',safeathome_private.public_shared_task(task,NULL,false)-'assigneeUserId'-'needsReview',
          'definitionHash',encode(sha256(convert_to((task-'state'-'revision')::text,'UTF8')),'hex')));
      END LOOP;
      FOR selected IN SELECT value FROM jsonb_array_elements(args->'assignedTaskIds') LOOP
        IF NOT args->'collaborationScope'->'taskIds' ? (selected#>>'{}') THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
      END LOOP;
      SELECT COALESCE(jsonb_agg(value),'[]') INTO assignment FROM jsonb_array_elements(work->'assignments')
        WHERE value->>'membershipId'<>grant_row.membership_id AND NOT args->'assignedTaskIds' ? (value->>'taskId');
      FOR selected IN SELECT value FROM jsonb_array_elements(args->'assignedTaskIds') LOOP
        assignment:=assignment||jsonb_build_array(jsonb_build_object('taskId',selected,'membershipId',grant_row.membership_id,'assigneeUserId',grant_row.recipient_id));
      END LOOP;
      work:=jsonb_set(work,'{assignments}',assignment);
      scope:=jsonb_build_object('taskIds',args->'collaborationScope'->'taskIds','allowTaskProgress',args->'collaborationScope'->'allowTaskProgress',
        'allowStatusProposals',args->'collaborationScope'->'allowStatusProposals','taskSnapshots',snapshots);
      IF grant_row.permission_revision>=998 THEN RETURN jsonb_build_object('status','quota_exceeded'); END IF;
    ELSIF action='update-shared-task' THEN
      IF args->>'expectedTaskRevision' IS NULL OR args->>'expectedTaskRevision' !~ '^[1-9][0-9]{0,3}$' OR args->>'state' IS NULL THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
      IF scope->>'allowTaskProgress'<>'true' OR NOT scope->'taskIds' ? (args->>'taskId') THEN RETURN jsonb_build_object('status','not_found'); END IF;
      SELECT value INTO assignment FROM jsonb_array_elements(work->'assignments') WHERE value->>'taskId'=args->>'taskId'
        AND value->>'membershipId'=grant_row.membership_id AND value->>'assigneeUserId'=actor;
      IF assignment IS NULL THEN RETURN jsonb_build_object('status','not_found'); END IF;
      SELECT value INTO old_task FROM jsonb_array_elements(task_record->'tasks') WHERE value->>'id'=args->>'taskId';
      SELECT value INTO published FROM jsonb_array_elements(scope->'taskSnapshots') WHERE value->'task'->>'id'=args->>'taskId';
      IF old_task IS NULL OR published IS NULL THEN RETURN jsonb_build_object('status','not_found'); END IF;
      IF (old_task->>'revision')::integer<>(args->>'expectedTaskRevision')::integer
        OR published->>'definitionHash'<>encode(sha256(convert_to((old_task-'state'-'revision')::text,'UTF8')),'hex')
        OR (old_task->>'basedOnCaseRevision')::bigint<>owner_case.revision
        OR old_task->>'basedOnRuleVersion' IS DISTINCT FROM rules->>(old_task->>'programId')
        THEN RETURN jsonb_build_object('status','conflict'); END IF;
      IF args->>'state' NOT IN ('pending','in_progress','blocked','completed','cancelled') THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
      task:=jsonb_set(jsonb_set(old_task,'{state}',args->'state'),'{revision}',to_jsonb((old_task->>'revision')::integer+1));
      SELECT jsonb_agg(CASE WHEN value->>'id'=task->>'id' THEN task ELSE value END ORDER BY ord) INTO selected
        FROM jsonb_array_elements(task_record->'tasks') WITH ORDINALITY t(value,ord);
      task_record:=jsonb_set(task_record,'{tasks}',selected);
      operation:=jsonb_build_object('type','put_task','task',task,'expectedTaskRevision',(old_task->>'revision')::integer);
      changed_progress:=true;
    ELSIF action='propose-shared-status' THEN
      IF scope->>'allowStatusProposals'<>'true' OR NOT grant_row.definition->'scope'->'programIds' ? (args->>'programId')
        THEN RETURN jsonb_build_object('status','not_found'); END IF;
      IF jsonb_array_length(work->'proposals')>=64 THEN RETURN jsonb_build_object('status','quota_exceeded'); END IF;
      IF NOT safeathome_private.valid_shared_update(args->'update') THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
      IF args->'update'->>'status' NOT IN ('preparing','submitted','received','needs_information','approved','denied','withdrawn')
        OR args->'update'->>'occurredOn'>substring(timestamp_text,1,10) OR args->'update'->>'updateId' IS NULL
        THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
      proposal:=jsonb_build_object('id',args->>'mutationId','membershipId',grant_row.membership_id,'permissionRevision',grant_row.permission_revision,
        'caseRevision',owner_case.revision,'programId',args->>'programId','update',args->'update','proposedBy',actor,'proposedAt',timestamp_text,
        'state','pending','reviewedBy',NULL,'reviewedAt',NULL);
      work:=jsonb_set(work,'{proposals}',work->'proposals'||jsonb_build_array(proposal));
    ELSIF action='review-shared-status' THEN
      SELECT value INTO proposal FROM jsonb_array_elements(work->'proposals') WHERE value->>'id'=args->>'proposalId' AND value->>'membershipId'=grant_row.membership_id;
      IF proposal IS NULL THEN RETURN jsonb_build_object('status','not_found'); END IF;
      IF proposal->>'state'<>'pending' THEN RETURN jsonb_build_object('status','conflict'); END IF;
      IF args->>'decision' NOT IN ('accepted','rejected') THEN RETURN jsonb_build_object('status','invalid_request'); END IF;
      IF args->>'decision'='accepted' THEN
        IF grant_row.revoked OR NOT grant_row.accepted OR grant_row.expires_at<=clock_timestamp()
          OR grant_row.definition->>'role'<>'helper' OR scope->>'allowStatusProposals'<>'true'
          OR NOT grant_row.definition->'scope'->'programIds' ? (proposal->>'programId')
          OR grant_row.permission_revision<>(proposal->>'permissionRevision')::integer
          OR owner_case.revision<>(proposal->>'caseRevision')::bigint THEN RETURN jsonb_build_object('status','conflict'); END IF;
        IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(task_record->'programs') WHERE value->>'programId'=proposal->>'programId')
          AND NOT EXISTS(SELECT 1 FROM safeathome_private.request_history WHERE case_id=owner_case.case_id AND program_id=proposal->>'programId')
          THEN RETURN jsonb_build_object('status','not_found'); END IF;
        IF EXISTS(SELECT 1 FROM jsonb_array_elements(task_record->'events') WHERE value->'operation'->>'type'='report_status'
          AND value->'operation'->'update'->>'updateId'=proposal->'update'->>'updateId')
          OR EXISTS(SELECT 1 FROM safeathome_private.request_history h, jsonb_array_elements(h.record->'events') e WHERE h.case_id=owner_case.case_id
            AND e->>'updateId'=proposal->'update'->>'updateId') THEN RETURN jsonb_build_object('status','conflict'); END IF;
        operation:=jsonb_build_object('type','report_status','programId',proposal->>'programId','update',proposal->'update');
        changed_progress:=true;
      END IF;
      proposal:=proposal||jsonb_build_object('state',args->>'decision','reviewedBy',actor,'reviewedAt',timestamp_text);
      SELECT jsonb_agg(CASE WHEN value->>'id'=proposal->>'id' THEN proposal ELSE value END ORDER BY ord) INTO selected
        FROM jsonb_array_elements(work->'proposals') WITH ORDINALITY p(value,ord);
      work:=jsonb_set(work,'{proposals}',selected);
    END IF;
    IF changed_progress THEN
      IF jsonb_array_length(task_record->'events')>=500 THEN RETURN jsonb_build_object('status','quota_exceeded'); END IF;
      IF EXISTS(SELECT 1 FROM jsonb_array_elements(task_record->'events') WHERE value->>'mutationId'=args->>'mutationId') THEN RETURN jsonb_build_object('status','conflict'); END IF;
      new_revision:=(task_record->>'revision')::integer+1;
      task_event:=jsonb_build_object('mutationId',args->>'mutationId','requestHash',args->>'requestHash','revision',new_revision,
        'recordedAt',timestamp_text,'recordedBy',actor,'caseRevision',owner_case.revision,'operation',operation);
      task_record:=jsonb_set(jsonb_set(task_record,'{revision}',to_jsonb(new_revision)),'{events}',task_record->'events'||jsonb_build_array(task_event));
      IF octet_length(task_record::text)>245760 THEN RETURN jsonb_build_object('status','quota_exceeded'); END IF;
    END IF;
    new_revision:=(work->>'revision')::integer+1;
    events:=work->'events'||jsonb_build_array(jsonb_build_object('revision',new_revision,'mutationId',args->>'mutationId','requestHash',args->>'requestHash',
      'type',action,'actorId',actor,'membershipId',grant_row.membership_id,'at',timestamp_text));
    work:=jsonb_set(jsonb_set(work,'{revision}',to_jsonb(new_revision)),'{events}',events);
    IF octet_length(work::text)>196608 OR octet_length(scope::text)>49152 THEN RETURN jsonb_build_object('status','quota_exceeded'); END IF;
    -- No changes occur before every validation/limit check has passed.
    UPDATE safeathome_private.cases SET collaboration=work WHERE case_id=owner_case.case_id;
    IF changed_progress THEN UPDATE safeathome_private.cases SET progress=task_record WHERE case_id=owner_case.case_id; END IF;
    IF action='configure-collaboration' THEN
      UPDATE safeathome_private.case_shares SET collaboration_scope=scope,permission_revision=permission_revision+1,
        audit=safeathome_private.share_audit(audit,'changed') WHERE membership_id=grant_row.membership_id RETURNING * INTO grant_row;
    ELSE
      UPDATE safeathome_private.case_shares SET audit=safeathome_private.share_audit(audit,CASE WHEN action='review-shared-status' THEN 'changed' ELSE 'note' END)
        WHERE membership_id=grant_row.membership_id RETURNING * INTO grant_row;
    END IF;
    acknowledged:=args->>'mutationId';
  END IF;
  IF action='read-collaboration' THEN
    UPDATE safeathome_private.case_shares SET audit=safeathome_private.share_audit(audit,'read')
      WHERE membership_id=grant_row.membership_id;
  END IF;
  IF owner_mode THEN
    FOR task IN SELECT value FROM jsonb_array_elements(task_record->'tasks') LOOP
      SELECT value INTO assignment FROM jsonb_array_elements(work->'assignments') WHERE value->>'taskId'=task->>'id';
      output_tasks:=output_tasks||jsonb_build_array(safeathome_private.public_shared_task(task,assignment->>'assigneeUserId',
        (task->>'basedOnCaseRevision')::bigint<>owner_case.revision OR task->>'basedOnRuleVersion' IS DISTINCT FROM rules->>(task->>'programId')));
    END LOOP;
  ELSE
    FOR published IN SELECT value FROM jsonb_array_elements(scope->'taskSnapshots') LOOP
      SELECT value INTO task FROM jsonb_array_elements(task_record->'tasks') WHERE value->>'id'=published->'task'->>'id';
      IF (published->'task'->>'programId' IS NOT NULL AND NOT grant_row.definition->'scope'->'programIds' ? (published->'task'->>'programId'))
        OR (published->'task'->>'findingId' IS NOT NULL AND NOT grant_row.definition->'scope'->'findingIds' ? (published->'task'->>'findingId')) THEN CONTINUE; END IF;
      stale:=task IS NULL OR published->>'definitionHash'<>encode(sha256(convert_to((task-'state'-'revision')::text,'UTF8')),'hex')
        OR (task->>'basedOnCaseRevision')::bigint<>owner_case.revision OR task->>'basedOnRuleVersion' IS DISTINCT FROM rules->>(task->>'programId');
      SELECT value INTO assignment FROM jsonb_array_elements(work->'assignments') WHERE value->>'taskId'=published->'task'->>'id';
      selected:=published->'task';
      IF NOT stale THEN selected:=selected||jsonb_build_object('state',task->'state','revision',task->'revision'); END IF;
      output_tasks:=output_tasks||jsonb_build_array(selected||jsonb_build_object('assigneeUserId',assignment->>'assigneeUserId','needsReview',stale));
    END LOOP;
  END IF;
  SELECT COALESCE(jsonb_agg(value ORDER BY ord),'[]') INTO output_proposals FROM jsonb_array_elements(work->'proposals') WITH ORDINALITY p(value,ord)
    WHERE value->>'membershipId'=grant_row.membership_id AND (owner_mode OR (value->>'proposedBy'=actor AND grant_row.definition->'scope'->'programIds' ? (value->>'programId')));
  output_scope:=scope-'taskSnapshots';
  RETURN jsonb_build_object('status','ok','data',jsonb_build_object('caseId',owner_case.case_id,'membershipId',grant_row.membership_id,'caseRevision',owner_case.revision,
    'permissionRevision',grant_row.permission_revision,'progressRevision',(task_record->>'revision')::integer,'collaborationRevision',(work->>'revision')::integer,
    'canManage',owner_mode,'scope',output_scope,'tasks',output_tasks,'proposals',output_proposals,'acknowledgedMutationId',acknowledged));
END $$;
REVOKE ALL ON FUNCTION safeathome_private.collaboration_operation(text,jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safeathome_private.collaboration_operation(text,jsonb,jsonb) TO safeathome_app;
