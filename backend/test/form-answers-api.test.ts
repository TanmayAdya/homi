import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test, { type TestContext } from 'node:test';
import type { AddressInfo } from 'node:net';
import { demoProgram } from '../fixtures/demo-program.ts';
import { createFormAnswerContext, createSavedFormAnswers, type FormAnswerInput } from '../src/forms/form-answers.ts';
import { createScfhpEaaFormTemplate } from '../src/forms/scfhp-eaa-template.ts';
import {
  handleReadFormAnswers, handleSaveFormAnswers, type FormAnswerDependencies, type FormAnswerErrorCode,
  type FormAnswerResult, type FormAnswerSaveInput, type FormAnswersResponse,
} from '../src/api/form-answers.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { createMatchingServer, MAX_REQUEST_BYTES } from '../src/api/http-server.ts';
import type { CaseSnapshot } from '../src/types.ts';

const NOW = '2026-10-17T22:00:00.000Z';
const PROGRAM = 'scfhp-eaa';
const answer: FormAnswerInput = { key: 'memberFirstName', value: 'Fictional Alice', reviewState: 'reviewed' };
const readRequest = { schemaVersion: '1', caseId: 'form-alice', expectedCaseRevision: 1, programId: PROGRAM };

function makeCase(caseId = 'form-alice'): CaseSnapshot {
  return { schemaVersion: '1', caseId, revision: 1,
    profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null,
      householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
}

function fixtureForm() {
  const bytes = Buffer.from('%PDF-1.7\nSynthetic bytes for API hash validation only.\n');
  const sha = createHash('sha256').update(bytes).digest('hex');
  const template = { ...createScfhpEaaFormTemplate(), templateSha256: sha, formVersion: `sha256:${sha}` };
  return { template, bytes: Uint8Array.from(bytes) };
}

function setup(snapshot = makeCase()) {
  const repository = new MemoryCaseRepository([{ userId: 'alice', snapshot }, { userId: 'bob', snapshot: makeCase('form-bob') }]);
  const form = fixtureForm();
  const calls: string[] = [];
  const saves: FormAnswerSaveInput[] = [];
  let now = NOW;
  const deps: FormAnswerDependencies = {
    authenticate: async token => {
      calls.push('authenticate');
      return token === 'alice-token' ? { userId: 'alice' } : token === 'bob-token' ? { userId: 'bob' } : null;
    },
    cases: {
      loadForUser: async (...args) => { calls.push('load'); return repository.loadForUser(...args); },
      loadFormAnswersForUser: (...args) => repository.loadFormAnswersForUser(...args),
      readFormAnswersIfCurrent: async input => { calls.push('read'); return repository.readFormAnswersIfCurrent(input); },
      saveFormAnswersIfCurrent: async input => { calls.push('save'); saves.push(structuredClone(input)); return repository.saveFormAnswersIfCurrent(input); },
    },
    loadFormTemplate: async programId => { calls.push('form'); return programId === PROGRAM ? form : null; },
    now: () => new Date(now),
  };
  const saveRequest = (overrides: Record<string, unknown> = {}) => ({ ...readRequest,
    caseId: snapshot.caseId, expectedFormContextId: createFormAnswerContext(form.template).formContextId,
    expectedAnswerRevision: 0, answers: [structuredClone(answer)], ...overrides });
  const read = (body: unknown = { ...readRequest, caseId: snapshot.caseId }, bearerToken: string | null = 'alice-token') =>
    handleReadFormAnswers({ body, bearerToken }, deps);
  const save = (body: unknown = saveRequest(), bearerToken: string | null = 'alice-token') =>
    handleSaveFormAnswers({ body, bearerToken }, deps);
  return { repository, form, calls, saves, deps, read, save, saveRequest, setNow: (value: string) => { now = value; } };
}

function success(result: FormAnswerResult): FormAnswersResponse {
  assert.equal(result.status, 200);
  assert.ok('context' in result.body);
  assert.equal(result.headers['Cache-Control'], 'no-store');
  return result.body;
}

function error(result: FormAnswerResult, status: number, code: FormAnswerErrorCode) {
  assert.equal(result.status, status);
  assert.ok('error' in result.body);
  assert.equal(result.body.error.code, code);
  assert.equal(result.headers['Cache-Control'], 'no-store');
}

test('read returns exact current form context and no fabricated answer set', async () => {
  const state = setup();
  assert.deepEqual(success(await state.read()), { schemaVersion: '1', caseId: 'form-alice', caseRevision: 1,
    context: createFormAnswerContext(state.form.template), saved: null, isCurrent: false });
  assert.deepEqual(await state.repository.loadForUser('alice', 'form-alice'), makeCase());
});

test('save assigns actor/time and atomically advances both answer and case revisions', async () => {
  const state = setup();
  await state.repository.saveMatchIfCurrent('alice', 'form-alice', 1, {
    schemaVersion: '1', caseId: 'form-alice', caseRevision: 1, evaluatedAt: NOW, evaluationDate: NOW.slice(0, 10), matches: [],
  });
  const result = success(await state.save());
  assert.equal(result.caseRevision, 2); assert.equal(result.isCurrent, true);
  assert.equal(result.saved!.caseRevision, 2); assert.equal(result.saved!.answerRevision, 1);
  assert.equal(result.saved!.updatedBy, 'alice'); assert.equal(result.saved!.updatedAt, NOW);
  assert.deepEqual(result.saved!.answers, [{ ...answer, reviewedBy: 'alice', reviewedAt: NOW }]);
  assert.deepEqual(await state.repository.loadForUser('alice', 'form-alice'), { ...makeCase(), revision: 2 });
  assert.equal(await state.repository.readSavedMatchForUser('alice', 'form-alice'), null);
  error(await state.read(), 409, 'CASE_REVISION_MISMATCH');
  assert.deepEqual(success(await state.read({ ...readRequest, expectedCaseRevision: 2 })), result);
});

test('replacement can remove prior review, omit fields and clear all answers while bumping case freshness', async () => {
  const state = setup();
  success(await state.save());
  const changed = success(await state.save(state.saveRequest({ expectedCaseRevision: 2, expectedAnswerRevision: 1,
    answers: [{ ...answer, value: 'Fictional Edit', reviewState: 'needs_review' }] })));
  assert.deepEqual(changed.saved!.answers, [{ ...answer, value: 'Fictional Edit', reviewState: 'needs_review', reviewedAt: null, reviewedBy: null }]);
  const cleared = success(await state.save(state.saveRequest({ expectedCaseRevision: 3, expectedAnswerRevision: 2, answers: [] })));
  assert.equal(cleared.caseRevision, 4); assert.equal(cleared.saved!.answerRevision, 3);
  assert.deepEqual(cleared.saved!.answers, []);
});

test('clock rollback across requests cannot replace answers or advance the case', async () => {
  const state = setup(); const first = success(await state.save());
  state.setNow('2026-10-17T21:59:59.999Z');
  error(await state.save(state.saveRequest({ expectedCaseRevision: 2, expectedAnswerRevision: 1,
    answers: [{ ...answer, value: 'Must not replace the prior answer' }] })), 503, 'SERVICE_UNAVAILABLE');
  assert.deepEqual(await state.repository.loadFormAnswersForUser('alice', 'form-alice', PROGRAM), first.saved);
  assert.equal((await state.repository.loadForUser('alice', 'form-alice'))!.revision, 2);
});

test('authentication precedes request validation and all private reads', async () => {
  for (const token of [null, '', 'bad token', 'invalid-token']) {
    const state = setup();
    for (const operation of [state.read, state.save]) {
      error(await operation({ private: 'not-a-request' }, token), 401, 'UNAUTHENTICATED');
    }
    assert.ok(!state.calls.includes('load')); assert.ok(!state.calls.includes('form'));
  }
});

test('an authentication adapter object cannot change the authorized actor during form loading', async () => {
  const state = setup(); const user = { userId: 'alice' };
  state.deps.authenticate = async () => user;
  state.deps.loadFormTemplate = async () => {
    await Promise.resolve(); user.userId = 'bob'; return state.form;
  };
  const saved = success(await state.save());
  assert.equal(saved.saved!.updatedBy, 'alice');
  assert.equal(saved.saved!.answers[0].reviewedBy, 'alice');
  assert.equal((await state.repository.loadForUser('alice', 'form-alice'))!.revision, 2);
  assert.equal(await state.repository.loadFormAnswersForUser('bob', 'form-alice', PROGRAM), null);
});

test('another owner sees the same case-not-found response and cannot access saved values', async () => {
  const state = setup(); success(await state.save());
  const body = { ...readRequest, expectedCaseRevision: 2 };
  const denied = await state.read(body, 'bob-token');
  const missing = await state.read({ ...body, caseId: 'missing' });
  assert.deepEqual(denied, missing); error(denied, 404, 'CASE_NOT_FOUND');
  error(await state.save(state.saveRequest({ expectedCaseRevision: 2, expectedAnswerRevision: 1 }), 'bob-token'), 404, 'CASE_NOT_FOUND');
  assert.equal(await state.repository.loadFormAnswersForUser('bob', 'form-alice', PROGRAM), null);
});

test('strict requests reject metadata injection, invalid IDs, revisions and context fingerprints', async () => {
  const state = setup();
  const invalid = [null, [], {}, { ...readRequest, schemaVersion: '2' }, { ...readRequest, updatedBy: 'alice' },
    ...['', ' ', ' leading', 'trailing ', 'x'.repeat(201), '\ud800', 'line\u2028separator', 'line\u2029separator', 'control\u0000'].map(caseId => ({ ...readRequest, caseId })),
    ...[0, -1, 1.5, '1', Number.MAX_SAFE_INTEGER + 1].map(expectedCaseRevision => ({ ...readRequest, expectedCaseRevision }))];
  for (const body of invalid) error(await state.read(body), 400, 'INVALID_REQUEST');
  for (const override of [
    { expectedFormContextId: 'a'.repeat(63) }, { expectedFormContextId: 'A'.repeat(64) },
    { expectedFormContextId: `${'a'.repeat(64)}\n` }, { expectedAnswerRevision: -1 }, { expectedAnswerRevision: 1.5 },
    { expectedAnswerRevision: '0' }, { ownerId: 'alice' }, { reviewedAt: NOW }, { formVersion: 'client-version' },
  ]) error(await state.save(state.saveRequest(override)), 400, 'INVALID_REQUEST');
  assert.ok(!state.calls.includes('load')); assert.equal(state.saves.length, 0);
});

test('unknown/protected/duplicate answers and client review provenance cannot be persisted', async () => {
  const state = setup();
  for (const answers of [null, {}, [{ ...answer, key: 'diagnosis' }], [{ ...answer, key: 'ha' }],
    [answer, answer], [{ ...answer, reviewedAt: NOW }], [{ ...answer, reviewedBy: 'professional' }],
    [{ ...answer, value: null }], [{ ...answer, value: ' ' }], [{ ...answer, value: 'x'.repeat(161) }],
    [{ ...answer, reviewState: 'approved' }]]) {
    error(await state.save(state.saveRequest({ answers })), 400, 'INVALID_REQUEST');
  }
  assert.equal(state.saves.length, 0);
  assert.equal((await state.repository.loadForUser('alice', 'form-alice'))!.revision, 1);
});

test('server-date validation rejects future supplied dates with 400 and no write', async () => {
  const state = setup();
  for (const key of ['memberBirthDate', 'referralDate']) {
    error(await state.save(state.saveRequest({ answers: [{ key, value: '2026-10-18', reviewState: 'reviewed' }] })), 400, 'INVALID_REQUEST');
  }
  assert.equal(state.saves.length, 0);
});

test('unknown forms, stale context and stale answer revision are distinct recoverable failures', async () => {
  const state = setup();
  error(await state.read({ ...readRequest, programId: 'unavailable' }), 404, 'FORM_NOT_AVAILABLE');
  error(await state.save(state.saveRequest({ expectedFormContextId: 'a'.repeat(64) })), 409, 'FORM_CONTEXT_MISMATCH');
  error(await state.save(state.saveRequest({ expectedAnswerRevision: 1 })), 409, 'FORM_ANSWERS_CONFLICT');
  assert.equal((await state.repository.loadForUser('alice', 'form-alice'))!.revision, 1);
});

test('same-version template changes leave prior answers readable but explicitly stale', async () => {
  const state = setup(); const before = success(await state.save());
  state.form.template = { ...state.form.template, publisherRevision: 'changed metadata, same mapping version' };
  const loaded = success(await state.read({ ...readRequest, expectedCaseRevision: 2 }));
  assert.equal(loaded.isCurrent, false); assert.deepEqual(loaded.saved, before.saved);
  assert.notEqual(loaded.context.formContextId, before.context.formContextId);
  error(await state.save(state.saveRequest({ expectedCaseRevision: 2, expectedAnswerRevision: 1,
    expectedFormContextId: before.context.formContextId })), 409, 'FORM_CONTEXT_MISMATCH');
  const replaced = success(await state.save(state.saveRequest({ expectedCaseRevision: 2, expectedAnswerRevision: 1, answers: [] })));
  assert.equal(replaced.isCurrent, true); assert.equal(replaced.caseRevision, 3);
});

test('older case-bound answers are returned as stale without copying review to the new revision', async () => {
  const state = setup(); const saved = success(await state.save()).saved!;
  state.deps.cases.loadForUser = async () => ({ ...makeCase(), revision: 3 });
  state.deps.cases.readFormAnswersIfCurrent = async () => ({ status: 'found', saved });
  const result = success(await state.read({ ...readRequest, expectedCaseRevision: 3 }));
  assert.equal(result.isCurrent, false); assert.equal(result.saved!.caseRevision, 2);
});

test('current-context records cannot contain keys unsupported by that template, while stale contexts remain readable', async () => {
  const state = setup();
  state.form.template = { ...state.form.template, fields: state.form.template.fields.map(field =>
    field.binding.kind === 'reviewed_answer' && field.binding.answerKey !== 'memberFirstName'
      ? { ...field, binding: { kind: 'manual' as const, reason: 'not_collected' as const, resolvedBy: 'resident' as const } }
      : field) };
  const record = createSavedFormAnswers({ snapshot: makeCase(), context: createFormAnswerContext(state.form.template),
    answerRevision: 1, answers: [{ key: 'memberLastName', value: 'PRIVATE UNSUPPORTED NAME', reviewState: 'reviewed' }],
    updatedAt: NOW, updatedBy: 'alice' });
  state.deps.cases.readFormAnswersIfCurrent = async () => ({ status: 'found', saved: record });
  const result = await state.read(); error(result, 500, 'INTERNAL_ERROR');
  assert.ok(!JSON.stringify(result).includes('PRIVATE UNSUPPORTED NAME'));
  record.formContextId = 'b'.repeat(64);
  const stale = success(await state.read());
  assert.equal(stale.isCurrent, false); assert.deepEqual(stale.saved, record);
});

test('concurrent replacements cannot both overwrite the same case and answer revisions', async () => {
  const state = setup();
  const results = await Promise.all([state.save(), state.save()]);
  assert.deepEqual(results.map(result => result.status).sort(), [200, 409]);
  error(results.find(result => result.status === 409)!, 409, 'CASE_REVISION_MISMATCH');
  assert.equal((await state.repository.loadForUser('alice', 'form-alice'))!.revision, 2);
  assert.equal((await state.repository.loadFormAnswersForUser('alice', 'form-alice', PROGRAM))!.answerRevision, 1);
});

test('ownership and revision are rechecked atomically after asynchronous form loading', async () => {
  for (const status of ['not_found', 'conflict'] as const) {
    const state = setup();
    state.deps.cases.readFormAnswersIfCurrent = async () => ({ status });
    state.deps.cases.saveFormAnswersIfCurrent = async () => ({ status });
    for (const operation of [state.read, state.save]) {
      error(await operation(), status === 'not_found' ? 404 : 409,
        status === 'not_found' ? 'CASE_NOT_FOUND' : 'CASE_REVISION_MISMATCH');
    }
    assert.equal((await state.repository.loadForUser('alice', 'form-alice'))!.revision, 1);
  }
});

test('template loader changes across awaits are rejected before any answer write', async () => {
  const state = setup(); let calls = 0;
  state.deps.loadFormTemplate = async () => ++calls === 1 ? state.form : {
    ...state.form, template: { ...state.form.template, publisherRevision: 'different' },
  };
  error(await state.save(), 409, 'FORM_CONTEXT_MISMATCH');
  assert.equal(state.saves.length, 0);
});

test('operational failures return sanitized 503 and malformed server artifacts return 500', async () => {
  for (const stage of ['auth', 'load', 'form', 'read', 'save']) {
    const state = setup(); const broken = async () => { throw new Error('PRIVATE INTERNAL VALUE'); };
    if (stage === 'auth') state.deps.authenticate = broken;
    if (stage === 'load') state.deps.cases.loadForUser = broken;
    if (stage === 'form') state.deps.loadFormTemplate = broken;
    if (stage === 'read') state.deps.cases.readFormAnswersIfCurrent = broken;
    if (stage === 'save') state.deps.cases.saveFormAnswersIfCurrent = broken;
    const result = await (stage === 'read' ? state.read() : state.save());
    error(result, 503, 'SERVICE_UNAVAILABLE'); assert.ok(!JSON.stringify(result).includes('PRIVATE'));
  }
  for (const change of ['bytes', 'oversized', 'program', 'shape', 'future-review']) {
    const state = setup();
    if (change === 'bytes') state.form.bytes.fill(0);
    if (change === 'oversized') state.form.bytes = new Uint8Array(5 * 1024 * 1024 + 1);
    if (change === 'program') state.form.template = { ...state.form.template, programId: 'different' };
    if (change === 'shape') state.deps.loadFormTemplate = async () => undefined as never;
    if (change === 'future-review') state.form.template = { ...state.form.template, reviewedOn: '2026-10-18' };
    error(await state.save(), 500, 'INTERNAL_ERROR');
    assert.equal(state.saves.length, 0);
  }
});

test('read refuses adapter records from another case, actor or future version', async () => {
  for (const overrides of [{ caseId: 'another-case' }, { updatedBy: 'bob' }, { caseRevision: 3 },
    { unexpectedPrivateData: 'PRIVATE VALUE' }, { updatedAt: '2026-10-18T22:00:00Z' }]) {
    const state = setup();
    const saved = createSavedFormAnswers({ snapshot: makeCase(), context: createFormAnswerContext(state.form.template),
      answerRevision: 1, answers: [answer], updatedAt: NOW, updatedBy: 'alice' });
    state.deps.cases.readFormAnswersIfCurrent = async () => ({ status: 'found', saved: { ...saved, ...overrides } });
    const result = await state.read(); error(result, 500, 'INTERNAL_ERROR');
    assert.ok(!JSON.stringify(result).includes('PRIVATE VALUE'));
  }
});

test('save refuses adapter substitution, extra data or an inconsistent case revision', async () => {
  for (const change of ['value', 'extra', 'case-revision']) {
    const state = setup();
    state.deps.cases.saveFormAnswersIfCurrent = async input => {
      const saved = structuredClone(input.answers);
      if (change === 'value') saved.answers[0].value = 'WRONG PRIVATE VALUE';
      if (change === 'extra') (saved as unknown as Record<string, unknown>).extra = 'WRONG PRIVATE VALUE';
      return { status: 'saved', saved, caseRevision: input.revision + (change === 'case-revision' ? 2 : 1) };
    };
    const result = await state.save(); error(result, 500, 'INTERNAL_ERROR');
    assert.ok(!JSON.stringify(result).includes('WRONG PRIVATE VALUE'));
  }
});

test('an adapter cannot mutate the expected server answer values during its await', async () => {
  const state = setup();
  state.deps.cases.saveFormAnswersIfCurrent = async input => {
    input.answers.answers[0].value = 'MUTATED PRIVATE VALUE';
    return { status: 'saved', saved: input.answers, caseRevision: input.revision + 1 };
  };
  const result = await state.save(); error(result, 500, 'INTERNAL_ERROR');
  assert.ok(!JSON.stringify(result).includes('MUTATED PRIVATE VALUE'));
});

test('saved inputs and owner reads are detached; malformed replacements leave both stores unchanged', async () => {
  const state = setup(); const result = success(await state.save());
  result.saved!.answers[0].value = 'changed returned response';
  state.saves[0].answers.answers[0].value = 'changed captured input';
  const loaded = (await state.repository.loadFormAnswersForUser('alice', 'form-alice', PROGRAM))!;
  assert.equal(loaded.answers[0].value, answer.value);
  loaded.answers[0].value = 'changed repository output';
  assert.equal((await state.repository.loadFormAnswersForUser('alice', 'form-alice', PROGRAM))!.answers[0].value, answer.value);
  await assert.rejects(state.repository.saveFormAnswersIfCurrent({ userId: 'alice', caseId: 'form-alice', revision: 2,
    programId: PROGRAM, expectedAnswerRevision: 1, answers: { ...loaded, caseRevision: 4, answerRevision: 2 } }));
  assert.equal((await state.repository.loadForUser('alice', 'form-alice'))!.revision, 2);
  assert.equal((await state.repository.loadFormAnswersForUser('alice', 'form-alice', PROGRAM))!.answerRevision, 1);
});

async function start(t: TestContext, enabled = true) {
  const state = setup();
  const matchDeps = { authenticate: state.deps.authenticate, cases: state.repository,
    loadRegistry: async () => [structuredClone(demoProgram)], now: state.deps.now, allowDemoPrograms: true };
  const server = createMatchingServer(matchDeps, undefined, enabled ? state.deps : undefined);
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve()); server.closeAllConnections();
  }));
  return { ...state, base: `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1` };
}

const send = (url: string, body: unknown, token = 'alice-token') => fetch(url, {
  method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
});

test('HTTP read/save routes preserve no-store owner isolation and invalidate the old matching revision', async t => {
  const state = await start(t);
  const first = await send(`${state.base}/read-form-answers`, readRequest);
  assert.equal(first.status, 200); assert.equal(first.headers.get('cache-control'), 'no-store');
  assert.equal(first.headers.get('x-content-type-options'), 'nosniff');
  const saved = await send(`${state.base}/save-form-answers`, state.saveRequest());
  assert.equal(saved.status, 200); assert.equal((await saved.json()).caseRevision, 2);
  assert.equal((await send(`${state.base}/read-form-answers`, { ...readRequest, expectedCaseRevision: 2 }, 'bob-token')).status, 404);
  assert.equal((await send(`${state.base}/match-case`, { schemaVersion: '1', caseId: 'form-alice', expectedCaseRevision: 1 })).status, 409);
});

test('HTTP form routes reuse authentication, media, method and bounded body rules', async t => {
  const state = await start(t);
  for (const path of ['read-form-answers', 'save-form-answers']) {
    const url = `${state.base}/${path}`;
    assert.equal((await fetch(url, { method: 'POST' })).status, 401);
    const method = await fetch(url); assert.equal(method.status, 405); assert.equal(method.headers.get('allow'), 'POST');
    assert.equal((await fetch(url, { method: 'POST', headers: { Authorization: 'Bearer alice-token', 'Content-Type': 'text/plain' }, body: '{}' })).status, 415);
    assert.equal((await fetch(url, { method: 'POST', headers: { Authorization: 'Bearer alice-token', 'Content-Type': 'application/json' }, body: '{' })).status, 400);
    assert.equal((await fetch(url, { method: 'POST', headers: { Authorization: 'Bearer alice-token', 'Content-Type': 'application/json' }, body: 'x'.repeat(MAX_REQUEST_BYTES + 1) })).status, 413);
    assert.equal((await send(`${url}?owner=alice`, readRequest)).status, 404);
  }
});

test('form endpoints remain unavailable unless the third dependency argument is supplied', async t => {
  const state = await start(t, false);
  for (const path of ['read-form-answers', 'save-form-answers']) {
    assert.equal((await send(`${state.base}/${path}`, readRequest)).status, 404);
  }
});
