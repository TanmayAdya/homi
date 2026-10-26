-- One self-contained connected-home snapshot, independently revisioned. Reuse
-- the owner RLS, lifecycle cascade and quota accounting of private room models.
ALTER TABLE safeathome_private.case_scan_models
 DROP CONSTRAINT case_scan_models_room_key_check,
 DROP CONSTRAINT case_scan_models_record_check,
 ADD CONSTRAINT case_scan_models_room_key_check CHECK (
  room_key IN ('legacy','home') OR (room_key LIKE 'room:%' AND length(room_key) BETWEEN 6 AND 205)),
 ADD CONSTRAINT case_scan_models_record_check CHECK (
  octet_length(record) BETWEEN 1 AND CASE WHEN room_key='home' THEN 3145728 ELSE 786432 END);
