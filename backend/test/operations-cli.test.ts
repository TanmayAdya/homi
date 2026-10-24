import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { parseOperationsArguments, summarizeOperationsWarnings } from '../tool/operations.ts';

test('operations accepts only a read-only default or help, never mutations, paths or private filters', () => {
  assert.equal(parseOperationsArguments([]), 'report');
  assert.equal(parseOperationsArguments(['--help']), 'help');
  for (const args of [['--apply'], ['--schedule'], ['--delete-user', 'fictional'], ['--output', '/tmp/report'],
    ['--database', 'postgres://fictional'], ['--help', '--help'], ['--help', '--apply']]) {
    assert.throws(() => parseOperationsArguments(args));
  }
});

test('any monitored warning requires attention; no warning makes only a scoped claim', () => {
  assert.deepEqual(summarizeOperationsWarnings([], []), {
    status: 'no_monitored_warning', exitCode: 0, warnings: [],
  });
  assert.deepEqual(summarizeOperationsWarnings(['cases_near_limit'], ['retention_success_stale']), {
    status: 'attention_required', exitCode: 2,
    warnings: ['capacity.cases_near_limit', 'lifecycle.retention_success_stale'],
  });
  assert.equal(summarizeOperationsWarnings([], ['auth_deletions_pending']).exitCode, 2);
  assert.equal(summarizeOperationsWarnings(['expired_pdf_payloads_pending_retention'], []).exitCode, 2);
  assert.deepEqual(summarizeOperationsWarnings(['quota_mismatch', 'quota_mismatch'], ['quota_mismatch']).warnings,
    ['capacity.quota_mismatch', 'lifecycle.quota_mismatch']);
});

test('help works without credentials; invalid configuration or arguments fail without leaking input', () => {
  const env = { ...process.env, SAFEATHOME_MIGRATION_DATABASE_URL: 'PRIVATE-FICTIONAL-CONNECTION' };
  const path = new URL('../tool/operations.ts', import.meta.url).pathname;
  const help = spawnSync(process.execPath, [path, '--help'], { env, encoding: 'utf8' });
  assert.equal(help.status, 0); assert.match(help.stdout, /read-only/); assert.match(help.stdout, /exit 2/);
  assert.equal(help.stderr, ''); assert.equal(help.stdout.includes('PRIVATE-FICTIONAL'), false);
  for (const args of [[], ['--apply', 'PRIVATE-FICTIONAL-ID'], ['--help', 'PRIVATE-FICTIONAL-ID']]) {
    const failed = spawnSync(process.execPath, [path, ...args], { env, encoding: 'utf8' });
    assert.equal(failed.status, 1); assert.equal(failed.stdout, '');
    assert.match(failed.stderr, /Operations check failed/);
    assert.equal(failed.stderr.includes('PRIVATE-FICTIONAL'), false);
  }
});
