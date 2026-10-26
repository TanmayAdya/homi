import assert from 'node:assert/strict';
import test from 'node:test';
import { handleMatchCase } from '../src/api/match-case.ts';
import type { ApiErrorCode, ApiErrorResponse, MatchCaseDependencies, MatchCaseResult } from '../src/api/match-case.ts';
import type { CaseSnapshot, MatchResponse, ProgramDefinition } from '../src/types.ts';
import { demoProgram } from '../fixtures/demo-program.ts';

const makeCase = (caseId = 'case-a', revision = 3): CaseSnapshot => ({
  schemaVersion: '1', caseId, revision,
  profile: {
    city: 'Demo City', county: null, healthPlan: 'Example Plan', tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null,
  },
  unresolvedFields: [], findings: [],
});
const request = { body: { schemaVersion: '1', caseId: 'case-a', expectedCaseRevision: 3 }, bearerToken: 'token-a' };

function setup() {
  const cases = new Map<string, { owner: string; snapshot: CaseSnapshot }>([
    ['case-a', { owner: 'user-a', snapshot: makeCase() }],
    ['case-b', { owner: 'user-b', snapshot: makeCase('case-b', 8) }],
  ]);
  const calls: string[] = [];
  const saved: { userId: string; caseId: string; revision: number; response: MatchResponse }[] = [];
  const deps: MatchCaseDependencies = {
    async authenticate(token) {
      calls.push(`auth:${token}`);
      return token === 'token-a' ? { userId: 'user-a' } : token === 'token-b' ? { userId: 'user-b' } : null;
    },
    cases: {
      async loadForUser(userId, caseId) {
        calls.push(`load:${userId}:${caseId}`);
        const found = cases.get(caseId);
        return found?.owner === userId ? found.snapshot : null;
      },
      async saveMatchIfCurrent(userId, caseId, revision, response) {
        calls.push(`save:${userId}:${caseId}:${revision}`);
        const found = cases.get(caseId);
        if (!found || found.owner !== userId) return 'not_found';
        if (found.snapshot.revision !== revision) return 'conflict';
        saved.push({ userId, caseId, revision, response: structuredClone(response) });
        return 'saved';
      },
    },
    async loadRegistry() {
      calls.push('registry');
      return [structuredClone(demoProgram)];
    },
    now() { calls.push('now'); return new Date('2026-10-13T19:00:00Z'); },
    allowDemoPrograms: true,
  };
  return { deps, cases, calls, saved };
}

function expectError(result: MatchCaseResult, status: number, code: ApiErrorCode) {
  assert.equal(result.status, status);
  assert.equal((result.body as ApiErrorResponse).error.code, code);
  assert.deepEqual(Object.keys(result.body).sort(), ['error', 'schemaVersion']);
  assert.equal(result.headers?.['Cache-Control'], 'no-store');
}

test('API persists an authenticated saved-case result before returning success', async () => {
  const { deps, calls, saved } = setup();
  const result = await handleMatchCase(request, deps);
  assert.equal(result.status, 200);
  assert.equal(saved.length, 1);
  assert.equal(saved[0].userId, 'user-a');
  assert.equal(saved[0].revision, 3);
  assert.deepEqual(saved[0].response, result.body);
  assert.equal((result.body as MatchResponse).matches[0].status, 'meets_known_criteria');
  assert.deepEqual(calls, ['auth:token-a', 'load:user-a:case-a', 'now', 'registry', 'now', 'save:user-a:case-a:3']);
  assert.equal(result.headers?.['Cache-Control'], 'no-store');
});

test('missing and whitespace credentials never reach authentication or storage', async () => {
  for (const bearerToken of [null, '', ' ', ' token-a', 'token-a\n']) {
    const { deps, calls } = setup();
    const result = await handleMatchCase({ ...request, bearerToken }, deps);
    expectError(result, 401, 'UNAUTHENTICATED');
    assert.equal(result.headers?.['WWW-Authenticate'], 'Bearer');
    assert.deepEqual(calls, []);
  }
});

test('rejected token is unauthorized before body validation or case lookup', async () => {
  const { deps, calls } = setup();
  expectError(await handleMatchCase({ body: { owner: 'user-a' }, bearerToken: 'invalid' }, deps), 401, 'UNAUTHENTICATED');
  assert.deepEqual(calls, ['auth:invalid']);
});

test('strict request rejects missing, extra, mistyped, empty and out-of-range values', async () => {
  for (const body of [
    null, [], {}, { ...request.body, schemaVersion: '2' },
    { ...request.body, caseId: '' }, { ...request.body, caseId: '   ' }, { ...request.body, caseId: 'a'.repeat(201) },
    ...[0, -1, 1.5, '3', NaN, Infinity, Number.MAX_SAFE_INTEGER + 1].map(expectedCaseRevision => ({ ...request.body, expectedCaseRevision })),
    ...['owner', 'userId', 'profile', 'evaluatedAt', 'evaluationDate', 'registry', 'rules'].map(field => ({ ...request.body, [field]: 'client-controlled' })),
  ]) {
    const { deps, calls } = setup();
    expectError(await handleMatchCase({ ...request, body }, deps), 400, 'INVALID_REQUEST');
    assert.deepEqual(calls, ['auth:token-a']);
  }
});

test('case IDs at the 200-character boundary remain valid and are not normalized', async () => {
  const { deps, cases, saved } = setup();
  const caseId = 'a'.repeat(200);
  cases.set(caseId, { owner: 'user-a', snapshot: makeCase(caseId) });
  assert.equal((await handleMatchCase({ ...request, body: { ...request.body, caseId } }, deps)).status, 200);
  assert.equal(saved[0].caseId, caseId);
});

test('case ID length uses Unicode code points like the shared JSON schema', async () => {
  const { deps, cases, saved } = setup();
  const caseId = '🏠'.repeat(200);
  cases.set(caseId, { owner: 'user-a', snapshot: makeCase(caseId) });
  assert.equal((await handleMatchCase({ ...request, body: { ...request.body, caseId } }, deps)).status, 200);
  assert.equal(saved[0].caseId, caseId);
  expectError(await handleMatchCase({ ...request, body: { ...request.body, caseId: '🏠'.repeat(201) } }, deps), 400, 'INVALID_REQUEST');
  assert.equal(saved.length, 1);
});

test('two users cannot read each other’s cases; missing and inaccessible look identical', async () => {
  const { deps, calls, saved } = setup();
  const inaccessible = await handleMatchCase({ ...request, body: { ...request.body, caseId: 'case-b', expectedCaseRevision: 8 } }, deps);
  const missing = await handleMatchCase({ ...request, body: { ...request.body, caseId: 'missing' } }, deps);
  expectError(inaccessible, 404, 'CASE_NOT_FOUND');
  assert.deepEqual(inaccessible, missing);
  assert.ok(calls.includes('load:user-a:case-b'));
  assert.ok(!calls.includes('registry'));
  assert.equal(saved.length, 0);
  expectError(await handleMatchCase({ ...request, bearerToken: 'token-b' }, deps), 404, 'CASE_NOT_FOUND');
  assert.equal((await handleMatchCase({ bearerToken: 'token-b', body: { ...request.body, caseId: 'case-b', expectedCaseRevision: 8 } }, deps)).status, 200);
  assert.equal(saved[0].userId, 'user-b');
});

test('a stale requested revision stops before loading rules or saving', async () => {
  const { deps, calls, saved } = setup();
  expectError(await handleMatchCase({ ...request, body: { ...request.body, expectedCaseRevision: 2 } }, deps), 409, 'CASE_REVISION_MISMATCH');
  assert.ok(!calls.includes('registry'));
  assert.equal(saved.length, 0);
});

test('a reused authentication object cannot retarget the owner during registry loading', async () => {
  const { deps, saved } = setup(); const user = { userId: 'user-a' };
  deps.authenticate = async () => user;
  deps.loadRegistry = async () => {
    await Promise.resolve(); user.userId = 'user-b';
    return [structuredClone(demoProgram)];
  };
  const result = await handleMatchCase(structuredClone(request), deps);
  assert.equal(result.status, 200); assert.equal(saved.length, 1);
  assert.equal(saved[0].userId, 'user-a'); assert.equal(saved[0].caseId, 'case-a');
});

test('the parsed request is detached before an asynchronous case read', async () => {
  const { deps, saved } = setup(); const input = structuredClone(request);
  const load = deps.cases.loadForUser;
  deps.cases.loadForUser = async (userId, caseId) => {
    const loaded = await load(userId, caseId);
    input.body.caseId = 'case-b'; input.body.expectedCaseRevision = 8;
    return loaded;
  };
  const result = await handleMatchCase(input, deps);
  assert.equal(result.status, 200); assert.equal(saved.length, 1);
  assert.equal(saved[0].caseId, 'case-a'); assert.equal(saved[0].revision, 3);
});

test('a concurrent revision change during evaluation cannot save or return the old result', async () => {
  const { deps, cases, saved } = setup();
  deps.loadRegistry = async () => {
    cases.get('case-a')!.snapshot.revision = 4;
    cases.get('case-a')!.snapshot.profile.healthPlan = 'Changed plan';
    return [structuredClone(demoProgram)];
  };
  expectError(await handleMatchCase(request, deps), 409, 'CASE_REVISION_MISMATCH');
  assert.equal(saved.length, 0);
});

test('case deletion during evaluation returns the same unavailable response', async () => {
  const { deps, cases, saved } = setup();
  deps.loadRegistry = async () => { cases.delete('case-a'); return [structuredClone(demoProgram)]; };
  expectError(await handleMatchCase(request, deps), 404, 'CASE_NOT_FOUND');
  assert.equal(saved.length, 0);
});

test('access loss during evaluation is rechecked atomically before saving', async () => {
  const { deps, cases, saved } = setup();
  deps.loadRegistry = async () => { cases.get('case-a')!.owner = 'user-b'; return [structuredClone(demoProgram)]; };
  expectError(await handleMatchCase(request, deps), 404, 'CASE_NOT_FOUND');
  assert.equal(saved.length, 0);
});

test('server-selected clock and registry determine the persisted result', async () => {
  const { deps, saved } = setup();
  deps.now = () => new Date('2026-10-13T23:45:06.123Z');
  deps.loadRegistry = async () => {
    const program = structuredClone(demoProgram);
    program.ruleVersion = 'server-selected-v2';
    program.criteria[1].rule = { kind: 'eq', field: 'healthPlan', value: 'Server-selected Plan', sourceIds: [], resolvedBy: 'resident' };
    return [program];
  };
  const result = await handleMatchCase(request, deps);
  assert.equal(result.status, 200);
  const response = result.body as MatchResponse;
  assert.equal(response.evaluatedAt, '2026-10-13T23:45:06.123Z');
  assert.equal(response.evaluationDate, '2026-10-13');
  assert.equal(response.matches[0].ruleVersion, 'server-selected-v2');
  assert.equal(response.matches[0].status, 'does_not_meet_criterion');
  assert.deepEqual(saved[0].response, response);
});

test('demo programs require explicit opt-in and never save by default', async () => {
  for (const allowDemoPrograms of [undefined, false]) {
    const { deps, saved } = setup();
    deps.allowDemoPrograms = allowDemoPrograms;
    expectError(await handleMatchCase(request, deps), 500, 'INTERNAL_ERROR');
    assert.equal(saved.length, 0);
  }
});

test('dependency failures are sanitized temporary failures and never successful responses', async () => {
  for (const operation of ['authenticate', 'load', 'registry', 'save'] as const) {
    const { deps, saved } = setup();
    const fail = async () => { throw new Error('token-a: private case profile; service credential SECRET'); };
    if (operation === 'authenticate') deps.authenticate = fail;
    if (operation === 'load') deps.cases.loadForUser = fail;
    if (operation === 'registry') deps.loadRegistry = fail;
    if (operation === 'save') deps.cases.saveMatchIfCurrent = fail;
    const result = await handleMatchCase(request, deps);
    expectError(result, 503, 'SERVICE_UNAVAILABLE');
    assert.doesNotMatch(JSON.stringify(result), /token-a|SECRET|private case/);
    assert.equal(saved.length, 0);
  }
});

test('malformed stored cases and wrong identities fail closed without saving', async () => {
  for (const snapshot of [
    undefined, { ...makeCase(), caseId: 'case-b' }, { ...makeCase(), revision: '3' },
    { ...makeCase(), extra: true }, { ...makeCase(), profile: { ...makeCase().profile, ownerConsentReported: 'yes' } },
  ]) {
    const { deps, calls, saved } = setup();
    deps.cases.loadForUser = async () => snapshot as CaseSnapshot;
    expectError(await handleMatchCase(request, deps), 500, 'INTERNAL_ERROR');
    assert.ok(!calls.includes('registry'));
    assert.equal(saved.length, 0);
  }
});

test('malformed registry and clock values are internal failures without persisted results', async () => {
  for (const setupFailure of [
    (deps: MatchCaseDependencies) => { deps.loadRegistry = async () => [{ ...demoProgram, criteria: [] }]; },
    (deps: MatchCaseDependencies) => { deps.loadRegistry = async () => null as unknown as ProgramDefinition[]; },
    (deps: MatchCaseDependencies) => { deps.now = () => new Date('invalid'); },
    (deps: MatchCaseDependencies) => { deps.now = () => { throw new Error('private clock configuration'); }; },
  ]) {
    const { deps, saved } = setup();
    setupFailure(deps);
    const result = await handleMatchCase(request, deps);
    expectError(result, 500, 'INTERNAL_ERROR');
    assert.equal(saved.length, 0);
    assert.doesNotMatch(JSON.stringify(result), /private clock/);
  }
});

test('unexpected authentication/save adapter results fail closed', async () => {
  const invalidIdentity = setup();
  invalidIdentity.deps.authenticate = async () => ({ userId: '' });
  expectError(await handleMatchCase(request, invalidIdentity.deps), 500, 'INTERNAL_ERROR');
  assert.equal(invalidIdentity.saved.length, 0);
  const invalidSave = setup();
  invalidSave.deps.cases.saveMatchIfCurrent = async () => undefined as unknown as 'saved';
  expectError(await handleMatchCase(request, invalidSave.deps), 500, 'INTERNAL_ERROR');
});

test('source expiry and cache boundaries survive the API persistence boundary', async () => {
  const { deps, saved } = setup();
  const program = structuredClone(demoProgram);
  program.isDemo = false;
  program.rulesVerified = true;
  program.reviewedOn = '2026-10-12';
  program.recheckAfter = '2026-10-20T00:00:00Z';
  program.sources = [{ id: 'synthetic-source', title: 'Synthetic policy fixture', url: 'https://example.org/policy', reviewedOn: '2026-10-12', effectiveFrom: null, effectiveUntil: '2026-10-13' }];
  for (const criterion of program.criteria) {
    assert.ok('sourceIds' in criterion.rule);
    criterion.rule.sourceIds = ['synthetic-source'];
  }
  deps.allowDemoPrograms = false;
  deps.loadRegistry = async () => [program];
  const before = await handleMatchCase(request, deps);
  assert.equal(before.status, 200);
  assert.equal((before.body as MatchResponse).matches[0].recheckAfter, '2026-10-14T00:00:00.000Z');
  deps.now = () => new Date('2026-10-14T00:00:00Z');
  const after = await handleMatchCase(request, deps);
  assert.equal(after.status, 200);
  assert.equal((after.body as MatchResponse).matches[0].status, 'needs_confirmation');
  assert.equal((after.body as MatchResponse).matches[0].checks[0].reasonCode, 'source_not_current');
  assert.equal(saved[1].response.matches[0].recheckAfter, '2026-10-14T00:00:00.000Z');
});

test('registry loading across policy expiry uses the later authoritative evaluation clock', async () => {
  const { deps, saved } = setup();
  let currentTime = '2026-10-13T23:59:59.999Z';
  deps.now = () => new Date(currentTime);
  deps.loadRegistry = async () => {
    currentTime = '2026-10-14T00:00:00.000Z';
    return [{ ...structuredClone(demoProgram), effectiveUntil: '2026-10-13', recheckAfter: '2026-10-20T00:00:00Z' }];
  };
  const result = await handleMatchCase(request, deps);
  assert.equal(result.status, 200);
  const response = result.body as MatchResponse;
  assert.equal(response.evaluatedAt, currentTime);
  assert.equal(response.evaluationDate, '2026-10-14');
  assert.equal(response.matches[0].status, 'needs_confirmation');
  assert.equal(response.matches[0].checks[0].reasonCode, 'rules_expired');
  assert.deepEqual(saved[0].response, response);
});
