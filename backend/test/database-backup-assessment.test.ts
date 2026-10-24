import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import type { Pool } from 'pg';
import { appendAssessment, emptyAssessment, type AssessmentMetadata, type AssessmentRecord } from '../src/assessment/metadata.ts';
import { caseFingerprint } from '../src/evidence/validation.ts';
import { DatabaseBackupError, restoreDatabaseBackup, validateDatabaseBackup } from '../src/storage/database-backup.ts';
import type { CaseSnapshot } from '../src/types.ts';

const origin = 'https://fictional-backup.supabase.co', owner = 'fictional-backup-owner';
const caseId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', at = '2026-10-22T00:00:00.000Z';
const names = ['repository_quota', 'cases', 'matches', 'packets', 'form_answers', 'evidence', 'program_intake',
  'assessment_metadata', 'evidence_annotations', 'exports', 'deleted_cases', 'closed_accounts',
  'account_deletion_previews', 'auth_deletion_jobs', 'request_history'];
const manifest = Promise.all(['001_private_repository.sql', '002_retention_deletion.sql', '003_request_tracking.sql',
  '004_assessment_annotations.sql', '005_program_intake.sql'].map(async file => ({ version: file.slice(0, 3),
    checksum: createHash('sha256').update(await readFile(new URL(`../migrations/${file}`, import.meta.url))).digest('hex') })));

async function fixture() {
  const before: CaseSnapshot = { schemaVersion: '1', caseId, revision: 1,
    profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null,
      householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
  const snapshot: CaseSnapshot = { ...before, revision: 2, findings: [{ id: 'fictional-finding', room: 'entrance',
    observation: 'Fictional measurement fixture.', reviewState: 'confirmed', evidenceIds: [],
    measurements: [{ type: 'thresholdHeight', value: 12.7, unit: 'mm', method: 'manual', confirmed: true }] }] };
  const metadata: AssessmentMetadata = { measurements: [{ findingId: 'fictional-finding', type: 'thresholdHeight',
    originalText: ' .5 ', originalUnit: 'in', decimalSeparator: 'point', source: 'manual', recorder: 'self', recordedAt: null }],
    reviews: [{ findingId: 'fictional-finding', state: 'confirmed', note: 'Fictional review.' }] };
  const { revision: _revision, ...draft } = snapshot;
  const record = appendAssessment(emptyAssessment(before), before, { schemaVersion: '2', caseId,
    expectedCaseRevision: 1, expectedCaseFingerprint: caseFingerprint(before), expectedCatalogRevision: 0,
    expectedAssessmentRevision: 0, mutationId: 'fictional-backup-assessment', draft, metadata }, owner, at)!;
  const tables: Record<string, unknown[]> = Object.fromEntries(names.map(name => [name, []]));
  tables.repository_quota = [{ singleton: true, case_count: '1', asset_count: '0', artifact_count: '0', stored_bytes: '0' }];
  tables.cases = [{ case_id: caseId, owner_id: owner, revision: '2', catalog_revision: '0', snapshot }];
  tables.assessment_metadata = [{ case_id: caseId, record }];
  const archive = { format: 'safeathome-app-data-v1', projectOrigin: origin, capturedAt: at, migrations: await manifest, tables };
  return { record, snapshot, metadata: record.metadata, archive, bytes: () => Buffer.from(JSON.stringify(archive)) };
}

test('current assessment original units and review provenance validate against the canonical case', async () => {
  const data = await fixture(), original = JSON.stringify(data.archive);
  const result = await validateDatabaseBackup(data.bytes(), origin);
  assert.equal(result.sourceRows.assessment_metadata, 1);
  assert.equal(data.record.caseRevision, data.snapshot.revision);
  assert.equal(data.metadata.measurements[0].originalText, ' .5 ');
  assert.equal(JSON.stringify(data.archive), original);
});

const invalidCurrent: Record<string, (record: AssessmentRecord) => void> = {
  'original numeric value': record => { record.metadata.measurements[0].originalText = '99'; },
  'original unit': record => { record.metadata.measurements[0].originalUnit = 'cm'; },
  'measurement method': record => { record.metadata.measurements[0].source = 'estimated'; },
  'missing measurement': record => { record.metadata.measurements = []; },
  'orphan measurement': record => { record.metadata.measurements[0].findingId = 'unknown-finding'; },
  'wrong measurement type': record => { record.metadata.measurements[0].type = 'unknown-measurement'; },
  'missing review': record => { record.metadata.reviews = []; },
  'orphan review': record => { record.metadata.reviews[0].findingId = 'unknown-finding'; },
  'review state mismatch': record => { record.metadata.reviews[0].state = 'needs_review'; },
};
for (const [name, corrupt] of Object.entries(invalidCurrent)) {
  test(`current backup rejects ${name} before opening a restore connection`, async () => {
    const data = await fixture(); corrupt(data.record);
    await assert.rejects(validateDatabaseBackup(data.bytes(), origin), DatabaseBackupError);
    let connections = 0;
    const neverConnect = { connect: async () => { connections++; throw new Error('No restore connection expected.'); } } as unknown as Pool;
    await assert.rejects(restoreDatabaseBackup(neverConnect, data.bytes(), origin), DatabaseBackupError);
    assert.equal(connections, 0);
  });
}

test('older sidecar remains valid after a v1 measurement or finding change', async () => {
  for (const removeFinding of [false, true]) {
    const data = await fixture(); data.snapshot.revision = 3;
    (data.archive.tables.cases[0] as { revision: string }).revision = '3';
    if (removeFinding) data.snapshot.findings = [];
    else { data.snapshot.findings[0].measurements[0].value = 25.4; data.snapshot.findings[0].reviewState = 'dismissed'; }
    const prior = structuredClone(data.record);
    assert.equal((await validateDatabaseBackup(data.bytes(), origin)).sourceRows.assessment_metadata, 1);
    assert.deepEqual(data.record, prior); assert.equal(data.record.caseRevision, 2);
  }
});

test('older sidecar still requires valid structure and owner provenance', async () => {
  for (const corrupt of [
    (record: AssessmentRecord) => { record.metadata.measurements[0].originalText = 'not a number'; },
    (record: AssessmentRecord) => { record.history[0].recordedBy = 'another-fictional-owner'; },
  ]) {
    const data = await fixture(); data.snapshot.revision = 3;
    (data.archive.tables.cases[0] as { revision: string }).revision = '3'; corrupt(data.record);
    await assert.rejects(validateDatabaseBackup(data.bytes(), origin), DatabaseBackupError);
  }
});
