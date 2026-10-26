import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import type { Pool } from 'pg';
import { readCapacityReport, CapacityReportError } from '../src/storage/capacity-report.ts';
import { parseCapacityArguments } from '../tool/capacity.ts';

test('capacity CLI has only a read-only default and help; never accepts mutations or private filters', () => {
  assert.equal(parseCapacityArguments([]), 'report');
  assert.equal(parseCapacityArguments(['--help']), 'help');
  for (const args of [['--apply'], ['--dry-run'], ['--case', 'fictional'], ['--database', 'postgres://fictional'],
    ['--help', '--apply'], ['--help', '--help']]) assert.throws(() => parseCapacityArguments(args));
});

test('capacity help works without configured credentials and invalid flags fail without reflecting private arguments', () => {
  const env = { ...process.env, SAFEATHOME_MIGRATION_DATABASE_URL: 'not a connection' };
  const path = new URL('../tool/capacity.ts', import.meta.url);
  const help = spawnSync(process.execPath, [path.pathname, '--help'], { env, encoding: 'utf8' });
  assert.equal(help.status, 0); assert.match(help.stdout, /read-only/); assert.equal(help.stderr, '');
  const invalid = spawnSync(process.execPath, [path.pathname, '--apply', 'PRIVATE-FICTIONAL'], { env, encoding: 'utf8' });
  assert.equal(invalid.status, 1); assert.equal(invalid.stdout, '');
  assert.equal(invalid.stderr.includes('PRIVATE-FICTIONAL'), false);
  assert.equal(invalid.stderr.includes('not a connection'), false);
});

test('connection errors are redacted before reaching the caller', async () => {
  const pool = { connect: async () => { throw new Error('PRIVATE connection credentials'); } } as unknown as Pool;
  await assert.rejects(readCapacityReport(pool), error => {
    assert.ok(error instanceof CapacityReportError); assert.equal(error.message.includes('PRIVATE'), false);
    assert.equal(error.cause, undefined); return true;
  });
});
