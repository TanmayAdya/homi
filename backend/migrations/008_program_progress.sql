-- Additive v3 tracking. cases already has forced owner RLS and private grants.
-- Drain old instances before admitting writes: deletion previews and backups
-- must include this column. Strict v1 case/history parsers remain unchanged.
ALTER TABLE safeathome_private.cases ADD COLUMN progress jsonb;
ALTER TABLE safeathome_private.cases ADD CONSTRAINT program_progress_record CHECK (
  progress IS NULL OR (
    jsonb_typeof(progress) = 'object' AND progress->>'schemaVersion' = '3'
    AND progress->>'caseId' = case_id
    AND (progress->>'revision')::numeric BETWEEN 1 AND 500
    AND jsonb_typeof(progress->'events') = 'array'
    AND jsonb_array_length(progress->'events') = (progress->>'revision')::numeric
    AND jsonb_array_length(progress->'programs') <= 32
    AND jsonb_array_length(progress->'tasks') <= 128
    AND octet_length(progress::text) <= 286720
  ) IS TRUE
);
