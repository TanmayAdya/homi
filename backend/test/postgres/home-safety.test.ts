import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { before, beforeEach, after, test } from 'node:test';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { OWNER, OTHER, create, imageInput } from './fixtures.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { safetyRequestHash, type HomeSafetySave, type SafetyOperation } from '../../src/assessment/home-safety.ts';
import { captureDatabaseBackup, restoreDatabaseBackup } from '../../src/storage/database-backup.ts';
import { readCapacityReport } from '../../src/storage/capacity-report.ts';
import { AccountClosedError } from '../../src/lifecycle/types.ts';
import { safetyConcernAddressed } from '../../src/assessment/home-safety-report.ts';
import { caseFingerprint } from '../../src/evidence/validation.ts';

let cluster: TestPostgres, target: TestPostgres, admin: Pool, runtime: Pool, repo: PostgresCaseRepository;
const at = '2026-10-24T18:00:00.000Z';
before(async () => {
  cluster = await TestPostgres.start(); admin = cluster.pool(); await applyMigrations(admin);
  await admin.query('CREATE ROLE safety_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  runtime = cluster.pool('safety_runtime'); repo = new PostgresCaseRepository(runtime);
});
beforeEach(async () => {
  await admin.query(`TRUNCATE safeathome_private.cases, safeathome_private.deleted_cases, safeathome_private.closed_accounts,
    safeathome_private.account_deletion_previews, safeathome_private.auth_deletion_jobs CASCADE;
    UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);
});
after(async () => { await target?.close(); await cluster?.close(); });
const save = (caseId: string, operation: SafetyOperation, expectedSafetyRevision = 0, expectedCaseRevision = 1): HomeSafetySave => ({
  schemaVersion: '3', caseId, mutationId: randomUUID(), expectedSafetyRevision, expectedCaseRevision, operation });
const add: SafetyOperation = { type: 'add_room', room: { id: 'fictional-bedroom', type: 'bedroom', name: 'Fictional upstairs' } };
async function state(caseId: string) { const loaded = await repo.readHomeSafetyForUser(OWNER, caseId); assert.equal(loaded.status, 'found'); if (loaded.status !== 'found') throw Error(); return loaded.state; }

test('forced RLS hides the private column; concurrent writes and request retries preserve one history', async () => {
  const { caseId } = await create(repo); await create(repo, OTHER);
  assert.equal((await runtime.query('SELECT home_safety FROM safeathome_private.cases')).rowCount, 0);
  const requests = [save(caseId, add), save(caseId, { ...add, room: { ...add.room, id: 'competing-room' } })];
  const second = new PostgresCaseRepository(cluster.pool('safety_runtime'));
  const results = await Promise.all([repo.saveHomeSafetyForUser(OWNER, requests[0], at), second.saveHomeSafetyForUser(OWNER, requests[1], at)]);
  assert.deepEqual(results.map(r => r.status).sort(), ['found', 'safety_conflict']);
  const index = results.findIndex(r => r.status === 'found');
  assert.deepEqual(await second.saveHomeSafetyForUser(OWNER, requests[index], at), results[index]);
  assert.equal((await state(caseId)).safety.history.length, 1);
  assert.equal((await repo.readHomeSafetyForUser(OTHER, caseId)).status, 'not_found');
  assert.equal((await repo.saveHomeSafetyForUser(OTHER, save(caseId, add), at)).status, 'not_found');
});
test('plain answers preserve case outputs; explicit concern review updates the case and invalidates matches atomically', async () => {
  const snapshot = await create(repo), { caseId } = snapshot;
  await repo.saveMatchIfCurrent(OWNER, caseId, 1, { schemaVersion: '1', caseId, caseRevision: 1, evaluatedAt: at, evaluationDate: '2026-10-24', matches: [] });
  await repo.saveHomeSafetyForUser(OWNER, save(caseId, add), at);
  await repo.saveHomeSafetyForUser(OWNER, save(caseId, { type: 'answer', roomId: add.room.id, questionId: 'bedroom.path', value: 'yes' }, 1), at);
  assert.equal((await state(caseId)).case.revision, 1);
  assert.equal((await admin.query('SELECT 1 FROM safeathome_private.matches WHERE case_id=$1', [caseId])).rowCount, 1);
  await repo.saveHomeSafetyForUser(OWNER, save(caseId, { type: 'review_concern', roomId: add.room.id, questionId: 'bedroom.path',
    findingId: 'fictional-checklist-concern', observation: 'Fictional resident reports darkness on the bathroom route.', state: 'confirmed' }, 2), at);
  const saved = await state(caseId); assert.equal(saved.case.revision, 2); assert.equal(saved.case.findings.length, snapshot.findings.length + 1);
  assert.equal(saved.safety.document.findingRooms[0].findingId, 'fictional-checklist-concern');
  assert.equal((await admin.query('SELECT 1 FROM safeathome_private.matches WHERE case_id=$1', [caseId])).rowCount, 0);
  const report = await readCapacityReport(admin); assert.equal(report.quota.consistent, true); assert.ok(report.physicalStorage.relationBytes.cases > 0);
});
test('checklist edits invalidate deletion previews; case and account deletion purge rooms and reject stale access', async () => {
  const { caseId } = await create(repo);
  const tokenHash = createHash('sha256').update(randomUUID()).digest('hex');
  await repo.prepareAccountDeletion({ userId: OWNER, tokenHash });
  await repo.saveHomeSafetyForUser(OWNER, save(caseId, add), at);
  assert.deepEqual(await repo.confirmAccountDeletion({ userId: OWNER, tokenHash }), { status: 'changed' });
  assert.equal((await repo.deleteCaseIfCurrent({ userId: OWNER, caseId, revision: 1, expectedCatalogRevision: 0 })).status, 'deleted');
  assert.equal((await repo.readHomeSafetyForUser(OWNER, caseId)).status, 'not_found');
  const another = await create(repo), nextHash = createHash('sha256').update(randomUUID()).digest('hex');
  await repo.saveHomeSafetyForUser(OWNER, save(another.caseId, add), at);
  await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: nextHash });
  assert.equal((await repo.confirmAccountDeletion({ userId: OWNER, tokenHash: nextHash })).status, 'confirmed');
  await assert.rejects(repo.readHomeSafetyForUser(OWNER, another.caseId), AccountClosedError);
  assert.equal((await admin.query('SELECT home_safety FROM safeathome_private.cases')).rowCount, 0);
});
test('backup and isolated restore retain structured rooms, source versions and audit history', async () => {
  const { caseId } = await create(repo); await repo.saveHomeSafetyForUser(OWNER, save(caseId, add), at);
  await repo.saveHomeSafetyForUser(OWNER, save(caseId, { type: 'assign_finding', roomId: add.room.id, findingId: 'fictional-finding' }, 1), at);
  const before = await state(caseId);
  const report = save(caseId, { type: 'set_addressed', roomId: add.room.id, findingId: 'fictional-finding', findingFingerprint: safetyRequestHash(before.case.findings[0]), answerRevision: null, addressed: true, evidenceCatalogRevision: 0 }, 2);
  assert.equal((await repo.saveHomeSafetyForUser(OTHER, report, at)).status, 'not_found');
  assert.equal((await repo.saveHomeSafetyForUser(OWNER, report, at)).status, 'found');
  assert.equal((await repo.saveHomeSafetyForUser(OWNER, report, at)).status, 'found');
  assert.equal((await state(caseId)).safety.history.length, 3);
  assert.deepEqual((await state(caseId)).case, before.case);
  await repo.saveHomeSafetyForUser(OWNER,save(caseId,{type:'annotate_answer',roomId:add.room.id,questionId:'bedroom.path',answerRevision:0,note:'Fictional restored note',expectedCatalogRevision:0,evidence:[]},3),at);
  const expected = await state(caseId), origin = 'https://fictional-safety.supabase.co';
  const archive = await captureDatabaseBackup(admin, origin);
  target = await TestPostgres.start(); const targetAdmin = target.pool(); await applyMigrations(targetAdmin);
  await restoreDatabaseBackup(targetAdmin, archive, origin);
  await targetAdmin.query('CREATE ROLE safety_restore LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  const restored = new PostgresCaseRepository(targetAdmin);
  assert.deepEqual(await restored.readHomeSafetyForUser(OWNER, caseId), { status: 'found', state: expected });
  assert.equal((await restored.readHomeSafetyForUser(OTHER, caseId)).status, 'not_found');
});
test('review retains exactly bound original measurement units but never rebinds stale v2 metadata', async () => {
  const before = await create(repo), { revision: _, ...draft } = structuredClone(before);
  draft.findings[0].measurements = [{ type: 'clearOpening', value: 25.4, unit: 'mm', method: 'manual', confirmed: true }];
  const original = { findingId: 'fictional-finding', type: 'clearOpening', originalText: '1', originalUnit: 'in' as const,
    decimalSeparator: 'point' as const, source: 'manual' as const, recorder: 'self' as const, recordedAt: at };
  assert.equal((await repo.saveAssessmentForUser(OWNER, { schemaVersion: '2', caseId: before.caseId, expectedCaseRevision: 1,
    expectedCaseFingerprint: caseFingerprint(before), expectedCatalogRevision: 0, expectedAssessmentRevision: 0,
    mutationId: randomUUID(), draft, metadata: { measurements: [original], reviews: [{ findingId: 'fictional-finding', state: 'confirmed', note: null }] } }, at)).status, 'found');
  await repo.saveHomeSafetyForUser(OWNER, save(before.caseId, add, 0, 2), at);
  await repo.saveHomeSafetyForUser(OWNER, save(before.caseId, { type: 'answer', roomId: add.room.id, questionId: 'bedroom.path', value: 'yes' }, 1, 2), at);
  const review: SafetyOperation = { type: 'review_concern', roomId: add.room.id, questionId: 'bedroom.path', findingId: 'fictional-linked',
    observation: 'Fictional bedroom route concern.', state: 'needs_review' };
  assert.equal((await repo.saveHomeSafetyForUser(OWNER, save(before.caseId, review, 2, 2), at)).status, 'found');
  const assessment = await repo.readAssessmentForUser(OWNER, before.caseId); assert.equal(assessment.status, 'found');
  if (assessment.status !== 'found') throw Error();
  assert.equal(assessment.state.case.revision, 3); assert.equal(assessment.state.assessment.caseRevision, 3);
  assert.deepEqual(assessment.state.assessment.metadata.measurements, [original]); assert.equal(assessment.state.assessment.history.length, 2);
  const { revision: __, ...sameDraft } = assessment.state.case;
  assert.equal((await repo.replaceIfCurrent(OWNER, before.caseId, 3, sameDraft)).status, 'saved');
  await repo.saveHomeSafetyForUser(OWNER, save(before.caseId, { ...review, state: 'confirmed' }, 3, 4), at);
  const stale = await repo.readAssessmentForUser(OWNER, before.caseId); assert.equal(stale.status, 'found');
  if (stale.status !== 'found') throw Error();
  assert.equal(stale.state.case.revision, 5); assert.equal(stale.state.assessment.caseRevision, 3);
  assert.equal(stale.state.assessment.history.length, 2);
});

test('question evidence references and addressed reports bind active photo revisions under the owned case lock', async () => {
  const before = await create(repo), {caseId}=before;
  const photo=await repo.saveEvidenceIfCurrent(await imageInput(before));assert.equal(photo.status,'saved');
  await repo.saveHomeSafetyForUser(OWNER, save(caseId,add),at);
  await repo.saveHomeSafetyForUser(OWNER, save(caseId,{type:'assign_finding',roomId:add.room.id,findingId:'fictional-finding'},1),at);
  const note: SafetyOperation={type:'annotate_answer',roomId:add.room.id,questionId:'bedroom.path',answerRevision:0,note:'Fictional note with photo',expectedCatalogRevision:1,evidence:[{evidenceId:'fictional-photo-a',expectedEvidenceRevision:1}]};
  assert.equal((await repo.saveHomeSafetyForUser(OWNER,save(caseId,note,2),at)).status,'found');
  const report:SafetyOperation={type:'set_addressed',roomId:add.room.id,findingId:'fictional-finding',findingFingerprint:safetyRequestHash(before.findings[0]),answerRevision:null,addressed:true,evidenceCatalogRevision:1};
  assert.equal((await repo.saveHomeSafetyForUser(OWNER,save(caseId,report,3),at)).status,'found');
  let current=await state(caseId);assert.equal(safetyConcernAddressed(current,current.safety.document.findingRooms[0]),true);
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(before,1,'fictional-photo-a',1))).status,'saved');
  current=await state(caseId);assert.equal(current.evidenceCatalogRevision,2);assert.equal(safetyConcernAddressed(current,current.safety.document.findingRooms[0]),false);
  assert.equal((await repo.saveHomeSafetyForUser(OWNER,save(caseId,note,4),at)).status,'evidence_conflict');
  assert.equal((await repo.saveHomeSafetyForUser(OWNER,save(caseId,report,4),at)).status,'invalid_operation');
  assert.equal((await state(caseId)).safety.history.length,4);
});
