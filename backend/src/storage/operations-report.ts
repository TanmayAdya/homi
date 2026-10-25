import type { Pool, PoolClient } from 'pg';
import { assertCompleteOperatorVisibility } from './capacity-report.ts';
import { RETENTION_COMMAND, RETENTION_JOB_NAME, RETENTION_SCHEDULE } from './retention-scheduler.ts';

export const OPERATIONS_THRESHOLDS = Object.freeze({ retentionSuccessStaleSeconds: 1800,
  retentionRunningLongSeconds: 300, authPendingOldSeconds: 900 });
const HISTORY_LIMIT = 1000;
export interface OperationsReport {
  schemaVersion: '1'; capturedAt: string; mode: 'read_only';
  retention: {
    state: 'configured' | 'missing_extension' | 'missing_job' | 'conflict' | 'unknown';
    history: 'known' | 'unknown'; lastSuccessAgeSeconds: number | null;
    latestFinishedStatus: 'succeeded' | 'failed' | 'other' | null;
    failedRuns24h: number | null; runningCount: number | null; oldestRunningAgeSeconds: number | null;
  };
  authDeletions: { pending: number; ready: number; leased: number; deferred: number;
    oldestPendingAgeSeconds: number | null; oldestReadyDelaySeconds: number | null };
  fences: { closedAccountsWithoutJob: number; jobsWithoutClosedAccount: number;
    completionMismatches: number; identityMismatches: number; consistent: boolean };
  warnings: string[];
}
export class OperationsReportError extends Error {
  constructor() { super('Operations report failed. Check current migrations and complete operator visibility.'); this.name = 'OperationsReportError'; }
}
function check(value: unknown): asserts value { if (!value) throw new OperationsReportError(); }
function integer(value: unknown): number {
  check(typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value));
  const parsed = Number(value); check(Number.isSafeInteger(parsed)); return parsed;
}
function age(value: unknown): number | null { return value === null ? null : integer(value); }
function unknownRetention(state: OperationsReport['retention']['state']): OperationsReport['retention'] {
  return { state, history: 'unknown', lastSuccessAgeSeconds: null, latestFinishedStatus: null,
    failedRuns24h: null, runningCount: null, oldestRunningAgeSeconds: null };
}

async function readRetention(client: PoolClient, warnings: string[], capturedAt: string): Promise<OperationsReport['retention']> {
  const extension = await client.query("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') AS installed");
  check(extension.rows.length === 1 && typeof extension.rows[0].installed === 'boolean');
  if (!extension.rows[0].installed) { warnings.push('retention_extension_missing'); return unknownRetention('missing_extension'); }
  const metadata = await client.query(`SELECT c.relname,c.relkind,
    has_schema_privilege(n.oid,'USAGE') AND has_table_privilege(c.oid,'SELECT') AS readable,
    NOT row_security_active(c.oid) AS full_visibility
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='cron' AND c.relname IN ('job','job_run_details')`);
  const available = (name: string) => metadata.rows.filter(row => row.relname === name && row.relkind === 'r'
    && row.readable === true && row.full_visibility === true).length === 1;
  if (!available('job')) { warnings.push('retention_job_visibility_unknown'); return unknownRetention('unknown'); }
  const jobs = await client.query(`SELECT jobid::text,
    schedule=$2 AS correct_schedule, command=$3 AS correct_command, active,
    username=current_user AS own_user, database=current_database() AS own_database
    FROM cron.job WHERE jobname=$1 LIMIT 2`, [RETENTION_JOB_NAME, RETENTION_SCHEDULE, RETENTION_COMMAND]);
  if (!jobs.rows.length) { warnings.push('retention_job_missing'); return unknownRetention('missing_job'); }
  const job = jobs.rows[0];
  if (jobs.rows.length !== 1 || typeof job.jobid !== 'string' || !/^[1-9][0-9]{0,18}$/.test(job.jobid)
    || job.correct_schedule !== true || job.correct_command !== true || job.active !== true
    || job.own_user !== true || job.own_database !== true) {
    warnings.push('retention_job_conflict'); return unknownRetention('conflict');
  }
  if (!available('job_run_details')) { warnings.push('retention_history_unknown'); return unknownRetention('configured'); }
  const history = await client.query(`WITH recent AS (
      SELECT runid,status,start_time,end_time,
        username=current_user AND database=current_database() AND command=$2 AS identity_matches
      FROM cron.job_run_details WHERE jobid=$1::bigint
        AND (start_time>=$3::timestamptz-interval '7 days'
          OR end_time>=$3::timestamptz-interval '7 days' OR end_time IS NULL)
      ORDER BY runid DESC LIMIT 1001
    ) SELECT count(*)::text AS rows,
      count(*) FILTER (WHERE identity_matches IS DISTINCT FROM true)::text AS identity_mismatches,
      count(*) FILTER (WHERE start_time IS NULL OR NOT isfinite(start_time) OR start_time>$3::timestamptz
        OR (end_time IS NOT NULL AND (NOT isfinite(end_time) OR end_time<start_time OR end_time>$3::timestamptz))
        OR (end_time IS NULL AND status NOT IN ('starting','running','sending','connecting'))
        OR (end_time IS NOT NULL AND status NOT IN ('succeeded','failed')) OR status IS NULL)::text AS malformed,
      floor(extract(epoch FROM $3::timestamptz-max(end_time) FILTER (WHERE status='succeeded')))::text AS success_age,
      (SELECT CASE WHEN status='succeeded' THEN 'succeeded' WHEN status='failed' THEN 'failed' ELSE 'other' END
        FROM recent WHERE end_time IS NOT NULL ORDER BY end_time DESC,runid DESC LIMIT 1) AS latest_status,
      count(*) FILTER (WHERE status='failed' AND end_time>=$3::timestamptz-interval '24 hours')::text AS failures,
      count(*) FILTER (WHERE end_time IS NULL)::text AS running,
      floor(extract(epoch FROM $3::timestamptz-min(start_time) FILTER (WHERE end_time IS NULL)))::text AS running_age
      FROM recent`, [job.jobid, RETENTION_COMMAND, capturedAt]);
  check(history.rows.length === 1);
  const row = history.rows[0], count = integer(row.rows);
  if (!count || count > HISTORY_LIMIT || integer(row.identity_mismatches) || integer(row.malformed)) {
    warnings.push(count > HISTORY_LIMIT ? 'retention_history_limit_exceeded' : !count ? 'retention_history_missing' : 'retention_history_unknown');
    return unknownRetention('configured');
  }
  check(row.latest_status === null || ['succeeded', 'failed', 'other'].includes(row.latest_status));
  const result: OperationsReport['retention'] = { state: 'configured', history: 'known',
    lastSuccessAgeSeconds: age(row.success_age), latestFinishedStatus: row.latest_status,
    failedRuns24h: integer(row.failures), runningCount: integer(row.running), oldestRunningAgeSeconds: age(row.running_age) };
  if (result.lastSuccessAgeSeconds === null) warnings.push('retention_success_missing');
  else if (result.lastSuccessAgeSeconds >= OPERATIONS_THRESHOLDS.retentionSuccessStaleSeconds) warnings.push('retention_success_stale');
  if (result.failedRuns24h! > 0) warnings.push('retention_failures_last_24h');
  if (result.latestFinishedStatus === 'failed') warnings.push('retention_latest_run_failed');
  if (result.oldestRunningAgeSeconds !== null && result.oldestRunningAgeSeconds >= OPERATIONS_THRESHOLDS.retentionRunningLongSeconds) warnings.push('retention_run_long');
  return result;
}

export async function readOperationsReport(pool: Pool): Promise<OperationsReport> {
  let client: PoolClient | undefined, broken = false;
  try {
    client = await pool.connect();
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    const clock = await client.query(`SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS captured_at`);
    check(clock.rows.length === 1 && typeof clock.rows[0].captured_at === 'string'
      && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/.test(clock.rows[0].captured_at));
    const capturedAt: string = clock.rows[0].captured_at;
    await assertCompleteOperatorVisibility(client);
    const result = await client.query(`WITH work AS (
      SELECT j.completed_at,j.next_attempt_at,j.lease_until,c.closed_at,
        j.completed_at IS NULL AS pending,
        j.completed_at IS NULL AND j.lease_until>$1::timestamptz AS leased,
        j.completed_at IS NULL AND (j.lease_until IS NULL OR j.lease_until<=$1::timestamptz)
          AND j.next_attempt_at<=$1::timestamptz AS ready
      FROM safeathome_private.auth_deletion_jobs j LEFT JOIN safeathome_private.closed_accounts c USING(owner_hash)
    ) SELECT count(*) FILTER (WHERE pending)::text AS pending,
      count(*) FILTER (WHERE ready)::text AS ready,
      count(*) FILTER (WHERE leased)::text AS leased,
      count(*) FILTER (WHERE pending AND NOT COALESCE(leased,false) AND NOT ready)::text AS deferred,
      floor(extract(epoch FROM $1::timestamptz-min(closed_at) FILTER (WHERE pending)))::text AS pending_age,
      floor(extract(epoch FROM $1::timestamptz-min(next_attempt_at) FILTER (WHERE ready)))::text AS ready_delay,
      count(*) FILTER (WHERE closed_at IS NULL OR NOT isfinite(closed_at) OR closed_at>$1::timestamptz
        OR NOT isfinite(next_attempt_at) OR (lease_until IS NOT NULL AND NOT isfinite(lease_until))
        OR (completed_at IS NOT NULL AND (NOT isfinite(completed_at) OR completed_at<closed_at OR completed_at>$1::timestamptz)))::text AS invalid_times,
      (SELECT count(*)::text FROM safeathome_private.closed_accounts c LEFT JOIN safeathome_private.auth_deletion_jobs j USING(owner_hash)
        WHERE j.owner_hash IS NULL) AS missing_jobs,
      (SELECT count(*)::text FROM safeathome_private.auth_deletion_jobs j LEFT JOIN safeathome_private.closed_accounts c USING(owner_hash)
        WHERE c.owner_hash IS NULL) AS missing_fences,
      (SELECT count(*)::text FROM safeathome_private.auth_deletion_jobs j JOIN safeathome_private.closed_accounts c USING(owner_hash)
        WHERE (j.completed_at IS NULL)<>(c.auth_deleted_at IS NULL)
          OR (c.auth_deleted_at IS NOT NULL AND (NOT isfinite(c.auth_deleted_at) OR c.auth_deleted_at<c.closed_at OR c.auth_deleted_at>$1::timestamptz))) AS completion_mismatches,
      (SELECT count(*)::text FROM safeathome_private.auth_deletion_jobs j
        WHERE (j.completed_at IS NULL AND (j.raw_user_id IS NULL OR j.owner_hash<>encode(sha256(convert_to(j.raw_user_id,'UTF8')),'hex')))
          OR (j.completed_at IS NOT NULL AND (j.raw_user_id IS NOT NULL OR j.lease_token IS NOT NULL OR j.lease_until IS NOT NULL))
          OR (j.lease_token IS NULL)<>(j.lease_until IS NULL)) AS identity_mismatches
      FROM work`, [capturedAt]);
    check(result.rows.length === 1); const row = result.rows[0];
    const warnings: string[] = [], invalidTimes = integer(row.invalid_times) > 0;
    const authDeletions = { pending: integer(row.pending), ready: integer(row.ready), leased: integer(row.leased),
      deferred: integer(row.deferred), oldestPendingAgeSeconds: invalidTimes ? null : age(row.pending_age),
      oldestReadyDelaySeconds: invalidTimes ? null : age(row.ready_delay) };
    check(authDeletions.pending === authDeletions.ready + authDeletions.leased + authDeletions.deferred);
    const counts = { closedAccountsWithoutJob: integer(row.missing_jobs), jobsWithoutClosedAccount: integer(row.missing_fences),
      completionMismatches: integer(row.completion_mismatches), identityMismatches: integer(row.identity_mismatches) };
    const fences = { ...counts, consistent: Object.values(counts).every(value => value === 0) };
    if (authDeletions.pending > 0) warnings.push('auth_deletions_pending');
    if (!fences.consistent) warnings.push('auth_deletion_fence_mismatch');
    if (invalidTimes) warnings.push('auth_deletion_timestamps_invalid');
    if (authDeletions.oldestPendingAgeSeconds !== null && authDeletions.oldestPendingAgeSeconds >= OPERATIONS_THRESHOLDS.authPendingOldSeconds) warnings.push('auth_deletions_aging');
    let retention: OperationsReport['retention'];
    await client.query('SAVEPOINT operations_retention');
    try { retention = await readRetention(client, warnings, capturedAt); }
    catch {
      await client.query('ROLLBACK TO SAVEPOINT operations_retention');
      warnings.push('retention_metadata_unavailable'); retention = unknownRetention('unknown');
    }
    await client.query('RELEASE SAVEPOINT operations_retention');
    await client.query('COMMIT');
    return { schemaVersion: '1', capturedAt, mode: 'read_only', retention, authDeletions, fences, warnings };
  } catch {
    if (client) try { await client.query('ROLLBACK'); } catch { broken = true; }
    throw new OperationsReportError();
  } finally { client?.release(broken); }
}
