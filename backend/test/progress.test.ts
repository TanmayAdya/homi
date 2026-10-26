import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { draft } from './postgres/fixtures.ts';
import { demoProgram } from '../fixtures/demo-program.ts';
import { emptyProgress, parseProgressRecord, parseProgressRequest, progressPrograms, progressPage, type NextStepTask, type ProgressSave, type ProgressOperation } from '../src/tracking/progress.ts';
const at = '2026-10-24T12:00:00.000Z', caseId = 'fictional-tracking', owner = 'alice';
const registry = Array.from({ length: 6 }, (_, i) => ({ ...demoProgram, programId: `program-${i}`, programName: `Fictional program ${i}` }));
const repo = () => new MemoryCaseRepository([{ userId: owner, snapshot: { ...draft(caseId), revision: 1 } }]);
const save = (operation: ProgressOperation, expectedProgressRevision = 0, expectedCaseRevision = 1): ProgressSave => ({ schemaVersion: '3', caseId, operation, expectedCaseRevision, expectedProgressRevision, mutationId: randomUUID() });
const task = (id = 'one', programId: string | null = null): NextStepTask => ({ id, programId, findingId: null, formId: null, title: 'Call the fictional agency', kind: 'contact', state: 'pending', responsiblePerson: null, dueOn: '2026-11-01', basedOnCaseRevision: 1, basedOnRuleVersion: programId === null ? null : registry[0].ruleVersion, revision: 1, sourceEventId: null });
async function context(r: MemoryCaseRepository) { const result = await r.readProgressForUser(owner, caseId); assert.equal(result.status, 'found'); if (result.status !== 'found') throw Error(); return result.context; }

test('multiple programs and independent tasks, no fabricated history and task completion never submits', async () => {
  const r = repo();
  for (const [index, program] of registry.entries()) assert.equal((await r.saveProgressForUser(owner, save({ type: 'track_program', programId: program.programId }, index), at, registry)).status, 'found');
  assert.equal(progressPrograms(await context(r), registry).length, 6);
  assert.ok(progressPrograms(await context(r), registry).every(p => p.latest === null));
  for (const [index, id] of ['one', 'two'].entries()) assert.equal((await r.saveProgressForUser(owner, save({ type: 'put_task', task: task(id, registry[0].programId), expectedTaskRevision: 0 }, index + 6), at, registry)).status, 'found');
  const request = save({ type: 'put_task', expectedTaskRevision: 1, task: { ...task('one', registry[0].programId), revision: 2, state: 'completed' } }, 8);
  await r.saveProgressForUser(owner, request, at, registry);
  assert.deepEqual((await context(r)).record.tasks.map(t => t.state), ['completed', 'pending']);
  assert.equal(progressPrograms(await context(r), registry)[0].latest, null);
  assert.equal((await context(r)).snapshot.revision, 1);
  assert.equal((await r.saveProgressForUser('bob', request, at, registry)).status, 'not_found');
  assert.equal((await r.readProgressForUser('bob', caseId)).status, 'not_found');
});
test('idempotent lost-response retries and revision conflicts preserve one append-only event', async () => {
  const r = repo(), request = save({ type: 'put_task', task: task(), expectedTaskRevision: 0 });
  await r.saveProgressForUser(owner, request, at, registry);
  assert.equal((await r.saveProgressForUser(owner, request, at, registry)).status, 'found');
  assert.equal((await context(r)).record.events.length, 1);
  assert.equal((await r.saveProgressForUser(owner, { ...request, expectedCaseRevision: 2 }, at, registry)).status, 'mutation_conflict');
  assert.equal((await r.saveProgressForUser(owner, save({ type: 'put_task', task: task('two'), expectedTaskRevision: 0 }), at, registry)).status, 'progress_conflict');
  assert.equal((await r.saveProgressForUser(owner, save({ type: 'put_task', task: task('one'), expectedTaskRevision: 0 }, 1), at, registry)).status, 'task_conflict');
  assert.equal((await r.saveProgressForUser(owner, save({ type: 'put_task', task: task('two'), expectedTaskRevision: 0 }, 1, 2), at, registry)).status, 'conflict');
});
test('legacy history remains intact, retired identity persists, old action needs acceptance only once', async () => {
  const r = repo(), updateId = randomUUID();
  await r.appendRequestUpdateForUser({ userId: owner, caseId, revision: 1, programId: registry[0].programId, expectedRequestRevision: 0, recordedAt: at,
    update: { updateId, status: 'withdrawn', occurredOn: '2026-10-24', source: 'self_report', note: null, nextAction: 'Ask the fictional agency', responsibleParty: 'caregiver', followUpOn: '2026-10-23' } });
  let ctx = await context(r);
  assert.equal(progressPrograms(ctx, registry)[0].proposal?.eventId, updateId);
  assert.equal(ctx.record.tasks.length, 0);
  await r.saveProgressForUser(owner, save({ type: 'put_task', task: { ...task('one', registry[0].programId), sourceEventId: updateId }, expectedTaskRevision: 0 }), at, registry);
  ctx = await context(r);
  const retired = progressPrograms(ctx, []);
  assert.equal(retired[0].name, registry[0].programName); assert.equal(retired[0].retired, true); assert.equal(retired[0].latest?.status, 'withdrawn'); assert.equal(retired[0].latest?.recordedBy, null); assert.equal(retired[0].proposal, null);
  assert.equal((await r.saveProgressForUser(owner, save({ type: 'put_task', task: { ...task('two', registry[0].programId), sourceEventId: updateId }, expectedTaskRevision: 0 }, 1), at, registry)).status, 'invalid_operation');
  const old = await r.readRequestHistoryForUser({ userId: owner, caseId, revision: 1, programId: registry[0].programId });
  assert.equal(old.status, 'found'); if (old.status === 'found') assert.equal(old.history.events.length, 1);
});
test('pagination, stale requirements and explicit quotas never drop existing tasks/history', async () => {
  const r = repo();
  for (let i = 0; i < 128; i++) assert.equal((await r.saveProgressForUser(owner, save({ type: 'put_task', task: task(`task-${i}`), expectedTaskRevision: 0 }, i), at, registry)).status, 'found');
  assert.equal((await r.saveProgressForUser(owner, save({ type: 'put_task', task: task('too-many'), expectedTaskRevision: 0 }, 128), at, registry)).status, 'limit');
  const ctx = await context(r);
  assert.equal(ctx.record.tasks.length, 128); assert.equal(ctx.record.events.length, 128);
  const query = { schemaVersion: '3' as const, caseId, offset: 0, limit: 20, expectedProgressRevision: null, expectedCaseRevision: null, expectedHistoryVersion: null };
  const page = progressPage({ ...ctx, snapshot: { ...ctx.snapshot, revision: 2 } }, query, registry);
  assert.equal(page.tasks.length, 20); assert.equal(page.nextOffset, 20); assert.equal(page.tasks[0].needsReview, true);
});
test('strict v3 validation rejects unknowns, invalid dates, misleading states and oversized fields', () => {
  const request = save({ type: 'put_task', task: task(), expectedTaskRevision: 0 });
  for (const invalid of [{ ...request, schemaVersion: '1' }, { ...request, userId: owner }, { ...request, expectedProgressRevision: -1 },
    { ...request, operation: { type: 'put_task', task: { ...task(), dueOn: '2026-02-31' }, expectedTaskRevision: 0 } },
    { ...request, operation: { type: 'put_task', task: { ...task(), state: 'approved' }, expectedTaskRevision: 0 } }]) assert.throws(() => parseProgressRequest(invalid, true));
  assert.deepEqual(parseProgressRecord(emptyProgress(caseId)), emptyProgress(caseId));
});
test('changed program rules flag tasks for review and cannot silently complete stale requirements', async () => {
  const r = repo();
  await r.saveProgressForUser(owner, save({ type: 'track_program', programId: registry[0].programId }), at, registry);
  await r.saveProgressForUser(owner, save({ type: 'put_task', task: task('one', registry[0].programId), expectedTaskRevision: 0 }, 1), at, registry);
  const changed = registry.map(p => ({ ...p, ruleVersion: 'fictional-next-version' })), ctx = await context(r);
  const query = { schemaVersion: '3' as const, caseId, offset: 0, limit: 20, expectedProgressRevision: null, expectedCaseRevision: null, expectedHistoryVersion: null };
  assert.equal(progressPage(ctx, query, changed).tasks[0].needsReview, true);
  assert.equal((await r.saveProgressForUser(owner, save({ type: 'put_task', task: { ...task('one', registry[0].programId), state: 'completed', revision: 2 }, expectedTaskRevision: 1 }, 2), at, changed)).status, 'invalid_operation');
});
test('v3 reports extend a full legacy history without rewriting its 50 original events', async () => {
  const r = repo(), programId = registry[0].programId;
  for (let i = 0; i < 50; i++) {
    assert.equal((await r.appendRequestUpdateForUser({ userId: owner, caseId, revision: 1, programId, expectedRequestRevision: i, recordedAt: at,
      update: { updateId: randomUUID(), status: 'preparing', occurredOn: '2026-10-24', source: 'self_report', note: null, nextAction: null, responsibleParty: null, followUpOn: null } })).status, 'found');
  }
  const status = await r.saveProgressForUser(owner, save({ type: 'report_status', programId, update: { updateId: randomUUID(), status: 'received', occurredOn: '2026-10-24', source: 'program_contact', note: 'Fictional phone report', nextAction: null, responsibleParty: null, followUpOn: null } }), at, registry);
  assert.equal(status.status, 'found');
  const ctx = await context(r), latest = progressPrograms(ctx, registry)[0].latest!;
  assert.equal(latest.status, 'received'); assert.equal(latest.recordedBy, owner); assert.equal(latest.source, 'program_contact');
  assert.equal(ctx.legacy[0].events.length, 50); assert.equal(ctx.record.events.length, 1);
});
