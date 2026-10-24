import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { after, before, beforeEach, test } from 'node:test';
import type { Pool } from 'pg';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { readOperationsReport, OperationsReportError, OPERATIONS_THRESHOLDS } from '../../src/storage/operations-report.ts';
import { RETENTION_COMMAND, RETENTION_JOB_NAME, RETENTION_SCHEDULE } from '../../src/storage/retention-scheduler.ts';
import { TestPostgres } from './harness.ts';
import { readOperationsHealth } from '../../tool/operations.ts';

let cluster: TestPostgres, admin: Pool, operator: Pool, runtime: Pool;
const operatorName = 'operations_operator';
const privateIdentity = 'private-fictional-operations-owner';
const privateFailure = 'private-synthetic-driver-return-message';
const hash = (value: string) => createHash('sha256').update(value).digest('hex');
before(async () => {
  cluster = await TestPostgres.start(); admin = cluster.pool(); await applyMigrations(admin);
  await admin.query(`CREATE ROLE operations_operator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE sah_test_admin;
    CREATE ROLE operations_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app;
    CREATE ROLE operations_cron_owner NOLOGIN;
    CREATE SCHEMA cron;
    CREATE TABLE cron.job(jobid bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,jobname text NOT NULL,
      schedule text NOT NULL,command text NOT NULL,active boolean NOT NULL DEFAULT true,username text NOT NULL,database text NOT NULL);
    CREATE TABLE cron.job_run_details(runid bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,jobid bigint NOT NULL,
      username text, database text, command text, status text, start_time timestamptz,end_time timestamptz,return_message text);
    ALTER TABLE cron.job OWNER TO operations_cron_owner;
    ALTER TABLE cron.job_run_details OWNER TO operations_cron_owner;
    GRANT USAGE ON SCHEMA cron TO operations_operator;
    GRANT SELECT ON cron.job,cron.job_run_details TO operations_operator`);
  operator = cluster.pool(operatorName); runtime = cluster.pool('operations_runtime');
});
beforeEach(async () => {
  await admin.query(`TRUNCATE safeathome_private.auth_deletion_jobs,safeathome_private.closed_accounts,cron.job,cron.job_run_details RESTART IDENTITY`);
  await admin.query(`INSERT INTO cron.job(jobname,schedule,command,username,database) VALUES($1,$2,$3,$4,current_database())`,
    [RETENTION_JOB_NAME, RETENTION_SCHEDULE, RETENTION_COMMAND, operatorName]);
  await history();
});
after(async () => { await cluster?.close(); });

function readerPool(options: { installed?: boolean; afterClock?: () => Promise<void>; afterBegin?: () => Promise<void> } = {}) {
  const sql: string[] = []; let readOnly = false, isolation = '', released = false;
  const pool = { connect: async () => {
    const client = await operator.connect();
    return { release: (broken?: boolean) => { released = true; client.release(broken); },
      query: async (statement: string, values?: unknown[]) => {
        sql.push(statement);
        if (statement.includes("FROM pg_extension WHERE extname='pg_cron'")) {
          return { rows: [{ installed: options.installed ?? true }], rowCount: 1 };
        }
        const result = await client.query(statement, values);
        if (statement.startsWith('BEGIN')) await options.afterBegin?.();
        if (statement.startsWith('SELECT to_char(clock_timestamp()')) {
          readOnly = (await client.query('SHOW transaction_read_only')).rows[0].transaction_read_only === 'on';
          isolation = (await client.query('SHOW transaction_isolation')).rows[0].transaction_isolation;
          await options.afterClock?.();
        }
        return result;
      } };
  } } as unknown as Pool;
  return { pool, sql, state: () => ({ readOnly, isolation, released }) };
}
async function history(options: { jobId?: number; status?: string; startAgo?: number; endAgo?: number | null;
  command?: string; username?: string; database?: string } = {}) {
  await admin.query(`INSERT INTO cron.job_run_details(jobid,username,database,command,status,start_time,end_time,return_message)
    VALUES($1,$2,COALESCE($3,current_database()),$4,$5,clock_timestamp()-$6::integer*interval '1 second',
      CASE WHEN $7::integer IS NULL THEN NULL ELSE clock_timestamp()-$7::integer*interval '1 second' END,$8)`,
  [options.jobId ?? 1, options.username ?? operatorName, options.database ?? null, options.command ?? RETENTION_COMMAND,
    options.status ?? 'succeeded', options.startAgo ?? 65, options.endAgo === undefined ? 60 : options.endAgo, privateFailure]);
}
async function closure(label: string, options: { age?: number; retryDelay?: number; leaseDelay?: number; completed?: boolean; noJob?: boolean } = {}) {
  const identity = `${privateIdentity}-${label}`, owner = hash(identity);
  await admin.query(`INSERT INTO safeathome_private.closed_accounts(owner_hash,closed_at,receipt_expires_at,auth_deleted_at)
    VALUES($1,clock_timestamp()-$2::integer*interval '1 second',clock_timestamp()+interval '1 day',
      CASE WHEN $3::boolean THEN clock_timestamp()-interval '1 second' ELSE NULL END)`, [owner, options.age ?? 120, options.completed ?? false]);
  if (!options.noJob) await admin.query(`INSERT INTO safeathome_private.auth_deletion_jobs
    (owner_hash,raw_user_id,completed_at,next_attempt_at,lease_token,lease_until)
    VALUES($1,$2,CASE WHEN $3::boolean THEN clock_timestamp()-interval '1 second' ELSE NULL END,
      clock_timestamp()+$4::integer*interval '1 second',$5,
      CASE WHEN $6::integer IS NULL THEN NULL ELSE clock_timestamp()+$6::integer*interval '1 second' END)`,
  [owner, options.completed ? null : identity, options.completed ?? false, options.retryDelay ?? -60,
    options.leaseDelay === undefined ? null : randomUUID(), options.leaseDelay ?? null]);
  return owner;
}
async function rows() {
  return Promise.all(['safeathome_private.closed_accounts', 'safeathome_private.auth_deletion_jobs', 'cron.job', 'cron.job_run_details']
    .map(async table => (await admin.query(`SELECT row_to_json(t) AS value FROM ${table} t ORDER BY row_to_json(t)::text`)).rows));
}

test('exact configured job and recent success produce an aggregate read-only report without raw content', async () => {
  await closure('completed', { completed: true }); const beforeRows = await rows(), tracked = readerPool();
  const report = await readOperationsReport(tracked.pool);
  assert.equal(report.mode, 'read_only'); assert.equal(report.retention.state, 'configured'); assert.equal(report.retention.history, 'known');
  assert.equal(report.retention.latestFinishedStatus, 'succeeded'); assert.ok(report.retention.lastSuccessAgeSeconds! >= 60);
  assert.deepEqual(report.authDeletions, { pending: 0, ready: 0, leased: 0, deferred: 0, oldestPendingAgeSeconds: null, oldestReadyDelaySeconds: null });
  assert.equal(report.fences.consistent, true); assert.deepEqual(report.warnings, []);
  assert.deepEqual(tracked.state(), { readOnly: true, isolation: 'repeatable read', released: true });
  assert.deepEqual(await rows(), beforeRows);
  assert.equal(tracked.sql.some(sql => /\b(?:INSERT|UPDATE|DELETE|sweep_retention|claim_auth_deletion_jobs|finish_auth_deletion_job|cron\.schedule)\b/i.test(sql)), false);
  const encoded = JSON.stringify(report);
  for (const secret of [privateIdentity, hash(`${privateIdentity}-completed`), privateFailure, operatorName, RETENTION_COMMAND]) assert.equal(encoded.includes(secret), false);
});

test('pending ages use closure time and lease/ready/deferred states partition work including expired leases', async () => {
  await closure('ready', { age: 2400, retryDelay: -10 });
  await closure('leased', { age: 1800, retryDelay: -100, leaseDelay: 60 });
  await closure('deferred', { age: 1200, retryDelay: 240 });
  await closure('expired', { age: 600, retryDelay: -30, leaseDelay: -1 });
  await closure('done', { completed: true, age: 3000 });
  const report = await readOperationsReport(readerPool().pool);
  assert.deepEqual({ ...report.authDeletions, oldestPendingAgeSeconds: null, oldestReadyDelaySeconds: null },
    { pending: 4, ready: 2, leased: 1, deferred: 1, oldestPendingAgeSeconds: null, oldestReadyDelaySeconds: null });
  assert.ok(report.authDeletions.oldestPendingAgeSeconds! >= 2400 && report.authDeletions.oldestPendingAgeSeconds! < 2410);
  assert.ok(report.authDeletions.oldestReadyDelaySeconds! >= 30 && report.authDeletions.oldestReadyDelaySeconds! < 40);
  assert.ok(report.warnings.includes('auth_deletions_pending')); assert.ok(report.warnings.includes('auth_deletions_aging'));
  await admin.query('UPDATE safeathome_private.auth_deletion_jobs SET next_attempt_at=clock_timestamp()+interval \'5 minutes\' WHERE completed_at IS NULL');
  assert.ok((await readOperationsReport(readerPool().pool)).authDeletions.oldestPendingAgeSeconds! >= 2400);
});

test('new pending work is visible before the aging threshold', async () => {
  await closure('new', { age: 1 }); const report = await readOperationsReport(readerPool().pool);
  assert.ok(report.warnings.includes('auth_deletions_pending')); assert.equal(report.warnings.includes('auth_deletions_aging'), false);
});

test('missing jobs and contradictory completion/lease state produce aggregate fence warnings without repair', async () => {
  await closure('missing', { noJob: true }); const mismatched = await closure('mismatch');
  await admin.query('UPDATE safeathome_private.closed_accounts SET auth_deleted_at=clock_timestamp()-interval \'1 second\' WHERE owner_hash=$1', [mismatched]);
  await closure('completed-lease', { completed: true, leaseDelay: 60 });
  const beforeRows = await rows(), report = await readOperationsReport(readerPool().pool);
  assert.deepEqual(report.fences, { closedAccountsWithoutJob: 1, jobsWithoutClosedAccount: 0, completionMismatches: 1, identityMismatches: 1, consistent: false });
  assert.ok(report.warnings.includes('auth_deletion_fence_mismatch')); assert.deepEqual(await rows(), beforeRows);
});

test('missing extension, missing job and altered configuration never imply healthy retention', async () => {
  assert.equal((await readOperationsReport(operator)).retention.state, 'missing_extension');
  await admin.query('DELETE FROM cron.job');
  assert.equal((await readOperationsReport(readerPool().pool)).retention.state, 'missing_job');
  for (const [schedule, command, active, username, database] of [
    ['* * * * *', RETENTION_COMMAND, true, operatorName, null],
    [RETENTION_SCHEDULE, 'SELECT private-command-sentinel', true, operatorName, null],
    [RETENTION_SCHEDULE, RETENTION_COMMAND, false, operatorName, null],
    [RETENTION_SCHEDULE, RETENTION_COMMAND, true, 'other-private-user', null],
    [RETENTION_SCHEDULE, RETENTION_COMMAND, true, operatorName, 'other-database'],
  ]) {
    await admin.query('TRUNCATE cron.job');
    await admin.query('INSERT INTO cron.job(jobname,schedule,command,active,username,database) VALUES($1,$2,$3,$4,$5,COALESCE($6,current_database()))',
      [RETENTION_JOB_NAME, schedule, command, active, username, database]);
    const report = await readOperationsReport(readerPool().pool);
    assert.equal(report.retention.state, 'conflict'); assert.equal(report.retention.history, 'unknown'); assert.ok(report.warnings.length);
    assert.doesNotMatch(JSON.stringify(report), /private-command-sentinel|other-private-user|other-database/);
  }
});

test('duplicate named jobs and unrelated successful history cannot establish current health', async () => {
  await admin.query('INSERT INTO cron.job(jobname,schedule,command,username,database) SELECT jobname,schedule,command,username,database FROM cron.job');
  assert.equal((await readOperationsReport(readerPool().pool)).retention.state, 'conflict');
  await admin.query('DELETE FROM cron.job WHERE jobid<>1; DELETE FROM cron.job_run_details');
  await history({ jobId: 999 });
  const report = await readOperationsReport(readerPool().pool);
  assert.equal(report.retention.history, 'unknown'); assert.equal(report.retention.lastSuccessAgeSeconds, null);
  assert.ok(report.warnings.includes('retention_history_missing'));
});

test('history reports stale success, recent failures and long running jobs using fixed investigation targets', async () => {
  assert.deepEqual(OPERATIONS_THRESHOLDS, { retentionSuccessStaleSeconds: 1800, retentionRunningLongSeconds: 300, authPendingOldSeconds: 900 });
  await admin.query('DELETE FROM cron.job_run_details');
  await history({ startAgo: 1905, endAgo: 1900 });
  await history({ status: 'failed', startAgo: 120, endAgo: 115 });
  await history({ status: 'failed', startAgo: 90005, endAgo: 90000 });
  await history({ status: 'running', startAgo: 310, endAgo: null });
  const report = await readOperationsReport(readerPool().pool);
  assert.equal(report.retention.history, 'known'); assert.equal(report.retention.failedRuns24h, 1);
  assert.equal(report.retention.runningCount, 1); assert.ok(report.retention.oldestRunningAgeSeconds! >= 310);
  for (const warning of ['retention_success_stale', 'retention_failures_last_24h', 'retention_latest_run_failed', 'retention_run_long']) assert.ok(report.warnings.includes(warning));
});

test('unknown status, invalid chronology and altered historical identity make all history metrics unknown', async () => {
  for (const options of [{ status: 'private-status-sentinel' }, { startAgo: -10, endAgo: -5 }, { startAgo: 1, endAgo: 10 },
    { command: 'SELECT private-old-command' }, { username: 'private-old-user' }, { database: 'private-old-database' }]) {
    await admin.query('DELETE FROM cron.job_run_details'); await history(options);
    const report = await readOperationsReport(readerPool().pool);
    assert.equal(report.retention.history, 'unknown'); assert.equal(report.retention.lastSuccessAgeSeconds, null);
    assert.equal(report.retention.failedRuns24h, null); assert.ok(report.warnings.includes('retention_history_unknown'));
    assert.doesNotMatch(JSON.stringify(report), /private-status|private-old/);
  }
});

test('bounded history refuses to hide overflow behind a recent success', async () => {
  await admin.query(`INSERT INTO cron.job_run_details(jobid,username,database,command,status,start_time,end_time)
    SELECT 1,$1,current_database(),$2,'succeeded',clock_timestamp()-interval '2 minutes',clock_timestamp()-interval '1 minute'
    FROM generate_series(1,1000)`, [operatorName, RETENTION_COMMAND]);
  const report = await readOperationsReport(readerPool().pool);
  assert.equal(report.retention.history, 'unknown'); assert.ok(report.warnings.includes('retention_history_limit_exceeded'));
});

test('cron permission gaps or restrictive row visibility cannot hide failed history behind visible success', async () => {
  await admin.query('REVOKE SELECT ON cron.job_run_details FROM operations_operator');
  try { assert.ok((await readOperationsReport(readerPool().pool)).warnings.includes('retention_history_unknown')); }
  finally { await admin.query('GRANT SELECT ON cron.job_run_details TO operations_operator'); }
  await history({ status: 'failed' });
  await admin.query(`ALTER TABLE cron.job_run_details ENABLE ROW LEVEL SECURITY;
    CREATE POLICY hide_failures ON cron.job_run_details FOR SELECT TO operations_operator USING(status='succeeded')`);
  try { assert.equal((await readOperationsReport(readerPool().pool)).retention.history, 'unknown'); }
  finally { await admin.query('DROP POLICY hide_failures ON cron.job_run_details; ALTER TABLE cron.job_run_details DISABLE ROW LEVEL SECURITY'); }
});

test('runtime role, restrictive private policy and migration drift fail with a finite redacted error', async () => {
  await assert.rejects(readOperationsReport(runtime), OperationsReportError);
  await admin.query('CREATE POLICY operations_hidden ON safeathome_private.closed_accounts AS RESTRICTIVE FOR SELECT TO operations_operator USING(false)');
  try { await assert.rejects(readOperationsReport(operator), OperationsReportError); }
  finally { await admin.query('DROP POLICY operations_hidden ON safeathome_private.closed_accounts'); }
  const before = (await admin.query("SELECT checksum FROM safeathome_migrations.versions WHERE version='003'")).rows[0].checksum;
  await admin.query("UPDATE safeathome_migrations.versions SET checksum='private-invalid-checksum' WHERE version='003'");
  try { await assert.rejects(readOperationsReport(operator), error => error instanceof OperationsReportError && !error.message.includes('private-invalid')); }
  finally { await admin.query("UPDATE safeathome_migrations.versions SET checksum=$1 WHERE version='003'", [before]); }
});

test('unexpected cron schema errors retain Auth aggregates but never return raw SQL diagnostics', async () => {
  await closure('new'); await admin.query('ALTER TABLE cron.job_run_details RENAME COLUMN status TO private_missing_status');
  try {
    const tracked = readerPool(), report = await readOperationsReport(tracked.pool);
    assert.equal(report.authDeletions.pending, 1); assert.equal(report.retention.state, 'unknown');
    assert.ok(report.warnings.includes('retention_metadata_unavailable')); assert.doesNotMatch(JSON.stringify(report), /private_missing_status|column|SQL/);
    assert.equal(tracked.state().released, true); assert.ok(tracked.sql.includes('ROLLBACK TO SAVEPOINT operations_retention'));
  } finally { await admin.query('ALTER TABLE cron.job_run_details RENAME COLUMN private_missing_status TO status'); }
});

test('all aggregate fields share the first read-only snapshot and do not observe a later closure', async () => {
  const tracked = readerPool({ afterClock: async () => { await closure('concurrent'); } });
  const report = await readOperationsReport(tracked.pool);
  assert.equal(report.authDeletions.pending, 0); assert.equal(report.fences.consistent, true);
  assert.equal((await readOperationsReport(readerPool().pool)).authDeletions.pending, 1);
});

test('a closure committed after BEGIN but before first snapshot is not falsely future-dated', async () => {
  const tracked = readerPool({ afterBegin: async () => { await closure('before-snapshot', { age: 0 }); } });
  const report = await readOperationsReport(tracked.pool);
  assert.equal(report.authDeletions.pending, 1); assert.equal(report.authDeletions.oldestPendingAgeSeconds, 0);
  assert.equal(report.warnings.includes('auth_deletion_timestamps_invalid'), false);
});

test('future closure time is unknown and warned rather than clamped into a healthy young queue', async () => {
  await closure('future', { age: -3600 });
  const report = await readOperationsReport(readerPool().pool);
  assert.equal(report.authDeletions.oldestPendingAgeSeconds, null); assert.ok(report.warnings.includes('auth_deletion_timestamps_invalid'));
});

test('combined health preserves separate snapshots and warns about a new pending job appearing after capacity', async () => {
  let commits = 0;
  const tracked = readerPool();
  const pool = { connect: async () => {
    const client = await tracked.pool.connect();
    return { release: (broken?: boolean) => client.release(broken), query: async (sql: string, values?: unknown[]) => {
      const result = await client.query(sql, values);
      if (sql === 'COMMIT' && ++commits === 1) await closure('between-reports', { age: 1 });
      return result;
    } };
  } } as unknown as Pool;
  const report = await readOperationsHealth(pool);
  assert.equal(report.componentsShareSnapshot, false); assert.equal(report.mode, 'read_only');
  assert.equal(report.capacity.payloads.pendingAuthDeletions, 0); assert.equal(report.lifecycle.authDeletions.pending, 1);
  assert.notEqual(report.capacity.capturedAt, report.lifecycle.capturedAt);
  assert.equal(report.status, 'attention_required'); assert.equal(report.exitCode, 2);
  assert.ok(report.warnings.includes('lifecycle.auth_deletions_pending'));
  assert.equal(report.warnings.includes('capacity.auth_deletions_pending'), false);
});

