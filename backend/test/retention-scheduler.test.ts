import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Pool } from 'pg';
import { configureRetentionSchedule, RETENTION_COMMAND, RETENTION_JOB_NAME,
  RETENTION_SCHEDULE, RetentionScheduleError } from '../src/storage/retention-scheduler.ts';
import { parseRetentionArguments } from '../tool/retention.ts';

function fake(initial: { installed?: boolean; job?: Record<string, unknown>; fail?: string } = {}) {
  let installed = initial.installed ?? false;
  let job = initial.job;
  const calls: Array<{ sql: string; values?: unknown[] }> = [];
  let released = false;
  const matching = () => ({ jobid: '12', schedule: RETENTION_SCHEDULE, command: RETENTION_COMMAND,
    active: true, own_user: true, own_database: true });
  const pool = { connect: async () => ({
    query: async (sql: string, values?: unknown[]) => {
      calls.push({ sql, values });
      if (initial.fail && sql.includes(initial.fail)) throw new Error('secret database detail');
      if (sql.includes('pg_extension')) return { rowCount: 1, rows: [{ installed }] };
      if (sql.includes('FROM cron.job WHERE')) return { rowCount: job ? 1 : 0, rows: job ? [job] : [] };
      if (sql.startsWith('CREATE EXTENSION')) installed = true;
      if (sql.startsWith('SELECT cron.schedule')) { assert.deepEqual(values, [RETENTION_JOB_NAME, RETENTION_SCHEDULE, RETENTION_COMMAND]); job = matching(); }
      if (sql.startsWith('SELECT cron.unschedule')) { assert.deepEqual(values, ['12']); job = undefined; return { rows: [{ removed: true }] }; }
      return { rows: [], rowCount: 0 };
    }, release: () => { released = true; },
  }) } as unknown as Pick<Pool, 'connect'>;
  return { pool, calls, matching, released: () => released };
}

test('retention default/status is read-only even when cron is absent', async () => {
  const f = fake();
  assert.deepEqual(await configureRetentionSchedule(f.pool), { installed: false, scheduled: false, conflict: false });
  assert.equal(f.calls.some(c => /CREATE|schedule\(|DELETE|UPDATE/.test(c.sql)), false);
  assert.equal(f.released(), true);
});
test('schedule installs only pg_cron and exact fixed bounded cleanup, then verifies', async () => {
  const f = fake();
  assert.deepEqual(await configureRetentionSchedule(f.pool, 'schedule'), { installed: true, scheduled: true, conflict: false });
  assert.ok(f.calls.some(c => c.sql.includes('pg_advisory_xact_lock')));
  const locked = f.calls.findIndex(c => c.sql === 'BEGIN ISOLATION LEVEL SERIALIZABLE');
  const scheduled = f.calls.findIndex(c => c.sql.startsWith('SELECT cron.schedule'));
  assert.ok(locked === 0 && scheduled > locked);
  assert.ok(f.calls.slice(locked + 1, scheduled).some(c => c.sql.includes('FROM cron.job WHERE')));
  assert.match(RETENTION_COMMAND, /statement_timeout = '8s'/);
  assert.match(RETENTION_COMMAND, /jobname = 'safeathome-retention-v1' AND username = current_user/);
  assert.match(RETENTION_COMMAND, /interval '7 days'/);
  assert.doesNotMatch(RETENTION_COMMAND, /https?:|net\.http/);
});
test('existing exact job is idempotent; unschedule only deletes its validated ID', async () => {
  const f = fake();
  const same = fake({ installed: true, job: f.matching() });
  await configureRetentionSchedule(same.pool, 'schedule');
  assert.equal(same.calls.some(c => c.sql.startsWith('SELECT cron.schedule')), false);
  assert.deepEqual(await configureRetentionSchedule(same.pool, 'unschedule'), { installed: true, scheduled: false, conflict: false });
  assert.equal(same.calls.some(c => c.sql.includes('DROP EXTENSION')), false);
});
test('conflicting command/schedule/owner/database/inactive job is never overwritten or removed', async () => {
  for (const change of [{ command: 'DELETE FROM other_app;' }, { schedule: '* * * * *' },
    { own_user: false }, { own_database: false }, { active: false }]) {
    for (const action of ['schedule', 'unschedule'] as const) {
      const f = fake();
      const altered = fake({ installed: true, job: { ...f.matching(), ...change } });
      await assert.rejects(configureRetentionSchedule(altered.pool, action), RetentionScheduleError);
      assert.equal(altered.calls.some(c => c.sql.startsWith('SELECT cron.')), false);
      assert.equal(altered.calls.at(-1)?.sql, 'ROLLBACK');
    }
  }
});
test('scheduler errors are sanitized and transaction/client is cleaned up', async () => {
  const rejectedPool = { connect: async () => { throw new Error('secret connection detail'); } } as unknown as Pick<Pool, 'connect'>;
  await assert.rejects(configureRetentionSchedule(rejectedPool), error => error instanceof RetentionScheduleError
    && !error.message.includes('secret'));
  const f = fake({ fail: 'cron.schedule' });
  await assert.rejects(configureRetentionSchedule(f.pool, 'schedule'), error => error instanceof RetentionScheduleError
    && !error.message.includes('secret'));
  assert.equal(f.calls.at(-1)?.sql, 'ROLLBACK'); assert.equal(f.released(), true);
});
test('CLI defaults safe and refuses custom targets, SQL, or combined actions', () => {
  assert.equal(parseRetentionArguments([]), '--dry-run');
  for (const flag of ['--help', '--dry-run', '--apply', '--schedule', '--unschedule']) assert.equal(parseRetentionArguments([flag]), flag);
  for (const args of [['--apply', '--schedule'], ['--schedule', 'custom'], ['user-id'], ['--apply=true']]) {
    assert.throws(() => parseRetentionArguments(args), TypeError);
  }
});
