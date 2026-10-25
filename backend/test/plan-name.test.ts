import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { handlePlanName, type PlanNameDependencies, type PlanNameRoute } from '../src/api/plan-name.ts';
import { AccountClosedError } from '../src/lifecycle/types.ts';
import { changePlanName, emptyPlanName, parsePlanNameState, parseStoredPlanName, parseSavePlanNameRequest,
  parseNamedCaseListRequest, parseNamedCaseListPage, validPlanName, type SavePlanNameRequest } from '../src/cases/plan-name.ts';
import type { CaseSnapshot } from '../src/types.ts';

const snapshot = (caseId = 'fictional-a'): CaseSnapshot => ({ schemaVersion: '1', caseId, revision: 1,
  profile: { city: 'Fictional City', county: null, healthPlan: null, tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] });
const save = (overrides: Partial<SavePlanNameRequest> = {}): SavePlanNameRequest => ({ schemaVersion: '2',
  caseId: 'fictional-a', expectedNameRevision: 0, mutationId: 'fictional-mutation-1', name: 'Fictional home', ...overrides });
function setup() {
  const cases = new MemoryCaseRepository([{ userId: 'alice', snapshot: snapshot() },
    { userId: 'alice', snapshot: snapshot('fictional-c') }, { userId: 'bob', snapshot: snapshot('fictional-b') }]);
  const deps: PlanNameDependencies = { cases, authenticate: async token => ['alice', 'bob'].includes(token) ? { userId: token } : null };
  const send = (route: PlanNameRoute, body: unknown, bearerToken: string | null = 'alice') => handlePlanName({ body, bearerToken }, deps, route);
  return { cases, deps, send };
}
test('canonical Unicode names are bounded by scalars and reject controls, bidi and malformed UTF16', () => {
  for (const name of [null, 'Fictional home', '🙂'.repeat(80), 'e\u0301', '家の計画', '👩‍👩‍👧']) assert.equal(validPlanName(name), true);
  for (const name of ['', ' ', ' padded', 'padded ', 'a\nb', 'a\tb', 'a\u0085b', '\u202aName', '\u2066Name',
    'a\u2028b', '\ud800', '\udfff', '🙂'.repeat(81), 7, false, undefined]) assert.equal(validPlanName(name), false);
});
test('strict states distinguish never named from a revisioned reset and reject extra private fields', () => {
  const initial = emptyPlanName('fictional-a'); assert.deepEqual(parsePlanNameState(initial), initial);
  assert.throws(() => parseStoredPlanName(initial));
  const reset = { ...initial, nameRevision: 1, lastMutationId: 'reset' };
  assert.deepEqual(parseStoredPlanName(reset), reset);
  for (const state of [null, {}, { ...initial, name: 'unexpected' }, { ...initial, lastMutationId: 'unexpected' },
    { ...reset, lastMutationId: null }, { ...reset, extra: true }, { ...reset, nameRevision: 1.5 },
    { ...reset, nameRevision: Number.MAX_SAFE_INTEGER + 1 }, { ...reset, caseId: '\ud800' }]) assert.throws(() => parsePlanNameState(state));
});
test('save requests reject caller-owned identities, coercion and exhausted revisions', () => {
  assert.deepEqual(parseSavePlanNameRequest(save()), save());
  for (const value of [null, {}, { ...save(), userId: 'bob' }, { ...save(), schemaVersion: '1' }, { ...save(), name: '' },
    { ...save(), mutationId: '' }, { ...save(), mutationId: 'x'.repeat(201) }, { ...save(), expectedNameRevision: '0' },
    { ...save(), expectedNameRevision: -1 }, { ...save(), expectedNameRevision: Number.MAX_SAFE_INTEGER }]) {
    assert.throws(() => parseSavePlanNameRequest(value));
  }
});
test('only the latest exact mutation can retry; reset and stale imports never revert a newer choice', () => {
  const first = changePlanName(emptyPlanName('fictional-a'), save())!;
  assert.deepEqual(changePlanName(first, save()), first);
  assert.equal(changePlanName(first, save({ name: 'Different' })), null);
  assert.equal(changePlanName(first, save({ expectedNameRevision: 1 })), null);
  assert.equal(changePlanName(first, save({ mutationId: 'other' })), null);
  const resetRequest = save({ name: null, expectedNameRevision: 1, mutationId: 'reset' });
  const reset = changePlanName(first, resetRequest)!;
  assert.equal(reset.name, null); assert.equal(reset.nameRevision, 2);
  assert.deepEqual(changePlanName(reset, resetRequest), reset);
  assert.equal(changePlanName(reset, save()), null);
});
test('list contracts reject duplicate/unordered/before-cursor rows and sparse or oversized pages', () => {
  const row = { caseId: 'a', caseRevision: 1, name: null, nameRevision: 0, lastMutationId: null };
  const query = { limit: 2, afterCaseId: null };
  assert.deepEqual(parseNamedCaseListRequest({ schemaVersion: '2', ...query }), query);
  for (const body of [{ schemaVersion: '1', ...query }, { schemaVersion: '2', ...query, ownerId: 'alice' }]) assert.throws(() => parseNamedCaseListRequest(body));
  for (const cases of [[row, row], [{ ...row, caseId: 'b' }, row], new Array(1), [row, { ...row, caseId: 'b' }, { ...row, caseId: 'c' }],
    [{ ...row, name: 'impossible' }], [{ ...row, nameRevision: 1, lastMutationId: null }], [{ ...row, profile: {} }]]) {
    assert.throws(() => parseNamedCaseListPage({ cases, nextAfterCaseId: null }, query));
  }
  assert.throws(() => parseNamedCaseListPage({ cases: [row], nextAfterCaseId: null }, { ...query, afterCaseId: 'a' }));
  assert.throws(() => parseNamedCaseListPage({ cases: [row], nextAfterCaseId: 'a' }, query));
});
test('memory owner checks, detached names and independent revisions preserve unchanged v1 snapshots', async () => {
  const { cases } = setup();
  assert.equal(await cases.readPlanNameForUser('bob', 'fictional-a'), null);
  assert.equal((await cases.savePlanNameForUser('bob', save())).status, 'not_found');
  const result = await cases.savePlanNameForUser('alice', save()); assert.equal(result.status, 'saved');
  if (result.status !== 'saved') throw Error('Unexpected test result.');
  result.state.name = 'Caller modified';
  assert.equal((await cases.readPlanNameForUser('alice', 'fictional-a'))!.name, save().name);
  assert.deepEqual(await cases.loadForUser('alice', 'fictional-a'), snapshot());
  assert.deepEqual(await cases.listForUser('alice', { limit: 1, afterCaseId: null }),
    { cases: [{ caseId: 'fictional-a', caseRevision: 1 }], nextAfterCaseId: 'fictional-a' });
  const { revision: _, ...draft } = snapshot();
  assert.equal((await cases.replaceIfCurrent('alice', 'fictional-a', 1, draft)).status, 'saved');
  assert.equal((await cases.readPlanNameForUser('alice', 'fictional-a'))!.nameRevision, 1);
});
test('simultaneous memory edits accept one winner and latest exact retry', async () => {
  const { cases } = setup();
  const requests = [save(), save({ mutationId: 'other', name: 'Other home' })];
  const outcomes = await Promise.all(requests.map(request => cases.savePlanNameForUser('alice', request)));
  assert.deepEqual(outcomes.map(result => result.status).sort(), ['conflict', 'saved']);
  const winner = outcomes.findIndex(result => result.status === 'saved');
  assert.deepEqual(await cases.savePlanNameForUser('alice', requests[winner]), outcomes[winner]);
});
test('handlers authenticate before malformed-request disclosure and prevent foreign reads/writes', async () => {
  const { send } = setup();
  for (const route of ['read-plan-name', 'save-plan-name', 'list-cases'] as const) {
    assert.equal((await send(route, { userId: 'bob' }, 'invalid')).status, 401);
    assert.equal((await send(route, { userId: 'bob' })).status, 400);
  }
  assert.equal((await send('read-plan-name', { schemaVersion: '2', caseId: 'fictional-a' }, 'bob')).status, 404);
  assert.equal((await send('save-plan-name', save(), 'bob')).status, 404);
  const first = await send('save-plan-name', save()); assert.equal(first.status, 200);
  assert.equal(first.headers['Cache-Control'], 'no-store');
  assert.deepEqual(first, await send('save-plan-name', save()));
  const conflict = await send('save-plan-name', save({ name: 'Different' }));
  assert.equal(conflict.status, 409); assert.ok('error' in conflict.body); assert.equal(conflict.body.error.code, 'PLAN_NAME_CONFLICT');
});
test('handler captures inputs before authentication yields and rejects misbound adapter responses', async () => {
  const { deps } = setup(); const body = save();
  deps.authenticate = async () => { body.caseId = 'fictional-b'; body.name = 'Changed'; return { userId: 'alice' }; };
  const result = await handlePlanName({ body, bearerToken: 'alice' }, deps, 'save-plan-name');
  assert.equal(result.status, 200); assert.ok('caseId' in result.body); assert.equal(result.body.caseId, 'fictional-a');
  deps.cases.readPlanNameForUser = async () => emptyPlanName('fictional-b');
  assert.equal((await handlePlanName({ body: { schemaVersion: '2', caseId: 'fictional-a' }, bearerToken: 'alice' }, deps, 'read-plan-name')).status, 500);
});
test('handler rejects malformed adapter metadata and maps closed-account/storage errors without payloads', async () => {
  const { deps, send } = setup();
  deps.cases.listNamedForUser = async () => ({ cases: new Array(1), nextAfterCaseId: null });
  assert.equal((await send('list-cases', { schemaVersion: '2', limit: 2, afterCaseId: null })).status, 500);
  deps.cases.readPlanNameForUser = async () => { throw new AccountClosedError(); };
  assert.equal((await send('read-plan-name', { schemaVersion: '2', caseId: 'fictional-a' })).status, 409);
  deps.cases.readPlanNameForUser = async () => { throw new Error('PRIVATE NAME'); };
  const result = await send('read-plan-name', { schemaVersion: '2', caseId: 'fictional-a' });
  assert.equal(result.status, 503); assert.equal(JSON.stringify(result).includes('PRIVATE'), false);
});
test('shared fictional plan-name fixtures parse and prove the exact retry/reset sequence', async () => {
  const fixture = JSON.parse(await readFile(new URL('../../contracts/v2/fixtures/plan-names.json', import.meta.url), 'utf8'));
  let state = parsePlanNameState(fixture.initial);
  for (const item of fixture.mutations) {
    const request = parseSavePlanNameRequest(item.request);
    state = changePlanName(state, request)!;
    assert.deepEqual(state, parsePlanNameState(item.result));
    assert.deepEqual(changePlanName(state, request), state);
  }
});
