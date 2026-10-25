-- Additive private sidecar. Inherits cases' forced owner RLS and cascade-free
-- deletion. Drain older service instances: deletion previews must bind this
-- column before any checklist writes are admitted. No v1/v2 case shape changes.
ALTER TABLE safeathome_private.cases ADD COLUMN home_safety jsonb;
ALTER TABLE safeathome_private.cases ADD CONSTRAINT home_safety_record CHECK (
  home_safety IS NULL OR (
    jsonb_typeof(home_safety) = 'object'
    AND home_safety->>'schemaVersion' = '3'
    AND home_safety->>'caseId' = case_id
    AND (home_safety->>'revision')::numeric BETWEEN 1 AND 500
    AND jsonb_typeof(home_safety->'document') = 'object'
    AND jsonb_typeof(home_safety->'history') = 'array'
    AND jsonb_array_length(home_safety->'history') = (home_safety->>'revision')::numeric
    AND octet_length(home_safety::text) <= 286720
  ) IS TRUE
);
