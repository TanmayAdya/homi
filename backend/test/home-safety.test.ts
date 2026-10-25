import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { STEADI_CATALOG, safetyRequestHash, parseHomeSafetyRecord, parseHomeSafetyRequest, type HomeSafetySave, type SafetyOperation } from '../src/assessment/home-safety.ts';
import { draft } from './postgres/fixtures.ts';

const owner = 'fictional-owner', caseId = randomUUID(), at = '2026-10-24T18:00:00.000Z';
const repo = () => new MemoryCaseRepository([{ userId: owner, snapshot: { ...draft(caseId), revision: 1 } }]);
const request = (operation: SafetyOperation, expectedSafetyRevision = 0, expectedCaseRevision = 1): HomeSafetySave => ({ schemaVersion: '3',
  caseId, expectedSafetyRevision, expectedCaseRevision, mutationId: randomUUID(), operation });
const add = (id = 'bedroom-one') => request({ type: 'add_room', room: { id, type: 'bedroom', name: 'Fictional upstairs room' } });
async function state(r: MemoryCaseRepository) { const result = await r.readHomeSafetyForUser(owner, caseId); assert.equal(result.status, 'found'); if (result.status !== 'found') throw Error(); return result.state; }

test('addressed reports require current confirmed concerns, retain actor/history, retry exactly and never change the canonical case', async () => {
  const r = repo();
  await r.saveHomeSafetyForUser(owner, add(), at);
  await r.saveHomeSafetyForUser(owner, request({ type: 'answer', roomId: 'bedroom-one', questionId: 'bedroom.path', value: 'yes' }, 1), at);
  const review: SafetyOperation = { type: 'review_concern', roomId: 'bedroom-one', questionId: 'bedroom.path', findingId: 'new-concern', observation: 'Fictional dark route', state: 'needs_review' };
  await r.saveHomeSafetyForUser(owner, request(review, 2), at);
  let saved = await state(r);
  const report = (): Extract<SafetyOperation, { type: 'set_addressed' }> => ({ type: 'set_addressed', roomId: 'bedroom-one', findingId: 'new-concern', findingFingerprint: safetyRequestHash(saved.case.findings.at(-1)), answerRevision: saved.safety.document.answers[0].revision, addressed: true });
  assert.equal((await r.saveHomeSafetyForUser(owner, request(report(), 3, 2), at)).status, 'invalid_operation');
  await r.saveHomeSafetyForUser(owner, request({ ...review, state: 'confirmed' }, 3, 2), at);
  saved = await state(r); const before = saved.case;
  const addressed = request(report(), 4, 3);
  assert.equal((await r.saveHomeSafetyForUser(owner, addressed, at)).status, 'found');
  saved = await state(r); assert.deepEqual(saved.case, before);
  assert.equal(saved.safety.history.at(-1)!.recordedBy, owner);
  assert.equal((await r.saveHomeSafetyForUser(owner, addressed, at)).status, 'found');
  assert.equal((await state(r)).safety.revision, 5);
  assert.equal((await r.saveHomeSafetyForUser('another-owner', addressed, at)).status, 'not_found');
  await r.saveHomeSafetyForUser(owner, request({ type: 'answer', roomId: 'bedroom-one', questionId: 'bedroom.path', value: 'no' }, 5, 3), at);
  saved = await state(r);
  assert.equal((await r.saveHomeSafetyForUser(owner, request(report(), 6, 3), at)).status, 'invalid_operation');
  await r.saveHomeSafetyForUser(owner, request({ ...review, state: 'confirmed', observation: 'Fictional corrected route' }, 6, 3), at);
  assert.equal((await r.saveHomeSafetyForUser(owner, { ...addressed, mutationId: randomUUID(), expectedSafetyRevision: 7, expectedCaseRevision: 4 }, at)).status, 'invalid_operation');
  saved = await state(r);
  assert.equal((await r.saveHomeSafetyForUser(owner, request({ ...report(), addressed: false }, 7, 4), at)).status, 'found');
  assert.equal((await state(r)).safety.history.length, 8);
});

test('two rooms of the same type have stable independent answers and names without changing the case', async () => {
  const r = repo(); await r.saveHomeSafetyForUser(owner, add(), at);
  await r.saveHomeSafetyForUser(owner, { ...add('bedroom-two'), expectedSafetyRevision: 1 }, at);
  await r.saveHomeSafetyForUser(owner, request({ type: 'answer', roomId: 'bedroom-one', questionId: 'bedroom.path', value: 'not_sure' }, 2), at);
  await r.saveHomeSafetyForUser(owner, request({ type: 'answer', roomId: 'bedroom-two', questionId: 'bedroom.path', value: 'no' }, 3), at);
  await r.saveHomeSafetyForUser(owner, request({ type: 'rename_room', roomId: 'bedroom-one', name: 'Fictional renamed room' }, 4), at);
  const saved = await state(r);
  assert.equal(saved.case.revision, 1); assert.equal(saved.case.findings.length, 1);
  assert.deepEqual(saved.safety.document.answers.map(a => a.value), ['not_sure', 'no']);
  assert.equal(saved.safety.document.rooms[0].name, 'Fictional renamed room');
  assert.equal(saved.safety.history[4].recordedBy, owner); assert.equal(saved.safety.history[4].recordedAt, at);
  saved.safety.document.rooms[0].name = 'Caller mutation';
  assert.equal((await state(r)).safety.document.rooms[0].name, 'Fictional renamed room');
});
test('exact retry is acknowledged even after later changes; reused IDs and competing writes conflict', async () => {
  const r = repo(), first = add(); await r.saveHomeSafetyForUser(owner, first, at);
  await r.saveHomeSafetyForUser(owner, request({ type: 'rename_room', roomId: 'bedroom-one', name: null }, 1), at);
  const retried = await r.saveHomeSafetyForUser(owner, first, at);
  assert.equal(retried.status, 'found'); if (retried.status === 'found') { assert.equal(retried.state.safety.revision, 2); assert.equal(retried.state.acknowledgedMutationId, first.mutationId); }
  assert.deepEqual(await r.saveHomeSafetyForUser(owner, { ...first, operation: { type: 'rename_room', roomId: 'bedroom-one', name: 'Different' } }, at), { status: 'mutation_conflict' });
  const writes = await Promise.all(['yes', 'no'].map(value => r.saveHomeSafetyForUser(owner,
    request({ type: 'answer', roomId: 'bedroom-one', questionId: 'bedroom.path', value: value as 'yes' | 'no' }, 2), at)));
  assert.deepEqual(writes.map(w => w.status).sort(), ['found', 'safety_conflict']);
  assert.deepEqual(await r.readHomeSafetyForUser('another-owner', caseId), { status: 'not_found' });
  assert.deepEqual(await r.saveHomeSafetyForUser('another-owner', first, at), { status: 'not_found' });
});
test('only explicit review creates a canonical finding; changed answers retain its provenance and measurements', async () => {
  const r = repo(); await r.saveHomeSafetyForUser(owner, add(), at);
  await r.saveHomeSafetyForUser(owner, request({ type: 'answer', roomId: 'bedroom-one', questionId: 'bedroom.path', value: 'yes' }, 1), at);
  assert.equal((await state(r)).case.findings.length, 1);
  const review: SafetyOperation = { type: 'review_concern', roomId: 'bedroom-one', questionId: 'bedroom.path', findingId: 'fictional-new-finding',
    observation: 'Fictional resident reports a dark bedroom route.', state: 'confirmed' };
  await r.saveHomeSafetyForUser(owner, request(review, 2), at);
  let saved = await state(r); assert.equal(saved.case.revision, 2); assert.equal(saved.case.findings.length, 2);
  assert.equal(saved.case.findings[1].room, 'other'); assert.equal(saved.safety.document.findingRooms[0].answerRevision, 1);
  await r.saveHomeSafetyForUser(owner, request({ type: 'answer', roomId: 'bedroom-one', questionId: 'bedroom.path', value: 'no' }, 3, 2), at);
  saved = await state(r); assert.equal(saved.case.findings[1].reviewState, 'confirmed');
  assert.equal(saved.safety.document.findingRooms[0].answerRevision, 1); assert.equal(saved.safety.document.answers[0].revision, 2);
  await r.saveHomeSafetyForUser(owner, request({ ...review, state: 'dismissed' }, 4, 2), at);
  saved = await state(r); assert.equal(saved.case.findings.length, 2); assert.equal(saved.case.findings[1].reviewState, 'dismissed');
  assert.equal(saved.safety.document.findingRooms[0].answerRevision, 2);
  assert.equal((await r.saveHomeSafetyForUser(owner, request({ ...review, findingId: 'duplicate-finding' }, 5, 3), at)).status, 'invalid_operation');
});
test('unknown, inapplicable and opposite-polarity answers never become hazards; room and case bindings are checked', async () => {
  const r = repo(); await r.saveHomeSafetyForUser(owner, add(), at);
  const review = { type: 'review_concern' as const, roomId: 'bedroom-one', questionId: 'bedroom.path', findingId: 'new', observation: 'Fictional observation', state: 'confirmed' as const };
  assert.equal((await r.saveHomeSafetyForUser(owner, request(review, 1), at)).status, 'invalid_operation');
  for (const [index, value] of ['not_sure', 'not_applicable', 'unanswered', 'no'].entries()) {
    await r.saveHomeSafetyForUser(owner, request({ type: 'answer', roomId: 'bedroom-one', questionId: 'bedroom.path', value: value as 'no' }, index + 1), at);
    assert.equal((await r.saveHomeSafetyForUser(owner, request(review, index + 2), at)).status, 'invalid_operation');
  }
  assert.equal((await r.saveHomeSafetyForUser(owner, request({ type: 'answer', roomId: 'bedroom-one', questionId: 'stairs.rails', value: 'no' }, 5), at)).status, 'invalid_operation');
  assert.equal((await r.saveHomeSafetyForUser(owner, request({ type: 'rename_room', roomId: 'bedroom-one', name: null }, 5, 99), at)).status, 'conflict');
  assert.equal(STEADI_CATALOG.questions.find(q => q.id === 'stairs.lighting')!.concernWhen, 'no');
});
test('strict contracts reject unknown fields, invalid names, orphan links and mismatched source versions', async () => {
  for (const invalid of [{ ...add(), ownerId: owner }, { ...add(), schemaVersion: '2' },
    request({ type: 'add_room', room: { id: 'one', type: 'bedroom', name: 'Fictional\nroom' } }),
    { ...add(), expectedSafetyRevision: -1 }, { ...add(), operation: { type: 'answer', roomId: 'a', questionId: 'invented', value: 'yes' } }]) {
    assert.throws(() => parseHomeSafetyRequest(invalid, true));
  }
  const r = repo(); await r.saveHomeSafetyForUser(owner, add(), at); const record = (await state(r)).safety;
  assert.throws(() => parseHomeSafetyRecord({ ...record, document: { ...record.document, catalogVersion: 'future' } }));
  assert.throws(() => parseHomeSafetyRecord({ ...record, history: [] }));
  assert.throws(() => parseHomeSafetyRecord({ ...record, document: { ...record.document, findingRooms: [{ findingId: 'f', roomId: 'missing', questionId: null, answerRevision: null }] } }));
});
test('the audit limit rejects the entire mutation while retaining the last saved room and case', async () => {
  const r = repo(); await r.saveHomeSafetyForUser(owner, add(), at);
  for (let index = 1; index < 500; index++) {
    const result = await r.saveHomeSafetyForUser(owner, request({ type: 'rename_room', roomId: 'bedroom-one', name: `Fictional name ${index}` }, index), at);
    assert.equal(result.status, 'found');
  }
  const before = await state(r);
  assert.equal((await r.saveHomeSafetyForUser(owner, request({ type: 'rename_room', roomId: 'bedroom-one', name: 'Must not save' }, 500), at)).status, 'history_limit');
  assert.deepEqual(await state(r), before); assert.equal(before.safety.history.length, 500); assert.equal(before.case.revision, 1);
});
