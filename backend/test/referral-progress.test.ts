import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { canonicalJson } from '../src/evidence/validation.ts';
import { parseProgressRecord, parseProgressRequest, parseTask, progressPage, type ProgressSave, type NextStepTask, type ProgressContext } from '../src/tracking/progress.ts';
import { draft } from './postgres/fixtures.ts';

const at = '2026-10-24T12:00:00.000Z', caseId = 'fictional-referral-plan';
const source = { id: 'local-follow-up', providerId: 'referral-211-national', title: 'Ask about a ramp', responsible: 'Fictional resident', dueDate: '2026-10-01', findingId: 'old-removed-finding', createdAt: at, completedAt: at };
export const importedReferral = { providerId: source.providerId, imported: {
  sourceTaskId: source.id, sourceHash: createHash('sha256').update(canonicalJson(source)).digest('hex'), original: source, contactNote: 'Ask for interpretation {count}',
} };
function task(id = 'shared-referral-task'): NextStepTask { return { id, programId: null, findingId: null, formId: null, title: source.title, kind: 'follow_up', state: 'completed', responsiblePerson: source.responsible, dueOn: null, basedOnCaseRevision: 1, basedOnRuleVersion: null, revision: 1, sourceEventId: null, referral: structuredClone(importedReferral) }; }
const request = (t = task(), revision = 0, expectedTaskRevision = 0): ProgressSave => ({ schemaVersion: '3', caseId, includeReferrals: true, expectedCaseRevision: 1, expectedProgressRevision: revision, mutationId: randomUUID(), operation: { type: 'put_task', task: t, expectedTaskRevision } });
function repo() { return new MemoryCaseRepository([{ userId: 'alice', snapshot: { ...draft(caseId), revision: 1 } }]); }
async function context(r: MemoryCaseRepository): Promise<ProgressContext> { const result = await r.readProgressForUser('alice', caseId); assert.equal(result.status, 'found'); if (result.status !== 'found') throw Error(); return result.context; }

test('referral contract is opt-in; old requests/tasks and exact old response shapes remain valid', async () => {
  const r = repo(), oldTask = task(); delete oldTask.referral;
  assert.deepEqual(parseTask(oldTask), oldTask);
  const input = request(); assert.deepEqual(parseProgressRequest(input, true), input);
  assert.equal((await r.saveProgressForUser('alice', input, at, [])).status, 'found');
  const ctx = await context(r), query = { schemaVersion: '3' as const, caseId, offset: 0, limit: 20, expectedProgressRevision: null, expectedCaseRevision: null, expectedHistoryVersion: null };
  const old = progressPage(ctx, query, []); assert.equal(Object.hasOwn(old.tasks[0], 'referral'), false);
  assert.deepEqual(Object.keys(old.tasks[0]).sort(), [...Object.keys(oldTask), 'needsReview'].sort());
  const current = progressPage(ctx, { ...query, includeReferrals: true }, []);
  assert.deepEqual(current.tasks[0].referral, importedReferral);
  assert.equal(ctx.record.tasks[0].programId, null); assert.equal(ctx.record.programs.length, 0); assert.equal(ctx.legacy.length, 0);
  assert.throws(() => parseProgressRequest({ ...query, includeReferrals: false }, false));
});

test('old-client edits retain import receipt, dates, note, completion and append-only provenance', async () => {
  const r = repo(); await r.saveProgressForUser('alice', request(), at, []);
  const original = (await context(r)).record.events[0];
  const edited = { ...task(), revision: 2, state: 'pending' as const, title: 'Call again' }; delete edited.referral;
  assert.equal((await r.saveProgressForUser('alice', request(edited, 1, 1), at, [])).status, 'found');
  const ctx = await context(r); assert.deepEqual(ctx.record.events[0], original);
  assert.deepEqual(ctx.record.tasks[0].referral, importedReferral); assert.equal(ctx.record.tasks[0].state, 'pending');
  assert.deepEqual(parseProgressRecord(ctx.record), ctx.record);
  const removed = { ...task(), revision: 3, referral: { providerId: 'another-referral' } };
  assert.equal((await r.saveProgressForUser('alice', request(removed, 2, 2), at, [])).status, 'invalid_operation');
});

test('stable source receipt prevents duplicate imports; exact retry and owner boundaries survive', async () => {
  const r = repo(), first = request();
  const saved = await r.saveProgressForUser('alice', first, at, []);
  assert.equal(saved.status, 'found');
  assert.deepEqual(await r.saveProgressForUser('alice', first, at, []), saved);
  assert.equal((await r.saveProgressForUser('alice', request(task('different-id'), 1), at, [])).status, 'task_conflict');
  assert.equal((await r.saveProgressForUser('bob', first, at, [])).status, 'not_found');
  const ctx = await context(r); assert.equal(ctx.record.tasks.length, 1); assert.equal(ctx.record.events.length, 1);
  assert.deepEqual(ctx.record.tasks[0].referral!.imported!.original, source);
});

test('malformed provenance and forged hashes fail without changing saved progress', async () => {
  const r = repo(), invalid = task(); invalid.referral!.imported!.original.title = 'Rewritten source';
  assert.throws(() => parseTask(invalid));
  await assert.rejects(r.saveProgressForUser('alice', request(invalid), at, []));
  assert.equal((await context(r)).record.tasks.length, 0);
  const extra = { ...task(), referral: { ...importedReferral, url: 'https://example.org' } };
  assert.throws(() => parseTask(extra));
});

test('shared fictional referral fixture parses without changing strict legacy shapes', () => {
  const fixture = JSON.parse(readFileSync(new URL('../../contracts/v3/fixtures/referral-progress.json', import.meta.url), 'utf8'));
  assert.deepEqual(parseProgressRequest(fixture.save, true), fixture.save);
  assert.deepEqual(parseTask(fixture.save.operation.task).referral?.imported?.original, fixture.localSource);
});
