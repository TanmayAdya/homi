import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import type { AddressInfo } from 'node:net';
import test from 'node:test';
import { PDFDocument } from 'pdf-lib';
import { TestPostgres } from './harness.ts';
import { OWNER, draft } from './fixtures.ts';
import { demoProgram } from '../../fixtures/demo-program.ts';
import { createMatchingServer } from '../../src/api/http-server.ts';
import { safetyRequestHash, type SafetyOperation } from '../../src/assessment/home-safety.ts';
import { safetyConcernAddressed } from '../../src/assessment/home-safety-report.ts';
import { canonicalJson } from '../../src/evidence/validation.ts';
import { PostgresSharingRepository } from '../../src/sharing/postgres-sharing-repository.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { captureDatabaseBackup, restoreDatabaseBackup } from '../../src/storage/database-backup.ts';
import type { NextStepTask, ProgressOperation } from '../../src/tracking/progress.ts';

const VIEWER = '22222222-2222-4222-8222-222222222222';
const HELPER = '33333333-3333-4333-8333-333333333333';
const OTHER = '44444444-4444-4444-8444-444444444444';
const roleSql = 'LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app';

test('Phase 5: one durable HTTP journey connects rooms, two programs, referral import, helper review, restart, quarantine and deletion', async t => {
  const cluster = await TestPostgres.start();
  t.after(() => cluster.close());
  const admin = cluster.pool();
  await applyMigrations(admin);
  await admin.query(`CREATE ROLE phase5_runtime ${roleSql}`);
  const pool = cluster.pool('phase5_runtime');
  const registry = [
    { ...demoProgram, recheckAfter: null },
    { ...demoProgram, programId: 'demo-second-route', programName: 'Second fictional route', recheckAfter: null },
  ];
  const authenticate = async (token: string) => [OWNER, VIEWER, HELPER, OTHER].includes(token) ? { userId: token } : null;
  let server: ReturnType<typeof createMatchingServer>;
  let origin = '';
  async function start(enabled = true) {
    const cases = new PostgresCaseRepository(pool);
    const deps = { cases, authenticate, loadRegistry: async () => registry, now: () => new Date(), allowDemoPrograms: true };
    server = createMatchingServer(deps, deps, undefined, undefined, deps, undefined, enabled ? {
      homeSafetyDependencies: deps,
      progressDependencies: deps,
      sharingDependencies: { authenticate, sharing: new PostgresSharingRepository(pool, async () => registry), collaborationEnabled: true },
      lifecycleDependencies: { authenticate, authenticateForDeletion: authenticate, lifecycle: cases },
    } : {});
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  }
  async function stop() {
    server.closeAllConnections();
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  }
  await start();
  t.after(stop);
  async function post(route: string, body: unknown, actor = OWNER, expected = 200): Promise<any> {
    const response = await fetch(origin + route, { method: 'POST', headers: {
      Authorization: `Bearer ${actor}`, 'Content-Type': 'application/json',
    }, body: JSON.stringify(body) });
    const result = await response.json();
    assert.equal(response.status, expected, `${route}: ${JSON.stringify(result)}`);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    return result;
  }
  const initial = await post('/v1/create-case', draft());
  const caseId = initial.caseId;
  const readSafety = () => post('/v3/read-home-safety', { schemaVersion: '3', caseId });
  const readProgress = () => post('/v3/read-progress', { schemaVersion: '3', caseId, includeReferrals: true,
    offset: 0, limit: 20, expectedProgressRevision: null, expectedCaseRevision: null, expectedHistoryVersion: null });
  let safety = await readSafety();
  async function saveSafety(operation: SafetyOperation) {
    safety = await post('/v3/save-home-safety', { schemaVersion: '3', caseId,
      expectedCaseRevision: safety.case.revision, expectedSafetyRevision: safety.safety.revision,
      mutationId: randomUUID(), operation });
  }
  await saveSafety({ type: 'add_room', room: { id: 'bedroom-main', type: 'bedroom', name: 'Fictional main bedroom' } });
  await saveSafety({ type: 'add_room', room: { id: 'bedroom-guest', type: 'bedroom', name: 'Fictional guest bedroom' } });
  await saveSafety({ type: 'answer', roomId: 'bedroom-guest', questionId: 'bedroom.path', value: 'not_sure' });
  assert.equal(safety.case.findings.length, initial.findings.length, 'An uncertain answer does not create a finding');
  const matchRequest = { schemaVersion: '1', caseId, expectedCaseRevision: 1 };
  await post('/v1/match-case', matchRequest);
  const packetRequest = { ...matchRequest, programId: registry[0].programId, generationKey: randomUUID() };
  const oldPacket = await post('/v1/prepare-packet', packetRequest);
  await saveSafety({ type: 'answer', roomId: 'bedroom-main', questionId: 'bedroom.path', value: 'yes' });
  await saveSafety({ type: 'review_concern', roomId: 'bedroom-main', questionId: 'bedroom.path',
    findingId: 'night-route', observation: 'Fictional resident reports a dark route.', state: 'confirmed' });
  assert.equal(safety.case.revision, 2);
  await post('/v1/match-case', matchRequest, OWNER, 409);
  await post('/v1/prepare-packet', packetRequest, OWNER, 409);
  const matches = await post('/v1/match-case', { ...matchRequest, expectedCaseRevision: 2 });
  assert.equal(matches.matches.length, 2);
  const freshPacket = await post('/v1/prepare-packet', { ...packetRequest, expectedCaseRevision: 2, generationKey: randomUUID() });
  assert.notEqual(freshPacket.packetId, oldPacket.packetId);
  assert.equal(freshPacket.caseRevision, 2);

  let progress = await readProgress();
  async function saveProgress(operation: ProgressOperation) {
    const request = { schemaVersion: '3', caseId, includeReferrals: true,
      expectedCaseRevision: safety.case.revision, expectedProgressRevision: progress.revision, mutationId: randomUUID(), operation };
    progress = await post('/v3/save-progress', request);
    return request;
  }
  for (const program of registry) await saveProgress({ type: 'track_program', programId: program.programId });
  const task: NextStepTask = { id: 'lighting-task', programId: registry[0].programId, findingId: 'night-route', formId: null,
    title: 'Fictional lighting follow-up', kind: 'room_review', state: 'pending', responsiblePerson: null,
    dueOn: null, basedOnCaseRevision: 2, basedOnRuleVersion: registry[0].ruleVersion, revision: 1, sourceEventId: null };
  await saveProgress({ type: 'put_task', expectedTaskRevision: 0, task });
  const original = { id: 'local-referral-one', providerId: 'referral-211-national', title: 'Fictional referral follow-up',
    responsible: 'Fictional resident', dueDate: null, findingId: null, createdAt: new Date().toISOString(), completedAt: null };
  const referral: NextStepTask = { ...task, id: 'referral-task', programId: null, findingId: null, basedOnRuleVersion: null,
    title: original.title, kind: 'contact', referral: { providerId: original.providerId, imported: {
      sourceTaskId: original.id, sourceHash: createHash('sha256').update(canonicalJson(original)).digest('hex'), original,
      contactNote: 'Fictional PRIVATE contact note',
    } } };
  const importedRequest = await saveProgress({ type: 'put_task', expectedTaskRevision: 0, task: referral });
  await post('/v3/save-progress', importedRequest);
  progress = await readProgress();
  assert.equal(progress.tasks.length, 2);
  assert.equal(progress.programs.length, 2);

  async function invite(recipientId: string, role: 'viewer' | 'helper') {
    const created = await post('/v3/create-invitation', { schemaVersion: '3', caseId, expectedCaseRevision: 2,
      invitationId: randomUUID(), recipientId, role, scope: { findingIds: ['night-route'],
        programIds: [registry[0].programId], allowHelperNotes: false }, expiresAt: null });
    await post('/v3/review-invitation', { schemaVersion: '3', code: created.invitationCode }, OTHER, 404);
    return post('/v3/accept-invitation', { schemaVersion: '3', code: created.invitationCode,
      expectedPermissionRevision: 1 }, recipientId);
  }
  const viewer = await invite(VIEWER, 'viewer'), helper = await invite(HELPER, 'helper');
  const projection = await post('/v3/read-shared-case', { schemaVersion: '3', membershipId: viewer.membership.membershipId,
    expectedPermissionRevision: 2 }, VIEWER);
  assert.equal(projection.projection.programs.length, 1);
  assert.equal(projection.projection.findings.length, 1);
  assert.ok(!JSON.stringify(projection).includes('PRIVATE contact note'));
  await post('/v3/read-home-safety', { schemaVersion: '3', caseId }, VIEWER, 404);
  await post('/v3/export-home-safety', { schemaVersion: '3', caseId, expectedCaseRevision: 2,
    expectedSafetyRevision: safety.safety.revision, expectedCatalogRevision: 0, includeNotes: false,
    includeEvidenceReferences: false }, VIEWER, 404);
  const configured = await post('/v3/configure-collaboration', { schemaVersion: '3', membershipId: helper.membership.membershipId,
    expectedPermissionRevision: 2, expectedCaseRevision: 2, expectedProgressRevision: progress.revision,
    expectedCollaborationRevision: 0, mutationId: randomUUID(), collaborationScope: {
      taskIds: [task.id], allowTaskProgress: true, allowStatusProposals: true }, assignedTaskIds: [task.id] });
  const completed = await post('/v3/update-shared-task', { schemaVersion: '3', membershipId: helper.membership.membershipId,
    expectedPermissionRevision: 3, expectedCaseRevision: 2, expectedCollaborationRevision: configured.collaborationRevision,
    mutationId: randomUUID(), taskId: task.id, expectedTaskRevision: 1, state: 'completed' }, HELPER);
  safety = await readSafety();
  const link = safety.safety.document.findingRooms.find((l: any) => l.findingId === 'night-route');
  assert.equal(safetyConcernAddressed(safety, link), false, 'Completing a task is not a repair report');
  const proposalId = randomUUID();
  const proposed = await post('/v3/propose-shared-status', { schemaVersion: '3', membershipId: helper.membership.membershipId,
    expectedPermissionRevision: 3, expectedCaseRevision: 2, expectedCollaborationRevision: completed.collaborationRevision,
    mutationId: proposalId, programId: registry[0].programId, update: { updateId: randomUUID(), status: 'submitted',
      occurredOn: new Date().toISOString().slice(0, 10), source: 'self_report', note: 'Fictional proposal only',
      nextAction: null, responsibleParty: null, followUpOn: null } }, HELPER);
  progress = await readProgress();
  const revisionBeforeReview = progress.revision;
  assert.equal(revisionBeforeReview, completed.progressRevision, 'An unreviewed proposal cannot update canonical history');
  await post('/v3/review-shared-status', { schemaVersion: '3', membershipId: helper.membership.membershipId,
    expectedPermissionRevision: 3, expectedCaseRevision: 2, expectedCollaborationRevision: proposed.collaborationRevision,
    expectedProgressRevision: progress.revision, mutationId: randomUUID(), proposalId, decision: 'accepted' });
  progress = await readProgress();
  assert.equal(progress.revision, revisionBeforeReview + 1);
  await saveSafety({ type: 'set_addressed', roomId: 'bedroom-main', findingId: 'night-route',
    findingFingerprint: safetyRequestHash(safety.case.findings.find((f: any) => f.id === 'night-route')),
    answerRevision: link.answerRevision, addressed: true });
  assert.equal(safetyConcernAddressed(safety, link), true);
  const reportRequest = { schemaVersion: '3', caseId, expectedCaseRevision: 2, expectedSafetyRevision: safety.safety.revision,
    expectedCatalogRevision: 0, includeNotes: false, includeEvidenceReferences: false };
  const report = await post('/v3/export-home-safety', reportRequest);
  const bytes = Buffer.from(report.pdfBase64, 'base64');
  assert.equal(createHash('sha256').update(bytes).digest('hex'), report.sha256);
  assert.equal((await PDFDocument.load(bytes)).getPageCount(), report.pageCount);

  const savedSafety = await readSafety(), savedProgress = await readProgress();
  await stop();
  await start(false);
  await post('/v3/read-home-safety', { schemaVersion: '3', caseId }, OWNER, 404);
  await post('/v3/read-progress', {}, OWNER, 404);
  await post('/v3/list-shared-cases', { schemaVersion: '3' }, VIEWER, 404);
  await stop();
  await start();
  assert.deepEqual(await readSafety(), savedSafety);
  assert.deepEqual(await readProgress(), savedProgress);
  assert.equal((await pool.query('SELECT home_safety, progress, collaboration FROM safeathome_private.cases')).rowCount, 0);

  const archiveOrigin = 'https://fictional-phase5.supabase.co';
  const archive = await captureDatabaseBackup(admin, archiveOrigin);
  const target = await TestPostgres.start();
  t.after(() => target.close());
  const targetAdmin = target.pool();
  await applyMigrations(targetAdmin);
  await restoreDatabaseBackup(targetAdmin, archive, archiveOrigin);
  await targetAdmin.query(`CREATE ROLE phase5_restore ${roleSql}`);
  const restoredPool = targetAdmin, restored = new PostgresCaseRepository(restoredPool);
  await assert.rejects(target.pool('phase5_restore').query('SELECT * FROM safeathome_private.cases'));
  const restoredSafety = await restored.readHomeSafetyForUser(OWNER, caseId);
  assert.equal(restoredSafety.status, 'found');
  if (restoredSafety.status !== 'found') throw Error('Missing restored fictional case');
  assert.deepEqual(restoredSafety.state, savedSafety);
  const restoredProgress = await restored.readProgressForUser(OWNER, caseId);
  assert.equal(restoredProgress.status, 'found');
  if (restoredProgress.status !== 'found') throw Error('Missing restored fictional tasks');
  assert.equal(restoredProgress.context.record.tasks.length, 2);
  assert.equal(restoredProgress.context.record.tasks.find(t => t.id === referral.id)!.referral!.imported!.contactNote,
    referral.referral!.imported!.contactNote);
  const restoredShares = new PostgresSharingRepository(restoredPool, async () => registry);
  assert.equal((await restoredShares.execute(HELPER, 'read-shared-case', { schemaVersion: '3',
    membershipId: helper.membership.membershipId, expectedPermissionRevision: 3 })).status, 'not_found');
  const restoredRows = await targetAdmin.query('SELECT collaboration FROM safeathome_private.cases WHERE case_id=$1', [caseId]);
  assert.deepEqual(restoredRows.rows[0].collaboration.assignments, []);

  await post('/v3/revoke-sharing', { schemaVersion: '3', caseId, invitationId: viewer.membership.membershipId, expectedPermissionRevision: 2 });
  await post('/v3/read-shared-case', { schemaVersion: '3', membershipId: viewer.membership.membershipId, expectedPermissionRevision: 2 }, VIEWER, 404);
  await saveSafety({ type: 'answer', roomId: 'bedroom-main', questionId: 'bedroom.path', value: 'not_sure' });
  assert.equal(safetyConcernAddressed(safety, link), false);
  await post('/v3/export-home-safety', reportRequest, OWNER, 409);
  await post('/v1/delete-case', { schemaVersion: '1', caseId, expectedCaseRevision: safety.case.revision,
    expectedCatalogRevision: 0, confirmation: 'DELETE_CASE' });
  await post('/v3/read-home-safety', { schemaVersion: '3', caseId }, OWNER, 404);
  await post('/v3/read-collaboration', { schemaVersion: '3', membershipId: helper.membership.membershipId, expectedPermissionRevision: 3 }, HELPER, 404);
  assert.equal((await admin.query('SELECT 1 FROM safeathome_private.case_shares WHERE case_id=$1', [caseId])).rowCount, 0);
});
