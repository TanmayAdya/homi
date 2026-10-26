import type { Pool, PoolClient } from 'pg';

export const RETENTION_JOB_NAME = 'safeathome-retention-v1';
export const RETENTION_SCHEDULE = '*/15 * * * *';
export const RETENTION_COMMAND = `SET statement_timeout = '8s';
SET lock_timeout = '3s';
SELECT safeathome_private.sweep_retention();
DELETE FROM cron.job_run_details WHERE jobid IN
  (SELECT jobid FROM cron.job WHERE jobname = 'safeathome-retention-v1' AND username = current_user)
  AND end_time < clock_timestamp() - interval '7 days';`;

export interface RetentionScheduleState { installed: boolean; scheduled: boolean; conflict: boolean }
export class RetentionScheduleError extends Error {
  constructor() { super('Retention scheduling failed or an existing job differs.'); this.name = 'RetentionScheduleError'; }
}

async function inspect(client: Pick<PoolClient, 'query'>): Promise<RetentionScheduleState & { jobId?: string }> {
  const extension = await client.query("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') AS installed");
  if (extension.rowCount !== 1 || typeof extension.rows[0]?.installed !== 'boolean') throw new RetentionScheduleError();
  if (!extension.rows[0].installed) return { installed: false, scheduled: false, conflict: false };
  const jobs = await client.query(`SELECT jobid::text, schedule, command, active,
    username = current_user AS own_user, database = current_database() AS own_database
    FROM cron.job WHERE jobname=$1`, [RETENTION_JOB_NAME]);
  if (jobs.rows.length === 0) return { installed: true, scheduled: false, conflict: false };
  const job = jobs.rows[0];
  if (jobs.rows.length !== 1 || typeof job.jobid !== 'string' || !/^[1-9][0-9]{0,18}$/.test(job.jobid)
    || job.schedule !== RETENTION_SCHEDULE || job.command !== RETENTION_COMMAND
    || job.own_user !== true || job.own_database !== true || job.active !== true) {
    return { installed: true, scheduled: false, conflict: true };
  }
  return { installed: true, scheduled: true, conflict: false, jobId: job.jobid };
}

export async function configureRetentionSchedule(
  pool: Pick<Pool, 'connect'>, action: 'status' | 'schedule' | 'unschedule' = 'status',
): Promise<RetentionScheduleState> {
  if (!['status', 'schedule', 'unschedule'].includes(action)) throw new RetentionScheduleError();
  let client: PoolClient;
  try { client = await pool.connect(); } catch { throw new RetentionScheduleError(); }
  let discard = false;
  try {
    await client.query(action === 'status' ? 'BEGIN READ ONLY' : 'BEGIN ISOLATION LEVEL SERIALIZABLE');
    if (action !== 'status') await client.query('SELECT pg_advisory_xact_lock(1935763045, 2)');
    let state = await inspect(client);
    if (action !== 'status') {
      if (action === 'schedule' && !state.installed) {
        await client.query('CREATE EXTENSION IF NOT EXISTS pg_cron');
        state = { installed: true, scheduled: false, conflict: false };
      }
      if (state.installed) {
        state = await inspect(client);
      }
      if (state.conflict) throw new RetentionScheduleError();
      if (action === 'schedule' && !state.scheduled) {
        await client.query('SELECT cron.schedule($1,$2,$3)', [RETENTION_JOB_NAME, RETENTION_SCHEDULE, RETENTION_COMMAND]);
      } else if (action === 'unschedule' && state.scheduled) {
        const result = await client.query('SELECT cron.unschedule($1::bigint) AS removed', [state.jobId]);
        if (result.rows[0]?.removed !== true) throw new RetentionScheduleError();
      }
      state = await inspect(client);
      if (state.conflict || state.scheduled !== (action === 'schedule')) throw new RetentionScheduleError();
    }
    await client.query('COMMIT');
    return { installed: state.installed, scheduled: state.scheduled, conflict: state.conflict };
  } catch {
    try { await client.query('ROLLBACK'); } catch { discard = true; }
    throw new RetentionScheduleError();
  } finally { client.release(discard); }
}
