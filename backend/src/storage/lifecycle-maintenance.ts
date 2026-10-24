import type { Pool } from 'pg';
import type { AuthDeletionJob, LifecycleMaintenance, RetentionReport } from '../lifecycle/types.ts';
import { evidenceIdentifier } from '../evidence/validation.ts';

const uuid = (value: unknown): value is string => typeof value === 'string'
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
function count(value: unknown): number {
  const parsed = typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value) ? Number(value) : value;
  if (!Number.isSafeInteger(parsed) || Number(parsed) < 0) throw new Error('Invalid lifecycle result.');
  return Number(parsed);
}

export class PostgresLifecycleMaintenance implements LifecycleMaintenance {
  private readonly pool: Pool;
  constructor(pool: Pool) { this.pool = pool; }
  async pendingAuthDeletionCount(): Promise<number> {
    const result = await this.pool.query('SELECT safeathome_private.pending_auth_deletion_count() AS count');
    return count(result.rows[0]?.count);
  }
  async claimAuthDeletionJobs(limit: number): Promise<AuthDeletionJob[]> {
    if (!Number.isInteger(limit) || limit < 1 || limit > 10) throw new Error('Invalid lifecycle batch.');
    const result = await this.pool.query('SELECT * FROM safeathome_private.claim_auth_deletion_jobs($1)', [limit]);
    if (result.rows.length > limit) throw new Error('Invalid lifecycle result.');
    return result.rows.map(row => {
      if (!uuid(row.job_id) || !uuid(row.lease_token) || !evidenceIdentifier(row.user_id)) throw new Error('Invalid lifecycle result.');
      return { jobId: row.job_id, userId: row.user_id, leaseToken: row.lease_token };
    });
  }
  async finishAuthDeletionJob(input: { jobId: string; leaseToken: string; outcome: 'deleted' | 'retry' }): Promise<boolean> {
    const { jobId, leaseToken, outcome } = input;
    if (!uuid(jobId) || !uuid(leaseToken) || !['deleted', 'retry'].includes(outcome)) throw new Error('Invalid lifecycle job.');
    const result = await this.pool.query('SELECT safeathome_private.finish_auth_deletion_job($1::uuid,$2::uuid,$3) AS finished',
      [jobId, leaseToken, outcome === 'deleted']);
    if (typeof result.rows[0]?.finished !== 'boolean') throw new Error('Invalid lifecycle result.');
    return result.rows[0].finished;
  }
  async sweepRetention(): Promise<RetentionReport> {
    const result = await this.pool.query('SELECT * FROM safeathome_private.sweep_retention()');
    if (result.rowCount !== 1) throw new Error('Invalid lifecycle result.');
    const row = result.rows[0];
    return { expiredExports: count(row.expired_exports), releasedBytes: count(row.released_bytes),
      expiredPreviews: count(row.expired_previews), expiredReceipts: count(row.expired_receipts) };
  }
}
