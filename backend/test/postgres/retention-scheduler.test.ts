import assert from 'node:assert/strict';
import { after, before, beforeEach, test } from 'node:test';
import type { Pool } from 'pg';
import { configureRetentionSchedule, RETENTION_COMMAND, RETENTION_JOB_NAME,
  RETENTION_SCHEDULE, RetentionScheduleError } from '../../src/storage/retention-scheduler.ts';
import { TestPostgres } from './harness.ts';

let cluster: TestPostgres;
let admin: Pool;
let operator: Pool;
const operatorName = 'retention_operator';
const otherJobName = 'unrelated-application-job';

before(async () => {
  cluster = await TestPostgres.start();
  admin = cluster.pool();
  await admin.query(`
    CREATE ROLE retention_operator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    CREATE SCHEMA cron;
    CREATE TABLE cron.job (
      jobid bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      jobname text NOT NULL, schedule text NOT NULL, command text NOT NULL,
      active boolean NOT NULL DEFAULT true, username text NOT NULL, database text NOT NULL,
      UNIQUE (jobname, username)
    );
    CREATE FUNCTION cron.schedule(p_name text, p_schedule text, p_command text)
      RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
      DECLARE result bigint;
      BEGIN
        INSERT INTO cron.job (jobname,schedule,command,username,database)
          VALUES (p_name,p_schedule,p_command,session_user,current_database())
          ON CONFLICT (jobname,username) DO UPDATE SET
            schedule=EXCLUDED.schedule,command=EXCLUDED.command,active=true
          RETURNING jobid INTO result;
        RETURN result;
      END $$;
    CREATE FUNCTION cron.unschedule(p_id bigint)
      RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
      BEGIN
        DELETE FROM cron.job WHERE jobid=p_id AND username=session_user;
        RETURN FOUND;
      END $$;
    REVOKE ALL ON FUNCTION cron.schedule(text,text,text), cron.unschedule(bigint) FROM PUBLIC;
    GRANT USAGE ON SCHEMA cron TO retention_operator;
    GRANT SELECT ON cron.job TO retention_operator;
    GRANT EXECUTE ON FUNCTION cron.schedule(text,text,text), cron.unschedule(bigint) TO retention_operator;
  `);
  operator = cluster.pool(operatorName, 'safeathome-retention-isolation-test');
});
beforeEach(async () => {
  await admin.query('TRUNCATE cron.job RESTART IDENTITY');
  await admin.query(`INSERT INTO cron.job(jobname,schedule,command,username,database)
    VALUES ($1,'0 2 * * *','SELECT 42',$2,current_database())`, [otherJobName, operatorName]);
});
after(async () => { await cluster?.close(); });

function schedulerPool(afterFirstJobRead?: () => Promise<void>) {
  const sqlStates: string[] = [];
  let jobRead = false;
  let managementCalls = 0;
  const pool = { connect: async () => {
    const client = await operator.connect();
    return {
      release: (broken?: boolean) => client.release(broken),
      query: async (sql: string, values?: unknown[]) => {
        if (sql.includes("FROM pg_extension WHERE extname='pg_cron'")) {
          return { rows: [{ installed: true }], rowCount: 1 };
        }
        if (sql.startsWith('SELECT cron.schedule(') || sql.startsWith('SELECT cron.unschedule(')) managementCalls++;
        let result;
        try { result = await client.query(sql, values); }
        catch (error) {
          if (error !== null && typeof error === 'object' && 'code' in error && typeof error.code === 'string') sqlStates.push(error.code);
          throw error;
        }
        if (sql.includes('FROM cron.job WHERE jobname=$1') && !jobRead) {
          jobRead = true;
          await afterFirstJobRead?.();
        }
        return result;
      },
    };
  } } as unknown as Pick<Pool, 'connect'>;
  return { pool, sqlStates, managementCalls: () => managementCalls };
}

async function rows() {
  return (await admin.query('SELECT * FROM cron.job ORDER BY jobid')).rows;
}
async function insertOwnedJob(command = RETENTION_COMMAND, schedule = RETENTION_SCHEDULE) {
  await admin.query(`INSERT INTO cron.job(jobname,schedule,command,username,database)
    VALUES ($1,$2,$3,$4,current_database())`, [RETENTION_JOB_NAME, schedule, command, operatorName]);
}

test('SELECT-only operator can schedule and remove the exact job without table-lock privileges', async () => {
  assert.equal((await admin.query("SELECT count(*) AS count FROM pg_extension WHERE extname='pg_cron'")).rows[0].count, '0');
  const client = await operator.connect();
  try {
    await client.query('BEGIN');
    await assert.rejects(client.query('LOCK TABLE cron.job IN SHARE ROW EXCLUSIVE MODE'), { code: '42501' });
    await client.query('ROLLBACK');
    await assert.rejects(client.query("UPDATE cron.job SET command='unavailable'"), { code: '42501' });
  } finally { client.release(); }
  const unrelated = (await rows())[0];
  const configured = schedulerPool();
  assert.deepEqual(await configureRetentionSchedule(configured.pool, 'schedule'), {
    installed: true, scheduled: true, conflict: false,
  });
  assert.equal(configured.managementCalls(), 1);
  const all = await rows();
  assert.deepEqual(all[0], unrelated);
  assert.equal(all[1].command, RETENTION_COMMAND);
  assert.equal(all[1].username, operatorName);
  const repeat = schedulerPool();
  await configureRetentionSchedule(repeat.pool, 'schedule');
  assert.equal(repeat.managementCalls(), 0);
  assert.deepEqual(await configureRetentionSchedule(schedulerPool().pool, 'unschedule'), {
    installed: true, scheduled: false, conflict: false,
  });
  assert.deepEqual(await rows(), [unrelated]);
});

test('concurrent external same-name insertion is preserved when scheduling aborts', async () => {
  const unrelated = (await rows())[0];
  let externalRows: Awaited<ReturnType<typeof rows>> = [];
  const f = schedulerPool(async () => {
    await insertOwnedJob('SELECT 9001', '* * * * *');
    externalRows = await rows();
  });
  await assert.rejects(configureRetentionSchedule(f.pool, 'schedule'), RetentionScheduleError);
  assert.deepEqual(f.sqlStates, ['40001']);
  assert.equal(f.managementCalls(), 1);
  assert.deepEqual(await rows(), externalRows);
  assert.deepEqual((await rows())[0], unrelated);
});

test('concurrent external modification is preserved when unscheduling aborts', async () => {
  await insertOwnedJob();
  let externalRows: Awaited<ReturnType<typeof rows>> = [];
  const f = schedulerPool(async () => {
    await admin.query('UPDATE cron.job SET command=$1,active=false WHERE jobname=$2', ['SELECT 9002', RETENTION_JOB_NAME]);
    externalRows = await rows();
  });
  await assert.rejects(configureRetentionSchedule(f.pool, 'unschedule'), RetentionScheduleError);
  assert.deepEqual(f.sqlStates, ['40001']);
  assert.equal(f.managementCalls(), 1);
  assert.deepEqual(await rows(), externalRows);
});

test('existing conflicting job is not changed by either requested mutation', async () => {
  await insertOwnedJob('SELECT 9003');
  const original = await rows();
  for (const action of ['schedule', 'unschedule'] as const) {
    const f = schedulerPool();
    await assert.rejects(configureRetentionSchedule(f.pool, action), RetentionScheduleError);
    assert.equal(f.managementCalls(), 0);
    assert.deepEqual(await rows(), original);
  }
});
