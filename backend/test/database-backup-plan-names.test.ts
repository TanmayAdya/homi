import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import type { Pool } from 'pg';
import { DatabaseBackupError, restoreDatabaseBackup, validateDatabaseBackup } from '../src/storage/database-backup.ts';

const origin = 'https://fictional-name-backup.supabase.co';
const owner = 'fictional-name-owner', caseId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const at = '2026-10-24T00:00:00.000Z';
const tableNames = ['repository_quota', 'cases', 'matches', 'packets', 'form_answers', 'evidence', 'program_intake',
  'assessment_metadata', 'evidence_annotations', 'exports', 'deleted_cases', 'closed_accounts',
  'account_deletion_previews', 'auth_deletion_jobs', 'request_history'];
const files = ['001_private_repository.sql', '002_retention_deletion.sql', '003_request_tracking.sql',
  '004_assessment_annotations.sql', '005_program_intake.sql', '006_plan_names.sql'];

async function fixture({ legacy = false }: { legacy?: boolean } = {}) {
  const migrations = await Promise.all(files.slice(0, legacy ? 5 : 6).map(async file => ({
    version: file.slice(0, 3), checksum: createHash('sha256')
      .update(await readFile(new URL(`../migrations/${file}`, import.meta.url))).digest('hex'),
  })));
  const snapshot = { schemaVersion: '1', caseId, revision: 1,
    profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null,
      householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
  const planName: Record<string, unknown> = { schemaVersion: '2', caseId, name: 'Fictional upstairs plan',
    nameRevision: 3, lastMutationId: 'fictional-name-backup-mutation' };
  const row: Record<string, unknown> = { case_id: caseId, owner_id: owner, revision: '1', catalog_revision: '0', snapshot,
    ...(!legacy ? { plan_name: planName } : {}) };
  const tables: Record<string, unknown[]> = Object.fromEntries(tableNames.map(name => [name, []]));
  tables.repository_quota = [{ singleton: true, case_count: '1', asset_count: '0', artifact_count: '0', stored_bytes: '0' }];
  tables.cases = [row];
  const archive = { format: 'safeathome-app-data-v1', projectOrigin: origin, capturedAt: at, migrations, tables };
  return { archive, row, planName, bytes: () => Buffer.from(JSON.stringify(archive)) };
}

test('current backup accepts case-bound names, explicit clearing and uninitialized SQL null', async () => {
  for (const mode of ['named', 'cleared', 'uninitialized']) {
    const data = await fixture();
    if (mode === 'cleared') data.planName.name = null;
    if (mode === 'uninitialized') data.row.plan_name = null;
    const before = JSON.stringify(data.archive);
    assert.equal((await validateDatabaseBackup(data.bytes(), origin)).sourceRows.cases, 1);
    assert.equal(JSON.stringify(data.archive), before);
  }
});

const malformed: Record<string, (record: Record<string, unknown>) => void> = {
  'foreign case identity': record => { record.caseId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; },
  'unrecognized owner claim': record => { record.ownerId = 'another-fictional-owner'; },
  'wrong schema': record => { record.schemaVersion = '1'; },
  'extra state field': record => { record.extra = true; },
  'missing name': record => { delete record.name; },
  'non-string name': record => { record.name = 12; },
  'oversized name': record => { record.name = 'x'.repeat(81); },
  'multiline name': record => { record.name = 'Fictional\nplan'; },
  'uninitialized stored revision': record => { record.nameRevision = 0; },
  'fractional revision': record => { record.nameRevision = 1.5; },
  'string revision': record => { record.nameRevision = '3'; },
  'unsafe revision': record => { record.nameRevision = Number.MAX_SAFE_INTEGER + 1; },
  'missing mutation': record => { delete record.lastMutationId; },
  'null mutation': record => { record.lastMutationId = null; },
  'empty mutation': record => { record.lastMutationId = ''; },
};
for (const [description, mutate] of Object.entries(malformed)) {
  test(`backup rejects ${description} before opening a restore connection`, async () => {
    const data = await fixture(); mutate(data.planName);
    await assert.rejects(validateDatabaseBackup(data.bytes(), origin), DatabaseBackupError);
    let connections = 0;
    const disconnected = { connect: async () => { connections++; throw new Error('No connection expected.'); } } as unknown as Pool;
    await assert.rejects(restoreDatabaseBackup(disconnected, data.bytes(), origin), DatabaseBackupError);
    assert.equal(connections, 0);
  });
}

test('exact five-migration legacy archive validates without modifying caller bytes', async () => {
  const data = await fixture({ legacy: true }), bytes = data.bytes(), copy = Buffer.from(bytes);
  assert.equal(Object.hasOwn(data.row, 'plan_name'), false);
  assert.equal((await validateDatabaseBackup(bytes, origin)).sourceRows.cases, 1);
  assert.deepEqual(bytes, copy);
  assert.equal(Object.hasOwn(data.row, 'plan_name'), false);
});

test('legacy normalization cannot bypass hashes or accept mixed case shapes', async () => {
  for (const corrupt of [
    (data: Awaited<ReturnType<typeof fixture>>) => { data.archive.migrations[0].checksum = '0'.repeat(64); },
    (data: Awaited<ReturnType<typeof fixture>>) => { data.archive.migrations.pop(); },
    (data: Awaited<ReturnType<typeof fixture>>) => { data.archive.migrations.reverse(); },
    (data: Awaited<ReturnType<typeof fixture>>) => { data.row.plan_name = null; },
    (data: Awaited<ReturnType<typeof fixture>>) => { data.row.plan_name = data.planName; },
  ]) {
    const data = await fixture({ legacy: true }); corrupt(data);
    await assert.rejects(validateDatabaseBackup(data.bytes(), origin), DatabaseBackupError);
  }
  const current = await fixture(); delete current.row.plan_name;
  await assert.rejects(validateDatabaseBackup(current.bytes(), origin), DatabaseBackupError);
});

test('named cases cannot bypass owner closure or case deletion markers', async () => {
  for (const deletedCase of [true, false]) {
    const data = await fixture();
    const hash = (value: string) => createHash('sha256').update(value).digest('hex');
    if (deletedCase) {
      data.archive.tables.deleted_cases = [{ case_hash: hash(caseId), owner_hash: hash(owner), revision: '1', catalog_revision: '0' }];
    } else {
      data.archive.tables.closed_accounts = [{ owner_hash: hash(owner), closed_at: at, receipt_hash: null,
        receipt_expires_at: at, auth_deleted_at: at }];
      data.archive.tables.auth_deletion_jobs = [{ job_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', owner_hash: hash(owner),
        raw_user_id: null, completed_at: at, next_attempt_at: at, lease_token: null, lease_until: null }];
    }
    await assert.rejects(validateDatabaseBackup(data.bytes(), origin), DatabaseBackupError);
  }
});
