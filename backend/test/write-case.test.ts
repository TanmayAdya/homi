import assert from 'node:assert/strict';
import test from 'node:test';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { handleCreateCase, handleSaveCase, type CaseWriteDependencies, type CaseWriteResponse } from '../src/api/write-case.ts';
import type { CaseDraft } from '../src/cases/types.ts';

const ID = '01000000-0000-4000-8000-000000000001';
function draft(caseId = ID): CaseDraft {
  return { schemaVersion: '1', caseId, profile: { city: null, county: null, healthPlan: null, tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
}
function setup() {
  const repository = new MemoryCaseRepository([]);
  const deps: CaseWriteDependencies = { authenticate: async token => token === 'alice-token' ? { userId: 'alice' }
    : token === 'bob-token' ? { userId: 'bob' } : null, cases: repository };
  const create = (body: unknown = draft(), bearerToken: string | null = 'alice-token') => handleCreateCase({ body, bearerToken }, deps);
  const save = (body: unknown = { ...draft(), expectedCaseRevision: 1 }, bearerToken: string | null = 'alice-token') => handleSaveCase({ body, bearerToken }, deps);
  return { repository, deps, create, save };
}
function error(response: CaseWriteResponse, status: number, code: string) {
  assert.equal(response.status, status); assert.ok('error' in response.body); assert.equal(response.body.error.code, code);
  assert.equal(response.headers['Cache-Control'], 'no-store');
}

test('create and save return exact detached case snapshots with server revisions', async () => {
  const state = setup(); const first = await state.create(); assert.equal(first.status, 200);
  assert.deepEqual(first.body, { ...draft(), revision: 1 }); assert.equal(first.headers['Cache-Control'], 'no-store');
  const changed = draft(); changed.profile.city = 'Fictional City';
  const second = await state.save({ ...changed, expectedCaseRevision: 1 }); assert.equal(second.status, 200);
  assert.deepEqual(second.body, { ...changed, revision: 2 });
  if ('revision' in second.body) second.body.profile.city = 'Caller mutation';
  assert.equal((await state.repository.loadForUser('alice', ID))!.profile.city, 'Fictional City');
});

test('authentication controls every write even when the supplied request is malformed', async () => {
  const state = setup(); let written = false;
  state.deps.cases = { createForUser: async () => { written = true; throw new Error(); }, replaceIfCurrent: async () => { written = true; throw new Error(); } };
  for (const token of [null, '', 'bad token', 'invalid-token', 'x'.repeat(4097)]) {
    error(await state.create({ malformed: true }, token), 401, 'UNAUTHENTICATED');
    error(await state.save({ malformed: true }, token), 401, 'UNAUTHENTICATED');
  }
  assert.equal(written, false);
});

test('case collision is generic for either owner and save does not reveal another owner', async () => {
  const state = setup(); await state.create();
  error(await state.create(), 409, 'CASE_ID_UNAVAILABLE');
  error(await state.create(draft(), 'bob-token'), 409, 'CASE_ID_UNAVAILABLE');
  error(await state.save(undefined, 'bob-token'), 404, 'CASE_NOT_FOUND');
  error(await state.save({ ...draft('missing-case'), expectedCaseRevision: 1 }), 404, 'CASE_NOT_FOUND');
});

test('strict requests reject owners, assigned revisions, extra values, unsupported UUIDs and oversize cases', async () => {
  const state = setup();
  for (const body of [null, [], {}, { ...draft(), userId: 'alice' }, { ...draft(), revision: 1 },
    { ...draft(), expectedCaseRevision: 1 }, draft('not-a-uuid'), { ...draft(), profile: { ...draft().profile, city: 'x'.repeat(13000) } }]) {
    error(await state.create(body), 400, 'INVALID_REQUEST');
  }
  await state.create();
  for (const body of [draft(), { ...draft(), expectedCaseRevision: 0 }, { ...draft(), expectedCaseRevision: 1.5 },
    { ...draft(), expectedCaseRevision: 9007199254740992 }, { ...draft(), expectedCaseRevision: 1, revision: 2 }]) {
    error(await state.save(body), 400, 'INVALID_REQUEST');
  }
  assert.equal((await state.repository.loadForUser('alice', ID))!.revision, 1);
});

test('simultaneous saves cannot overwrite each other and stale replays are rejected', async () => {
  const state = setup(); await state.create();
  const results = await Promise.all([state.save(), state.save()]);
  assert.deepEqual(results.map(result => result.status).sort(), [200, 409]);
  error(results.find(result => result.status === 409)!, 409, 'CASE_REVISION_MISMATCH');
  error(await state.save(), 409, 'CASE_REVISION_MISMATCH');
});

test('request values cannot change while authentication yields', async () => {
  const state = setup(), body = draft();
  state.deps.authenticate = async () => { body.caseId = 'changed'; body.profile.city = 'changed'; return { userId: 'alice' }; };
  const response = await state.create(body);
  assert.equal(response.status, 200); assert.deepEqual(response.body, { ...draft(), revision: 1 });
});

test('authentication identity cannot change while the repository yields', async () => {
  const state = setup(), user = { userId: 'alice' }; state.deps.authenticate = async () => user;
  state.deps.cases = { ...state.deps.cases,
    createForUser: async (userId, value) => { user.userId = 'bob'; await Promise.resolve(); return state.repository.createForUser(userId, value); },
    replaceIfCurrent: (...args) => state.repository.replaceIfCurrent(...args) };
  assert.equal((await state.create()).status, 200);
  assert.notEqual(await state.repository.loadForUser('alice', ID), null);
  assert.equal(await state.repository.loadForUser('bob', ID), null);
});

test('mutable adapter input or substituted output cannot change expected response identity or content', async () => {
  const state = setup();
  for (const mutate of [(value: CaseDraft) => { value.caseId = 'another-case'; },
    (value: CaseDraft) => { value.profile.city = 'Adapter substitution'; }]) {
    state.deps.cases = { createForUser: async (_user, value) => {
      mutate(value); await Promise.resolve(); return { status: 'saved', snapshot: { ...value, revision: 1 } };
    }, replaceIfCurrent: (...args) => state.repository.replaceIfCurrent(...args) };
    error(await state.create(), 500, 'INTERNAL_ERROR');
  }
  state.deps.cases = { createForUser: async (_user, value) => ({ status: 'saved', snapshot: { ...value, revision: 99 } }),
    replaceIfCurrent: (...args) => state.repository.replaceIfCurrent(...args) };
  error(await state.create(), 500, 'INTERNAL_ERROR');
});

test('lost create or save responses can be recovered with read-case and the known case ID', async () => {
  const state = setup();
  state.deps.cases = { createForUser: async (...args) => { await state.repository.createForUser(...args); throw new Error('response lost'); },
    replaceIfCurrent: async (...args) => { await state.repository.replaceIfCurrent(...args); throw new Error('response lost'); } };
  error(await state.create(), 503, 'SERVICE_UNAVAILABLE');
  assert.equal((await state.repository.loadForUser('alice', ID))!.revision, 1);
  error(await state.save(), 503, 'SERVICE_UNAVAILABLE');
  assert.equal((await state.repository.loadForUser('alice', ID))!.revision, 2);
  error(await handleSaveCase({ body: { ...draft(), expectedCaseRevision: 1 }, bearerToken: 'alice-token' },
    { ...state.deps, cases: state.repository }), 409, 'CASE_REVISION_MISMATCH');
});

test('repository failures have exact safe statuses and never expose internal errors', async () => {
  const state = setup();
  for (const [status, code, http] of [
    ['not_found', 'CASE_NOT_FOUND', 404], ['conflict', 'CASE_REVISION_MISMATCH', 409],
    ['id_unavailable', 'CASE_ID_UNAVAILABLE', 409], ['evidence_conflict', 'EVIDENCE_CONFLICT', 409],
    ['quota_exceeded', 'STORAGE_LIMIT_REACHED', 507], ['invalid_input', 'INVALID_REQUEST', 400],
  ] as const) {
    state.deps.cases = { createForUser: async () => ({ status }), replaceIfCurrent: async () => ({ status }) };
    error(await state.create(), http, code);
  }
  state.deps.authenticate = async () => { throw new Error('secret/token/path'); };
  const response = await state.create(); error(response, 503, 'SERVICE_UNAVAILABLE');
  assert.equal(JSON.stringify(response).includes('secret'), false);
});
