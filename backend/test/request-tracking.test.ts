import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import sharp from 'sharp';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { sanitizeEvidenceImage } from '../src/evidence/image-sanitizer.ts';
import { createSavedFormAnswers } from '../src/forms/form-answers.ts';
import { AccountClosedError } from '../src/lifecycle/types.ts';
import type { CaseSnapshot } from '../src/types.ts';
import { demoProgram } from '../fixtures/demo-program.ts';
import { handleAppendRequestUpdate, handleReadRequestHistory, type RequestTrackingDependencies,
  type RequestTrackingResult } from '../src/api/request-tracking.ts';
import { appendRequestHistory, emptyRequestHistory, parseRequestAppendInput, parseRequestHistory,
  parseRequestHistoryInput, parseRequestTrackingRequest, parseRequestUpdate, requestDate, requestInstant,
  REQUEST_PARTIES, REQUEST_SOURCES, REQUEST_STATUSES, type RequestHistory, type RequestHistoryAppendInput,
  type RequestUpdate } from '../src/requests/tracking.ts';

const NOW = '2026-10-18T10:00:00.000Z';
const LATER = '2026-10-18T10:01:00.000Z';
const PROGRAM = 'scfhp-eaa';
const ID = '01000000-0000-4000-8000-000000000001';
const NEXT_ID = '01000000-0000-4000-8000-000000000002';
const binding = { userId: 'alice', caseId: 'case-alice', revision: 1, programId: PROGRAM };
const readRequest = { schemaVersion: '1', caseId: 'case-alice', expectedCaseRevision: 1, programId: PROGRAM };
function update(overrides: Partial<RequestUpdate> = {}): RequestUpdate {
  return { updateId: ID, status: 'preparing', occurredOn: '2026-10-18', source: 'self_report',
    note: null, nextAction: null, responsibleParty: null, followUpOn: null, ...overrides };
}
function appendInput(overrides: Partial<RequestHistoryAppendInput> = {}): RequestHistoryAppendInput {
  return { ...binding, expectedRequestRevision: 0, update: update(), recordedAt: NOW, ...overrides };
}
function appendRequest(overrides: Record<string, unknown> = {}) {
  return { ...readRequest, expectedRequestRevision: 0, update: update(), ...overrides };
}
function found(result: ReturnType<typeof appendRequestHistory>): RequestHistory {
  assert.equal(result.status, 'found'); assert.ok('history' in result); return result.history;
}
function setup() {
  const repository = new MemoryCaseRepository([{ userId: 'alice', snapshot: snapshot() },
    { userId: 'bob', snapshot: snapshot('case-bob') }]);
  const calls: string[] = [];
  let now = NOW;
  const deps: RequestTrackingDependencies = {
    authenticate: async token => {
      calls.push('authenticate'); return token === 'alice-token' ? { userId: 'alice' }
        : token === 'bob-token' ? { userId: 'bob' } : null;
    },
    cases: {
      readRequestHistoryForUser: async input => { calls.push('read'); return repository.readRequestHistoryForUser(input); },
      appendRequestUpdateForUser: async input => { calls.push('append'); return repository.appendRequestUpdateForUser(input); },
    },
    loadRegistry: async () => { calls.push('registry'); return [{ ...demoProgram, programId: PROGRAM, isDemo: false }]; },
    now: () => new Date(now),
  };
  const read = (body: unknown = readRequest, bearerToken: string | null = 'alice-token') =>
    handleReadRequestHistory({ body, bearerToken }, deps);
  const append = (body: unknown = appendRequest(), bearerToken: string | null = 'alice-token') =>
    handleAppendRequestUpdate({ body, bearerToken }, deps);
  return { repository, calls, deps, read, append, setNow: (value: string) => { now = value; } };
}
function success(result: RequestTrackingResult): RequestHistory {
  assert.equal(result.status, 200); assert.ok('events' in result.body);
  assert.equal(result.headers['Cache-Control'], 'no-store');
  assert.deepEqual(Object.keys(result.body).sort(), ['caseId', 'caseRevision', 'events', 'programId', 'provenance', 'requestRevision', 'schemaVersion']);
  return result.body;
}
function failure(result: RequestTrackingResult, status: number, code: string) {
  assert.equal(result.status, status); assert.ok('error' in result.body);
  assert.equal(result.body.error.code, code); assert.equal(result.headers['Cache-Control'], 'no-store');
  assert.deepEqual(Object.keys(result.body).sort(), ['error', 'schemaVersion']);
  assert.deepEqual(Object.keys(result.body.error).sort(), ['code', 'message']);
  assert.ok(!JSON.stringify(result).includes('PRIVATE'));
  if (status === 401) assert.equal(result.headers['WWW-Authenticate'], 'Bearer');
}

function snapshot(caseId = 'case-alice', revision = 1): CaseSnapshot {
  return { schemaVersion: '1', caseId, revision,
    profile: { city: 'PRIVATE Fictional City', county: null, healthPlan: null, tenure: null,
      ageYears: null, householdSize: null, annualIncomeUsd: 0, ownerConsentReported: false },
    unresolvedFields: [], findings: [{ id: 'finding-a', room: 'bathroom',
      observation: 'PRIVATE fictional reviewed finding', reviewState: 'confirmed', evidenceIds: ['photo-a'], measurements: [] }] };
}

async function seedIndependentOutputs(repository: MemoryCaseRepository) {
  const answers = createSavedFormAnswers({ snapshot: snapshot('case-alice', 2), context: {
    programId: PROGRAM, formVersion: 'form-a', mappingVersion: 'mapping-a', formContextId: 'b'.repeat(64) },
    answerRevision: 1, answers: [], updatedAt: NOW, updatedBy: 'alice' });
  assert.equal((await repository.saveFormAnswersIfCurrent({ userId: 'alice', caseId: 'case-alice', revision: 1,
    programId: PROGRAM, expectedAnswerRevision: 0, answers })).status, 'saved');
  const match = { schemaVersion: '1' as const, caseId: 'case-alice', caseRevision: 2,
    evaluatedAt: NOW, evaluationDate: NOW.slice(0, 10), matches: [] };
  assert.equal(await repository.saveMatchIfCurrent('alice', 'case-alice', 2, match), 'saved');
  const image = await sanitizeEvidenceImage(await sharp({ create: { width: 2, height: 2,
    channels: 4, background: '#d0d0d0' } }).png().toBuffer());
  const binding = { userId: 'alice', caseId: 'case-alice', revision: 2, expectedCatalogRevision: 1 };
  assert.equal((await repository.saveEvidenceIfCurrent({ ...binding, expectedCatalogRevision: 0,
    evidenceId: 'photo-a', expectedEvidenceRevision: 0, findingId: 'finding-a', image,
    capturedAt: null, preparedAt: NOW })).status, 'saved');
  const selections = [{ evidenceId: 'photo-a', expectedEvidenceRevision: 1, reviewedForExport: true as const }];
  const loaded = await repository.loadExportSnapshotForUser({ ...binding, programId: PROGRAM, selections });
  assert.equal(loaded.status, 'found'); if (loaded.status !== 'found') throw new Error('Fixture setup failed.');
  const bytes = Buffer.from('%PDF-1.7\nFictional export bytes; rendering has separate tests.\n');
  const contextFingerprint = 'a'.repeat(64);
  assert.equal((await repository.publishExportIfCurrent({ ...binding, programId: PROGRAM, selections,
    expectedCaseFingerprint: loaded.snapshot.caseFingerprint, expectedAnswersFingerprint: loaded.snapshot.answersFingerprint,
    contextFingerprint, generationKey: 'tracking-invariance', checkedAt: NOW,
    artifact: { bytes, metadata: { schemaVersion: '1', artifactId: 'artifact-a', caseId: 'case-alice', caseRevision: 2,
      programId: PROGRAM, ruleVersion: 'rule-a', formVersion: 'form-a', mappingVersion: 'mapping-a', formContextId: 'b'.repeat(64),
      answerRevision: 1, evidenceCatalogRevision: 1, exportContextId: contextFingerprint, generatedAt: NOW,
      expiresAt: '2026-10-18T10:15:00.000Z', recheckAfter: null, status: 'draft', isDemo: true, mediaType: 'application/pdf',
      byteLength: bytes.byteLength, sha256: createHash('sha256').update(bytes).digest('hex'), pageCount: 2,
      renderingVersion: 'draft-export-v1', selectedEvidence: loaded.snapshot.assets.map(asset => ({
        evidenceId: asset.descriptor.evidenceId, evidenceRevision: asset.descriptor.evidenceRevision,
        findingId: asset.descriptor.findingId, sha256: asset.descriptor.sha256, reviewedAt: NOW, reviewedBy: 'alice' })),
      missingItems: [], warnings: ['INCOMPLETE_DRAFT', 'NOT_SUBMITTED', 'POLICY_CURRENTNESS_UNKNOWN'] } } })).status, 'saved');
  const inspect = async () => ({
    case: await repository.loadForUser('alice', 'case-alice'),
    match: await repository.readSavedMatchForUser('alice', 'case-alice'),
    answers: await repository.loadFormAnswersForUser('alice', 'case-alice', PROGRAM),
    catalog: await repository.readEvidenceCatalogForUser('alice', 'case-alice'),
    evidence: await repository.readEvidenceForUser({ ...binding, evidenceId: 'photo-a', expectedEvidenceRevision: 1 }),
    export: await repository.readExportForUserIfCurrent({ userId: 'alice', caseId: 'case-alice', artifactId: 'artifact-a',
      contextFingerprint, checkedAt: NOW }),
  });
  return { inspect, before: await inspect() };
}

test('request updates preserve every declared user-reported status, source and responsible party', () => {
  for (const status of REQUEST_STATUSES) for (const source of REQUEST_SOURCES) {
    const input = update({ status, source }); assert.deepEqual(parseRequestUpdate(input), input);
  }
  for (const responsibleParty of REQUEST_PARTIES) {
    const input = update({ nextAction: 'Call the fictional program contact', responsibleParty, followUpOn: '2026-10-20' });
    assert.deepEqual(parseRequestUpdate(input), input);
  }
});

test('calendar dates and recorded instants are exact Gregorian values without coercion or offsets', () => {
  for (const value of ['0001-01-01', '2000-02-29', '2024-02-29', '9999-12-31']) assert.equal(requestDate(value), true);
  for (const value of ['0000-01-01', '1900-02-29', '2026-02-29', '2026-04-31', '2026-13-01', '2026-10-00',
    '2026-1-01', '2026-10-18T00:00:00Z', '', null, 20261018]) assert.equal(requestDate(value), false);
  assert.equal(requestInstant(NOW), true);
  for (const value of ['2026-10-18T10:00:00Z', '2026-10-18T10:00:00.000000Z', '2026-10-18T03:00:00.000-07:00',
    '2026-02-30T10:00:00.000Z', '2026-10-18T24:00:00.000Z', '2026-10-18T10:00:60.000Z', '0000-01-01T00:00:00.000Z', null]) {
    assert.equal(requestInstant(value), false);
  }
});

test('notes allow bounded Unicode scalars and line feeds while rejecting control, malformed and padded text', () => {
  const allowed = update({ note: '🙂'.repeat(500), nextAction: '🙂'.repeat(250), responsibleParty: 'resident' });
  assert.deepEqual(parseRequestUpdate(allowed), allowed);
  assert.equal(parseRequestUpdate(update({ note: 'First line\nSecond line' })).note, 'First line\nSecond line');
  for (const note of ['', ' ', ' leading', 'trailing ', 'x\ty', 'x\ry', 'x\0y', 'x\u007fy', 'x\u0085y',
    'x\u2028y', 'x\u2029y', '\ud800', '\udfff', '🙂'.repeat(501), 0, false, []]) {
    assert.throws(() => parseRequestUpdate({ ...update(), note }));
  }
  assert.throws(() => parseRequestUpdate(update({ nextAction: '🙂'.repeat(251), responsibleParty: 'resident' })));
});

test('updates reject extra provenance, inferred approval, invalid identities and incomplete next actions', () => {
  for (const value of [null, [], {}, { ...update(), updateId: 'manual-id' }, { ...update(), updateId: 'A1000000-0000-4000-8000-000000000001' },
    { ...update(), status: 'automatically_approved' }, { ...update(), source: 'verified_agency' },
    { ...update(), recordedAt: NOW }, { ...update(), actorId: 'PRIVATE' }, { ...update(), revision: 1 },
    { ...update(), nextAction: 'Call tomorrow' }, { ...update(), responsibleParty: 'resident' },
    { ...update(), followUpOn: '2026-10-19' }, { ...update(), nextAction: 'Call tomorrow', responsibleParty: 'unrecognized' }]) {
    assert.throws(() => parseRequestUpdate(value));
  }
});

test('strict route requests reject owner injection, revision coercion and unsupported fields', () => {
  assert.deepEqual(parseRequestTrackingRequest(readRequest, false), readRequest);
  assert.deepEqual(parseRequestTrackingRequest(appendRequest(), true), appendRequest());
  for (const append of [false, true]) {
    const good = append ? appendRequest() : readRequest;
    for (const value of [null, [], {}, { ...good, schemaVersion: 1 }, { ...good, schemaVersion: '2' },
      ...['ownerId', 'userId', 'recordedAt', 'caseRevision', 'provenance'].map(key => ({ ...good, [key]: 'PRIVATE' })),
      ...[0, -1, 1.5, '1', null, true, Number.MAX_SAFE_INTEGER + 1].map(expectedCaseRevision => ({ ...good, expectedCaseRevision })),
      ...['', ' leading', '\ud800', '🙂'.repeat(201)].map(caseId => ({ ...good, caseId })),
      ...['', 'trailing ', 'a\0b'].map(programId => ({ ...good, programId }))]) {
      assert.throws(() => parseRequestTrackingRequest(value, append));
    }
  }
  for (const expectedRequestRevision of [-1, 51, 1.5, '0', null, true, Infinity]) {
    assert.throws(() => parseRequestTrackingRequest(appendRequest({ expectedRequestRevision }), true));
  }
  assert.throws(() => parseRequestTrackingRequest(appendRequest(), false));
  assert.throws(() => parseRequestTrackingRequest(readRequest, true));
});

test('trusted adapter inputs are still strictly validated and detach nested caller values', () => {
  assert.deepEqual(parseRequestHistoryInput(binding), binding);
  const input = appendInput(); const parsed = parseRequestAppendInput(input);
  input.update.note = 'PRIVATE changed after parsing'; input.programId = 'changed';
  assert.equal(parsed.update.note, null); assert.equal(parsed.programId, PROGRAM);
  for (const value of [{ ...binding, userId: '' }, { ...binding, revision: 0 }, { ...binding, ownerId: 'bob' }]) {
    assert.throws(() => parseRequestHistoryInput(value));
  }
  for (const value of [appendInput({ recordedAt: 'invalid' }), appendInput({ update: update({ occurredOn: '2026-10-19' }) }),
    { ...appendInput(), extra: 'PRIVATE' }]) assert.throws(() => parseRequestAppendInput(value));
});

test('empty history carries explicit user-reported provenance and never invents a submitted state', () => {
  assert.deepEqual(emptyRequestHistory(binding), { schemaVersion: '1', caseId: 'case-alice', caseRevision: 1,
    programId: PROGRAM, requestRevision: 0, provenance: 'user_reported', events: [] });
});

test('event order is append revision order even when reported status or occurrence dates go backwards', () => {
  const first = found(appendRequestHistory(emptyRequestHistory(binding), appendInput({ update: update({ status: 'approved' }) })));
  const second = found(appendRequestHistory(first, appendInput({ expectedRequestRevision: 1, recordedAt: LATER,
    update: update({ updateId: NEXT_ID, status: 'preparing', occurredOn: '2026-10-01', source: 'document' }) })));
  assert.deepEqual(second.events.map(item => [item.revision, item.status, item.occurredOn]),
    [[1, 'approved', '2026-10-18'], [2, 'preparing', '2026-10-01']]);
  assert.equal(second.provenance, 'user_reported'); assert.equal(second.caseRevision, 1);
  assert.equal(second.events[1].recordedAt, LATER);
});

test('history parser rejects unsupported metadata, sparse or duplicate events and inconsistent revisions', () => {
  const history = found(appendRequestHistory(emptyRequestHistory(binding), appendInput()));
  const event = history.events[0];
  const withEvent = (value: unknown) => ({ ...history, events: [value] });
  for (const value of [null, [], {}, { ...history, source: 'agency' }, { ...history, provenance: 'verified' },
    { ...history, requestRevision: 0 }, { ...history, requestRevision: '1' }, { ...history, events: new Array(1) },
    { ...history, requestRevision: 2, events: [event, { ...event, revision: 2 }] },
    withEvent({ ...event, revision: 2 }), withEvent({ ...event, revision: '1' }), withEvent({ ...event, caseRevision: 0 }),
    withEvent({ ...event, caseRevision: 2 }), withEvent({ ...event, recordedAt: '2026-10-17T10:00:00.000Z' }),
    withEvent({ ...event, ownerId: 'PRIVATE' }), withEvent(null)]) assert.throws(() => parseRequestHistory(value));
});

test('history parser rejects decreasing case revisions and recorded timestamps', () => {
  const first = found(appendRequestHistory(emptyRequestHistory(binding), appendInput()));
  for (const patch of [{ caseRevision: 1, recordedAt: '2026-10-17T10:00:00.000Z', occurredOn: '2026-10-17' },
    { caseRevision: 1, recordedAt: LATER }]) {
    const events = [{ ...first.events[0], caseRevision: 2 }, { ...first.events[0], updateId: NEXT_ID, revision: 2, ...patch }];
    assert.throws(() => parseRequestHistory({ ...first, caseRevision: 2, requestRevision: 2, events }));
  }
});

test('new request updates use a separate CAS and exact retries remain recognizable after later history', () => {
  const first = found(appendRequestHistory(emptyRequestHistory(binding), appendInput()));
  assert.equal(appendRequestHistory(first, appendInput({ update: update({ updateId: NEXT_ID }) })).status, 'request_conflict');
  const second = found(appendRequestHistory(first, appendInput({ expectedRequestRevision: 1,
    update: update({ updateId: NEXT_ID }), recordedAt: LATER })));
  assert.deepEqual(found(appendRequestHistory(second, appendInput({ recordedAt: LATER }))), second);
  for (const changed of [appendInput({ update: update({ note: 'Different content' }) }),
    appendInput({ expectedRequestRevision: 1 }), appendInput({ update: update({ source: 'document' }) })]) {
    assert.equal(appendRequestHistory(second, changed).status, 'update_conflict');
  }
});

test('clock rollback cannot reorder saved history and output mutations cannot rewrite it', () => {
  const first = found(appendRequestHistory(emptyRequestHistory(binding), appendInput({ recordedAt: LATER })));
  const second = found(appendRequestHistory(first, appendInput({ expectedRequestRevision: 1, update: update({ updateId: NEXT_ID }) })));
  assert.equal(second.events[1].recordedAt, LATER);
  second.events[0].note = 'PRIVATE substitution';
  assert.equal(first.events[0].note, null);
});

test('history is bounded at fifty events but still permits exact retry at the limit', () => {
  let history = emptyRequestHistory(binding);
  for (let index = 0; index < 50; index++) {
    history = found(appendRequestHistory(history, appendInput({ expectedRequestRevision: index,
      update: update({ updateId: `01000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`,
        note: '🙂'.repeat(500), nextAction: '🙂'.repeat(250), responsibleParty: 'resident' }) })));
  }
  assert.equal(history.events.length, 50);
  assert.ok(Buffer.byteLength(JSON.stringify(history)) < 256 * 1024);
  assert.equal(appendRequestHistory(history, appendInput({ expectedRequestRevision: 50,
    update: update({ updateId: '01000000-0000-4000-8000-000000000051' }) })).status, 'quota_exceeded');
  assert.equal(found(appendRequestHistory(history, appendInput({ update: update({ note: '🙂'.repeat(500),
    nextAction: '🙂'.repeat(250), responsibleParty: 'resident' }) }))).requestRevision, 50);
});

test('authentication precedes invalid requests and never reaches private storage for a denied user', async () => {
  for (const token of [null, '', 'bad token', '\ttoken', 'unknown-token']) {
    const state = setup();
    for (const operation of [state.read, state.append]) failure(await operation({ ownerId: 'PRIVATE' }, token), 401, 'UNAUTHENTICATED');
    assert.ok(!state.calls.includes('read')); assert.ok(!state.calls.includes('append')); assert.ok(!state.calls.includes('registry'));
  }
});

test('authenticated malformed requests fail before storage, including untrusted server metadata', async () => {
  const state = setup();
  for (const body of [null, {}, { ...readRequest, ownerId: 'PRIVATE' }, { ...readRequest, expectedCaseRevision: 0 }]) {
    failure(await state.read(body), 400, 'INVALID_REQUEST');
  }
  for (const body of [readRequest, appendRequest({ recordedAt: NOW }), appendRequest({ update: { ...update(), verified: true } })]) {
    failure(await state.append(body), 400, 'INVALID_REQUEST');
  }
  assert.ok(!state.calls.includes('read'));
});

test('owner and current case checks precede the program registry and do not reveal foreign history', async () => {
  const state = setup(); success(await state.append());
  const deniedRead = await state.read(readRequest, 'bob-token');
  const missingRead = await state.read({ ...readRequest, caseId: 'missing' });
  assert.deepEqual(deniedRead, missingRead); failure(deniedRead, 404, 'CASE_NOT_FOUND');
  state.calls.length = 0;
  failure(await state.append(appendRequest(), 'bob-token'), 404, 'CASE_NOT_FOUND');
  failure(await state.append(appendRequest({ expectedCaseRevision: 2 })), 409, 'CASE_REVISION_MISMATCH');
  assert.ok(!state.calls.includes('registry')); assert.ok(!state.calls.includes('append'));
});

test('configured programs allow explicit manual reports without turning unverified policy into verification', async () => {
  const state = setup();
  const saved = success(await state.append(appendRequest({ update: update({ status: 'approved', source: 'program_contact' }) })));
  assert.equal(saved.provenance, 'user_reported'); assert.equal(saved.events[0].status, 'approved');
  assert.deepEqual(Object.keys(saved.events[0]).sort(), ['caseRevision', 'followUpOn', 'nextAction', 'note', 'occurredOn',
    'recordedAt', 'responsibleParty', 'revision', 'source', 'status', 'updateId']);
  assert.equal(saved.events[0].recordedAt, NOW); assert.equal(saved.events[0].caseRevision, 1);
  assert.equal(saved.caseRevision, 1); assert.equal(saved.requestRevision, 1);
});

test('unknown or demo programs cannot receive live updates, but saved history remains readable after removal', async () => {
  const state = setup(); const saved = success(await state.append());
  state.deps.loadRegistry = async () => [];
  assert.deepEqual(success(await state.read()), saved);
  failure(await state.append(appendRequest({ expectedRequestRevision: 1, update: update({ updateId: NEXT_ID }) })), 404, 'PROGRAM_NOT_FOUND');
  state.deps.loadRegistry = async () => [{ ...demoProgram, programId: PROGRAM }];
  failure(await state.append(appendRequest({ expectedRequestRevision: 1, update: update({ updateId: NEXT_ID }) })), 404, 'PROGRAM_NOT_FOUND');
  state.deps.allowDemoPrograms = true;
  assert.equal(success(await state.append(appendRequest({ expectedRequestRevision: 1, update: update({ updateId: NEXT_ID }) }))).requestRevision, 2);
});

test('future occurrence dates and invalid server clocks never append an event', async () => {
  const state = setup();
  failure(await state.append(appendRequest({ update: update({ occurredOn: '2026-10-19' }) })), 400, 'INVALID_REQUEST');
  state.setNow('invalid'); failure(await state.append(), 500, 'INTERNAL_ERROR');
  assert.ok(!state.calls.includes('append')); assert.equal(success(await state.read()).requestRevision, 0);
});

test('request and authenticated identity are captured before their asynchronous owners can mutate them', async () => {
  const state = setup(); const body = appendRequest(); const user = { userId: 'alice' };
  state.deps.authenticate = async () => {
    body.caseId = 'case-bob'; body.update.note = 'PRIVATE changed input'; await Promise.resolve(); return user;
  };
  state.deps.loadRegistry = async () => { user.userId = 'bob'; await Promise.resolve(); return [{ ...demoProgram, programId: PROGRAM, isDemo: false }]; };
  const saved = success(await state.append(body));
  assert.equal(saved.caseId, 'case-alice'); assert.equal(saved.events[0].note, null);
  assert.equal((await state.repository.readRequestHistoryForUser({ ...binding, userId: 'bob' })).status, 'not_found');
});

test('repository results and inputs are detached and response substitutions are rejected', async () => {
  const state = setup(); const saved = success(await state.append());
  saved.events[0].note = 'PRIVATE changed response'; saved.caseId = 'changed';
  assert.equal(success(await state.read()).events[0].note, null);
  const good = await state.repository.readRequestHistoryForUser(binding); assert.equal(good.status, 'found');
  if (good.status !== 'found') throw new Error('Fixture setup failed.');
  state.deps.cases.readRequestHistoryForUser = async input => { input.caseId = 'case-bob'; return good; };
  assert.equal(success(await state.read()).caseId, 'case-alice');
  for (const history of [{ ...good.history, caseId: 'case-bob' }, { ...good.history, caseRevision: 2 },
    { ...good.history, programId: 'changed' }, { ...good.history, ownerId: 'PRIVATE' },
    { ...good.history, events: [{ ...good.history.events[0], recordedBy: 'PRIVATE' }] }]) {
    state.deps.cases.readRequestHistoryForUser = async () => ({ status: 'found', history });
    failure(await state.read(), 500, 'INTERNAL_ERROR');
  }
});

test('append adapters cannot acknowledge a substituted update or mutate the expected request', async () => {
  for (const mutate of [(input: RequestHistoryAppendInput) => { input.update.note = 'PRIVATE substituted'; },
    (input: RequestHistoryAppendInput) => { input.update.updateId = NEXT_ID; },
    (input: RequestHistoryAppendInput) => { input.expectedRequestRevision = 1; }]) {
    const state = setup();
    state.deps.cases.appendRequestUpdateForUser = async input => {
      mutate(input); await Promise.resolve();
      return { status: 'found', history: found(appendRequestHistory(emptyRequestHistory(binding), { ...input, expectedRequestRevision: 0 })) };
    };
    const result = await state.append();
    if (result.status === 200) assert.equal(success(result).events[0].note, null);
    else failure(result, 500, 'INTERNAL_ERROR');
  }
});

test('simultaneous different updates cannot overwrite each other while identical retries return one event', async () => {
  const state = setup();
  const simultaneous = await Promise.all([state.append(), state.append(appendRequest({ update: update({ updateId: NEXT_ID }) }))]);
  assert.deepEqual(simultaneous.map(result => result.status).sort(), [200, 409]);
  failure(simultaneous.find(result => result.status === 409)!, 409, 'REQUEST_REVISION_MISMATCH');
  const same = setup(); const retries = await Promise.all([same.append(), same.append()]);
  assert.deepEqual(retries.map(result => success(result).requestRevision), [1, 1]);
  assert.equal(success(await same.read()).events.length, 1);
});

test('uncertain writes recover with the same update ID even after another event was appended', async () => {
  const state = setup();
  state.deps.cases.appendRequestUpdateForUser = async input => {
    await state.repository.appendRequestUpdateForUser(input); throw new Error('PRIVATE response lost');
  };
  failure(await state.append(), 503, 'SERVICE_UNAVAILABLE');
  state.deps.cases = state.repository;
  success(await state.append(appendRequest({ expectedRequestRevision: 1, update: update({ updateId: NEXT_ID, status: 'submitted' }) })));
  const recovered = success(await state.append()); assert.equal(recovered.requestRevision, 2);
  failure(await state.append(appendRequest({ update: update({ note: 'Edited retry' }) })), 409, 'REQUEST_UPDATE_CONFLICT');
  assert.equal(success(await state.read()).requestRevision, 2);
});

test('case edits preserve history but require a fresh case revision and record each event’s saved case revision', async () => {
  const state = setup(); const first = success(await state.append());
  const { revision, ...draft } = snapshot();
  assert.equal((await state.repository.replaceIfCurrent('alice', 'case-alice', revision,
    { ...draft, profile: { ...draft.profile, city: 'PRIVATE corrected city' } })).status, 'saved');
  failure(await state.read(), 409, 'CASE_REVISION_MISMATCH');
  failure(await state.append(), 409, 'CASE_REVISION_MISMATCH');
  const resumed = success(await state.read({ ...readRequest, expectedCaseRevision: 2 }));
  assert.equal(resumed.caseRevision, 2); assert.deepEqual(resumed.events, first.events);
  const second = success(await state.append(appendRequest({ expectedCaseRevision: 2, expectedRequestRevision: 1,
    update: update({ updateId: NEXT_ID, status: 'needs_information', nextAction: 'Call the fictional program', responsibleParty: 'resident' }) })));
  assert.deepEqual(second.events.map(event => event.caseRevision), [1, 2]);
  failure(await state.append(appendRequest({ expectedCaseRevision: 2 })), 409, 'REQUEST_UPDATE_CONFLICT');
});

test('manual tracking does not change saved case, matching, answers, evidence or private draft exports', async () => {
  const state = setup(); const independent = await seedIndependentOutputs(state.repository);
  success(await state.append(appendRequest({ expectedCaseRevision: 2, update: update({ status: 'approved' }) })));
  assert.deepEqual(await independent.inspect(), independent.before);
});

test('memory bounds histories per case to four program streams and retain exact retry at both limits', async () => {
  const state = setup();
  for (let program = 0; program < 4; program++) {
    assert.equal((await state.repository.appendRequestUpdateForUser(appendInput({ programId: `program-${program}` }))).status, 'found');
  }
  assert.equal((await state.repository.appendRequestUpdateForUser(appendInput({ programId: 'program-4' }))).status, 'quota_exceeded');
  assert.equal((await state.repository.readRequestHistoryForUser({ ...binding, programId: 'program-4' })).status, 'found');
  for (let index = 1; index < 50; index++) {
    assert.equal((await state.repository.appendRequestUpdateForUser(appendInput({ programId: 'program-0', expectedRequestRevision: index,
      update: update({ updateId: `01000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}` }) }))).status, 'found');
  }
  assert.equal((await state.repository.appendRequestUpdateForUser(appendInput({ programId: 'program-0', expectedRequestRevision: 50,
    update: update({ updateId: '01000000-0000-4000-8000-000000000051' }) }))).status, 'quota_exceeded');
  const retried = await state.repository.appendRequestUpdateForUser(appendInput({ programId: 'program-0' }));
  assert.equal(found(retried).requestRevision, 50);
});

test('repository failures map to sanitized errors and closed accounts cannot read or append', async () => {
  const state = setup();
  for (const [status, http, code] of [['not_found', 404, 'CASE_NOT_FOUND'], ['conflict', 409, 'CASE_REVISION_MISMATCH'],
    ['request_conflict', 409, 'REQUEST_REVISION_MISMATCH'], ['update_conflict', 409, 'REQUEST_UPDATE_CONFLICT'],
    ['quota_exceeded', 409, 'REQUEST_HISTORY_FULL']] as const) {
    state.deps.cases.readRequestHistoryForUser = async () => ({ status });
    failure(await state.read(), http, code); failure(await state.append(), http, code);
  }
  state.deps.cases.readRequestHistoryForUser = async () => { throw new AccountClosedError(); };
  failure(await state.read(), 401, 'UNAUTHENTICATED'); failure(await state.append(), 401, 'UNAUTHENTICATED');
  state.deps.cases.readRequestHistoryForUser = async () => { throw new Error('PRIVATE connection string'); };
  failure(await state.read(), 503, 'SERVICE_UNAVAILABLE');
  state.deps.authenticate = async () => { throw new AccountClosedError(); };
  failure(await state.append(), 401, 'UNAUTHENTICATED');
  state.deps.authenticate = async () => { throw new Error('PRIVATE access token'); };
  failure(await state.append(), 503, 'SERVICE_UNAVAILABLE');
});

test('registry adapter failures and malformed configuration do not append or leak internals', async () => {
  const state = setup();
  state.deps.loadRegistry = async () => { throw new Error('PRIVATE program source'); };
  failure(await state.append(), 503, 'SERVICE_UNAVAILABLE');
  state.deps.loadRegistry = async () => [{ ...demoProgram, programId: PROGRAM }, { ...demoProgram, programId: PROGRAM }];
  failure(await state.append(), 500, 'INTERNAL_ERROR');
  assert.ok(!state.calls.includes('append')); assert.equal(success(await state.read()).requestRevision, 0);
});
