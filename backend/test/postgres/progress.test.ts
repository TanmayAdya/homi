import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { before, beforeEach, after, test } from 'node:test';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { OWNER, OTHER, create } from './fixtures.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import type { ProgressSave, NextStepTask } from '../../src/tracking/progress.ts';
import { captureDatabaseBackup, restoreDatabaseBackup } from '../../src/storage/database-backup.ts';
let cluster: TestPostgres, target: TestPostgres, admin: Pool, runtime: Pool, repo: PostgresCaseRepository;
const at = '2026-10-24T18:00:00.000Z';
before(async () => { cluster = await TestPostgres.start(); admin = cluster.pool(); await applyMigrations(admin); await admin.query('CREATE ROLE progress_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app'); runtime = cluster.pool('progress_runtime'); repo = new PostgresCaseRepository(runtime); });
beforeEach(async () => { await admin.query(`TRUNCATE safeathome_private.cases, safeathome_private.deleted_cases, safeathome_private.closed_accounts, safeathome_private.account_deletion_previews, safeathome_private.auth_deletion_jobs CASCADE; UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`); });
after(async () => { await target?.close(); await cluster?.close(); });
function request(caseId: string): ProgressSave {
  const task: NextStepTask = { id: randomUUID(), programId: null, findingId: null, formId: null, title: 'Fictional agency call', kind: 'contact', state: 'pending', responsiblePerson: null, dueOn: '2026-11-01', basedOnCaseRevision: 1, basedOnRuleVersion: null, revision: 1, sourceEventId: null };
  return { schemaVersion: '3', caseId, expectedCaseRevision: 1, expectedProgressRevision: 0, mutationId: randomUUID(), operation: { type: 'put_task', expectedTaskRevision: 0, task } };
}
test('real forced RLS, simultaneous writes, idempotent retries, and case ownership', async () => {
  const { caseId } = await create(repo), a = request(caseId), b = request(caseId);
  assert.equal((await runtime.query('SELECT progress FROM safeathome_private.cases')).rowCount, 0);
  const results = await Promise.all([repo.saveProgressForUser(OWNER, a, at, []), repo.saveProgressForUser(OWNER, b, at, [])]);
  assert.deepEqual(results.map(r => r.status).sort(), ['found', 'progress_conflict']);
  const winner = results.findIndex(r => r.status === 'found');
  assert.deepEqual(await repo.saveProgressForUser(OWNER, [a,b][winner], at, []), results[winner]);
  assert.equal((await repo.readProgressForUser(OTHER, caseId)).status, 'not_found');
  assert.equal((await repo.saveProgressForUser(OTHER, a, at, [])).status, 'not_found');
});
test('progress edits invalidate deletion previews; delete-case purges progress with the case', async () => {
  const { caseId } = await create(repo), tokenHash = createHash('sha256').update(randomUUID()).digest('hex');
  await repo.prepareAccountDeletion({ userId: OWNER, tokenHash });
  await repo.saveProgressForUser(OWNER, request(caseId), at, []);
  assert.deepEqual(await repo.confirmAccountDeletion({ userId: OWNER, tokenHash }), { status: 'changed' });
  assert.equal((await repo.deleteCaseIfCurrent({ userId: OWNER, caseId, revision: 1, expectedCatalogRevision: 0 })).status, 'deleted');
  assert.equal((await repo.readProgressForUser(OWNER, caseId)).status, 'not_found');
});
test('backup and isolated restore retain tasks and append-only history', async () => {
  const { caseId } = await create(repo); await repo.saveProgressForUser(OWNER, request(caseId), at, []);
  const expected = await repo.readProgressForUser(OWNER, caseId), origin = 'https://fictional-progress.supabase.co';
  const archive = await captureDatabaseBackup(admin, origin);
  target = await TestPostgres.start(); const targetAdmin = target.pool(); await applyMigrations(targetAdmin); await restoreDatabaseBackup(targetAdmin, archive, origin);
  await targetAdmin.query('CREATE ROLE progress_restore LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  const restored = new PostgresCaseRepository(targetAdmin);
  assert.deepEqual(await restored.readProgressForUser(OWNER, caseId), expected);
});
