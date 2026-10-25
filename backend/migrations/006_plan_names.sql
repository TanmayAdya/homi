-- Optional presentation metadata is owned and erased with the existing case.
-- A reset remains a revisioned record; SQL NULL alone means never named.
ALTER TABLE safeathome_private.cases ADD COLUMN plan_name jsonb;
ALTER TABLE safeathome_private.cases ADD CONSTRAINT plan_name_shape CHECK (
  plan_name IS NULL OR (
    jsonb_typeof(plan_name)='object' AND octet_length(plan_name::text)<=4096
    AND plan_name ?& ARRAY['schemaVersion','caseId','name','nameRevision','lastMutationId']
    AND plan_name - ARRAY['schemaVersion','caseId','name','nameRevision','lastMutationId']='{}'::jsonb
    AND plan_name->>'schemaVersion'='2' AND jsonb_typeof(plan_name->'schemaVersion')='string'
    AND plan_name->>'caseId'=case_id AND jsonb_typeof(plan_name->'caseId')='string'
    AND jsonb_typeof(plan_name->'nameRevision')='number'
    AND (plan_name->>'nameRevision')::numeric BETWEEN 1 AND 9007199254740991
    AND (plan_name->>'nameRevision')::numeric=trunc((plan_name->>'nameRevision')::numeric)
    AND jsonb_typeof(plan_name->'lastMutationId')='string'
    AND char_length(plan_name->>'lastMutationId') BETWEEN 1 AND 200
    AND (plan_name->'name'='null'::jsonb OR jsonb_typeof(plan_name->'name')='string'
      AND char_length(plan_name->>'name') BETWEEN 1 AND 80)
  ) IS TRUE
);
COMMENT ON COLUMN safeathome_private.cases.plan_name IS 'Private versioned plan display name; independent of case and output revisions.';
