import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import type { AddressInfo } from 'node:net';
import { createDemoFormArtifact } from '../fixtures/demo-form-template.ts';
import { demoProgram } from '../fixtures/demo-program.ts';
import { createFormAnswerContext } from '../src/forms/form-answers.ts';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { handleReadCase, type ReadCaseDependencies, type ReadCaseErrorCode, type ReadCaseResult } from '../src/api/read-case.ts';
import type { CaseSnapshot } from '../src/types.ts';

const NOW = '2026-10-17T22:00:00.000Z';
const request = { schemaVersion: '1', caseId: 'read-case-alice' };

function snapshot(caseId = request.caseId): CaseSnapshot {
  return { schemaVersion: '1', caseId, revision: 1,
    profile: { city: 'Fictional City', county: null, healthPlan: null, tenure: 'renter',
      ageYears: null, householdSize: null, annualIncomeUsd: 0, ownerConsentReported: false },
    unresolvedFields: [], findings: [] };
}

function setup(value = snapshot()) {
  const repository = new MemoryCaseRepository([{ userId: 'alice', snapshot: value },
    { userId: 'bob', snapshot: snapshot('read-case-bob') }]);
  const calls: string[] = [];
  const deps: ReadCaseDependencies = {
    authenticate: async token => {
      calls.push('authenticate');
      return token === 'alice-token' ? { userId: 'alice' } : token === 'bob-token' ? { userId: 'bob' } : null;
    },
    cases: { loadForUser: async (...args) => { calls.push('load'); return repository.loadForUser(...args); } },
    now: () => new Date(NOW),
  };
  const send = (body: unknown = { ...request, caseId: value.caseId }, bearerToken: string | null = 'alice-token') =>
    handleReadCase({ body, bearerToken }, deps);
  return { repository, deps, calls, send };
}

function success(result: ReadCaseResult): CaseSnapshot {
  assert.equal(result.status, 200); assert.ok('profile' in result.body);
  assert.equal(result.headers['Cache-Control'], 'no-store'); return result.body;
}

function error(result: ReadCaseResult, status: number, code: ReadCaseErrorCode) {
  assert.equal(result.status, status); assert.ok('error' in result.body);
  assert.equal(result.body.error.code, code); assert.equal(result.headers['Cache-Control'], 'no-store');
}

test('owner can reload the exact current case without knowing its revision', async () => {
  const value = { ...snapshot(), revision: 42 };
  const state = setup(value);
  const result = success(await state.send());
  assert.deepEqual(result, value);
  assert.deepEqual(Object.keys(result).sort(), ['schemaVersion', 'caseId', 'revision', 'profile', 'unresolvedFields', 'findings'].sort());
  result.profile.city = 'changed returned value';
  assert.equal((await state.repository.loadForUser('alice', value.caseId))!.profile.city, value.profile.city);
});

test('authentication precedes request validation and any private case read', async () => {
  for (const token of [null, '', 'bad token', 'unknown-token']) {
    const state = setup(); const result = await state.send({ ownerId: 'alice' }, token);
    error(result, 401, 'UNAUTHENTICATED');
    assert.equal(result.headers['WWW-Authenticate'], 'Bearer'); assert.ok(!state.calls.includes('load'));
  }
});

test('missing cases and another owner have indistinguishable safe errors', async () => {
  const state = setup();
  const denied = await state.send(request, 'bob-token');
  const missing = await state.send({ ...request, caseId: 'missing' });
  assert.deepEqual(denied, missing); error(denied, 404, 'CASE_NOT_FOUND');
  assert.equal(success(await state.send({ ...request, caseId: 'read-case-bob' }, 'bob-token')).caseId, 'read-case-bob');
});

test('requests reject caller metadata, expected revisions, invalid IDs and unsupported shapes', async () => {
  const state = setup();
  for (const body of [null, [], {}, { ...request, schemaVersion: '2' },
    ...['owner', 'userId', 'expectedCaseRevision', 'profile', 'updatedAt'].map(key => ({ ...request, [key]: 'override' })),
    ...['', ' ', ' leading', 'trailing ', 'x'.repeat(201), '\ud800', 'a\0b', 'a\u2028b', 'a\u2029b'].map(caseId => ({ ...request, caseId }))]) {
    error(await state.send(body), 400, 'INVALID_REQUEST');
  }
  assert.ok(!state.calls.includes('load'));
  const unicode = snapshot('🙂'.repeat(200));
  assert.equal(success(await setup(unicode).send()).caseId, unicode.caseId);
});

test('dependency failures are sanitized and malformed authentication identities fail closed', async () => {
  for (const stage of ['auth', 'load']) {
    const state = setup(); const broken = async () => { throw new Error('PRIVATE ACCESS TOKEN'); };
    if (stage === 'auth') state.deps.authenticate = broken; else state.deps.cases.loadForUser = broken;
    const result = await state.send(); error(result, 503, 'SERVICE_UNAVAILABLE');
    assert.ok(!JSON.stringify(result).includes('PRIVATE'));
  }
  for (const user of [undefined, {}, { userId: '' }, { userId: ' actor ' }, { userId: '\ud800' }]) {
    const state = setup(); state.deps.authenticate = async () => user as never;
    error(await state.send(), 500, 'INTERNAL_ERROR'); assert.ok(!state.calls.includes('load'));
  }
});

test('all stored case fields are validated before returning a response', async () => {
  for (const mutation of [
    (value: any) => { value.caseId = 'private-other-case'; },
    (value: any) => { value.revision = 0; },
    (value: any) => { value.revision = Number.MAX_SAFE_INTEGER + 1; },
    (value: any) => { value.profile.ownerConsentReported = 'false'; },
    (value: any) => { value.profile.annualIncomeUsd = Infinity; },
    (value: any) => { value.unresolvedFields = [123]; },
    (value: any) => { value.findings = [{ private: 'PRIVATE MALFORMED FINDING' }]; },
    (value: any) => { value.extra = 'PRIVATE UNEXPECTED FIELD'; },
  ]) {
    const state = setup(); const value = snapshot(); mutation(value);
    state.deps.cases.loadForUser = async () => value;
    const result = await state.send(); error(result, 500, 'INTERNAL_ERROR');
    assert.ok(!JSON.stringify(result).includes('PRIVATE'));
  }
});

test('invalid server clocks fail closed without exposing the loaded case', async () => {
  for (const clock of [() => new Date('invalid'), () => ({}) as Date, () => new Date('+010000-01-01T00:00:00Z'),
    () => { throw new Error('PRIVATE CLOCK FAILURE'); }]) {
    const state = setup(); state.deps.now = clock;
    const result = await state.send(); error(result, 500, 'INTERNAL_ERROR');
    assert.ok(!JSON.stringify(result).includes('Fictional City'));
  }
});

test('request, authentication and stored objects cannot be retargeted across the repository await', async () => {
  const state = setup(); const body = { ...request }; const user = { userId: 'alice' }; const stored = snapshot();
  state.deps.authenticate = async () => user;
  state.deps.cases.loadForUser = async (userId, caseId) => {
    assert.equal(userId, 'alice'); assert.equal(caseId, request.caseId);
    await Promise.resolve(); body.caseId = 'read-case-bob'; user.userId = 'bob';
    return stored;
  };
  state.deps.now = () => {
    stored.profile.city = 'PRIVATE LATE ADAPTER MUTATION';
    return new Date(NOW);
  };
  const result = success(await state.send(body));
  assert.equal(result.caseId, request.caseId); assert.equal(result.profile.city, 'Fictional City');
});

async function start(t: TestContext) {
  const state = setup();
  const form = await createDemoFormArtifact(demoProgram.programId);
  const common = { authenticate: state.deps.authenticate, cases: state.repository, now: state.deps.now,
    loadRegistry: async () => [structuredClone(demoProgram)], allowDemoPrograms: true };
  const formDeps = { ...common, loadFormTemplate: async (programId: string) => programId === demoProgram.programId ? form : null };
  const server = createMatchingServer(common, formDeps, formDeps);
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve()); server.closeAllConnections();
  }));
  return { ...state, form, base: `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1` };
}

const send = (endpoint: string, body: unknown, token = 'alice-token') => fetch(endpoint, {
  method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
});

test('HTTP case read supports recovery without consuming the prior save result or guessing a revision', async t => {
  const state = await start(t);
  const saveBody = { schemaVersion: '1', caseId: request.caseId, expectedCaseRevision: 1,
    programId: demoProgram.programId, expectedFormContextId: createFormAnswerContext(state.form.template).formContextId,
    expectedAnswerRevision: 0, answers: [{ key: 'memberFirstName', value: 'Fictional Updated Name', reviewState: 'reviewed' }] };
  const ignoredSave = await send(`${state.base}/save-form-answers`, saveBody);
  await ignoredSave.body?.cancel();
  const loaded = await send(`${state.base}/read-case`, request);
  assert.equal(loaded.status, 200); assert.equal(loaded.headers.get('cache-control'), 'no-store');
  assert.equal(loaded.headers.get('x-content-type-options'), 'nosniff');
  const current: CaseSnapshot = await loaded.json();
  assert.equal(current.revision, 2);
  const answers = await send(`${state.base}/read-form-answers`, { ...request,
    expectedCaseRevision: current.revision, programId: demoProgram.programId });
  assert.equal(answers.status, 200);
  const currentAnswers = await answers.json();
  assert.equal(currentAnswers.isCurrent, true); assert.equal(currentAnswers.saved.answerRevision, 1);
  assert.equal(currentAnswers.saved.answers[0].value, 'Fictional Updated Name');
  assert.equal((await send(`${state.base}/save-form-answers`, saveBody)).status, 409);
  assert.equal((await send(`${state.base}/read-case`, request, 'bob-token')).status, 404);
  assert.ok(!JSON.stringify(current).includes('Fictional Updated Name'));
});

test('HTTP case read preserves fixed routes, authentication, methods and JSON restrictions', async t => {
  const state = await start(t); const endpoint = `${state.base}/read-case`;
  const unsigned = await fetch(endpoint, { method: 'POST' });
  assert.equal(unsigned.status, 401); assert.equal(unsigned.headers.get('www-authenticate'), 'Bearer');
  const method = await fetch(endpoint); assert.equal(method.status, 405); assert.equal(method.headers.get('allow'), 'POST');
  assert.equal((await send(`${endpoint}?owner=alice`, request)).status, 404);
  assert.equal((await send(endpoint, { ...request, expectedCaseRevision: 1 })).status, 400);
  assert.equal((await fetch(endpoint, { method: 'POST', headers: { Authorization: 'Bearer alice-token', 'Content-Type': 'text/plain' }, body: '{}' })).status, 415);
});
