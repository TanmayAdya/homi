import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Pool } from 'pg';
import { OperationsReportError, readOperationsReport } from '../src/storage/operations-report.ts';

function redacted(error: unknown): boolean {
  assert.ok(error instanceof OperationsReportError);
  assert.equal(error.message.includes('PRIVATE'), false);
  assert.equal(error.cause, undefined);
  return true;
}

test('connection failures never expose operator credentials or database diagnostics', async () => {
  const pool = { connect: async () => { throw new Error('PRIVATE connection and credentials'); } } as unknown as Pool;
  await assert.rejects(readOperationsReport(pool), redacted);
});

test('failed reads roll back and discard a client whose rollback also fails', async () => {
  for (const rollbackFails of [false, true]) {
    const queries: string[] = []; const releases: boolean[] = [];
    const pool = { connect: async () => ({
      query: async (sql: string) => {
        queries.push(sql);
        if (sql.startsWith('BEGIN')) return {};
        if (sql === 'ROLLBACK' && !rollbackFails) return {};
        throw new Error('PRIVATE query detail');
      },
      release: (broken: boolean) => { releases.push(broken); },
    }) } as unknown as Pool;
    await assert.rejects(readOperationsReport(pool), redacted);
    assert.equal(queries[0], 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    assert.equal(queries.at(-1), 'ROLLBACK'); assert.equal(queries.includes('COMMIT'), false);
    assert.deepEqual(releases, [rollbackFails]);
  }
});

test('an invalid database clock cannot become a successful age-based report', async () => {
  const queries: string[] = []; let released = false;
  const pool = { connect: async () => ({
    query: async (sql: string) => {
      queries.push(sql);
      if (sql.startsWith('BEGIN') || sql === 'ROLLBACK') return {};
      return { rows: [{ captured_at: 'PRIVATE-invalid-time' }] };
    },
    release: () => { released = true; },
  }) } as unknown as Pool;
  await assert.rejects(readOperationsReport(pool), redacted);
  assert.equal(queries.at(-1), 'ROLLBACK'); assert.equal(released, true);
  assert.equal(queries.some(sql => sql.includes('auth_deletion_jobs')), false);
});
