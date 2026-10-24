import assert from 'node:assert/strict';
import test from 'node:test';
import { handleListCases, type ListCasesDependencies, type ListCasesErrorCode,
  type ListCasesResult } from '../src/api/list-cases.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { compareCaseIds, parseCaseListPage, parseCaseListQuery, parseListCasesRequest,
  type CaseListPage, type CaseListQuery } from '../src/cases/discovery.ts';
import { AccountClosedError } from '../src/lifecycle/types.ts';
import type { CaseSnapshot } from '../src/types.ts';

function request(limit = 2, afterCaseId: string | null = null) {
  return { schemaVersion: '1', limit, afterCaseId };
}

function snapshot(caseId: string, revision = 1): CaseSnapshot {
  return { schemaVersion: '1', caseId, revision,
    profile: { city: 'PRIVATE Fictional City', county: null, healthPlan: null,
      tenure: null, ageYears: null, householdSize: null, annualIncomeUsd: 12345,
      ownerConsentReported: null },
    unresolvedFields: ['profile.healthPlan'],
    findings: [{ id: 'fictional-finding', room: 'entrance',
      observation: 'PRIVATE fictional observation', reviewState: 'needs_review',
      evidenceIds: [], measurements: [] }] };
}

function setup(repository = new MemoryCaseRepository([
  { userId: 'alice', snapshot: snapshot('alice-a', 3) },
  { userId: 'alice', snapshot: snapshot('alice-c', 7) },
  { userId: 'bob', snapshot: snapshot('bob-b', 4) },
])) {
  const calls: { userId: string; query: CaseListQuery }[] = [];
  const deps: ListCasesDependencies = {
    authenticate: async token => token === 'alice-token' ? { userId: 'alice' }
      : token === 'bob-token' ? { userId: 'bob' } : null,
    cases: { listForUser: async (userId, query) => {
      calls.push({ userId, query: { ...query } });
      return repository.listForUser(userId, query);
    } },
  };
  const send = (body: unknown = request(), bearerToken: string | null = 'alice-token') =>
    handleListCases({ body, bearerToken }, deps);
  return { repository, calls, deps, send };
}

function success(result: ListCasesResult): CaseListPage & { schemaVersion: '1' } {
  assert.equal(result.status, 200);
  assert.ok('cases' in result.body);
  assert.equal(result.headers['Cache-Control'], 'no-store');
  assert.equal(result.body.schemaVersion, '1');
  return result.body;
}

function failure(result: ListCasesResult, status: number, code: ListCasesErrorCode) {
  assert.equal(result.status, status);
  assert.ok('error' in result.body);
  assert.deepEqual(Object.keys(result.body).sort(), ['error', 'schemaVersion']);
  assert.deepEqual(Object.keys(result.body.error).sort(), ['code', 'message']);
  assert.equal(result.body.schemaVersion, '1');
  assert.equal(result.body.error.code, code);
  assert.equal(typeof result.body.error.message, 'string');
  assert.equal(result.headers['Cache-Control'], 'no-store');
  if (status === 401) assert.equal(result.headers['WWW-Authenticate'], 'Bearer');
  assert.ok(!JSON.stringify(result).includes('PRIVATE'));
}

test('query parsing accepts bounded limits and preserves Unicode without normalization', () => {
  for (const limit of [1, 20]) {
    for (const afterCaseId of [null, 'case-1', '🙂'.repeat(200), 'e\u0301']) {
      const query = { limit, afterCaseId };
      assert.deepEqual(parseCaseListQuery(query), query);
      assert.deepEqual(parseListCasesRequest({ schemaVersion: '1', ...query }), query);
    }
  }
});

test('query and request schemas reject extra, missing and caller-owned identity fields', () => {
  for (const value of [null, [], {}, { limit: 2 }, { afterCaseId: null },
    { limit: 2, afterCaseId: null, userId: 'bob' },
    { limit: 2, afterCaseId: null, offset: 2 }]) {
    assert.throws(() => parseCaseListQuery(value));
  }
  for (const value of [null, [], {}, { limit: 2, afterCaseId: null },
    { ...request(), schemaVersion: 1 }, { ...request(), schemaVersion: '2' },
    ...['owner', 'userId', 'caseId', 'profile', 'sort', 'offset'].map(key => ({ ...request(), [key]: 'PRIVATE' }))]) {
    assert.throws(() => parseListCasesRequest(value));
  }
});

test('query limit and identifier validation rejects coercion, malformed Unicode and control characters', () => {
  for (const limit of [0, -1, 21, 1.5, '2', true, null, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => parseCaseListQuery({ limit, afterCaseId: null }));
  }
  for (const afterCaseId of ['', ' ', ' leading', 'trailing ', 'a\nb', 'a\0b',
    'a\u007fb', 'a\u0085b', 'a\u2028b', 'a\u2029b', '\ud800', '\udfff', '🙂'.repeat(201), 1, {}, false]) {
    assert.throws(() => parseCaseListQuery({ limit: 2, afterCaseId }));
  }
});

test('case ordering uses UTF-8 byte order rather than JavaScript UTF-16 or locale order', () => {
  const ids = ['\u{10000}', '\ue000', 'é', 'e\u0301', 'a', 'A', 'aa'];
  assert.deepEqual([...ids].sort(compareCaseIds), ['A', 'a', 'aa', 'e\u0301', 'é', '\ue000', '\u{10000}']);
  assert.ok(compareCaseIds('\ue000', '\u{10000}') < 0);
  assert.ok('\ue000' > '\u{10000}');
  assert.equal(compareCaseIds('same', 'same'), 0);
});

test('page parsing accepts empty, full terminal and bounded continuation pages', () => {
  const query = { limit: 2, afterCaseId: null };
  for (const value of [
    { cases: [], nextAfterCaseId: null },
    { cases: [{ caseId: 'a', caseRevision: 1 }], nextAfterCaseId: null },
    { cases: [{ caseId: 'a', caseRevision: 1 }, { caseId: 'b', caseRevision: 2 }], nextAfterCaseId: null },
    { cases: [{ caseId: 'a', caseRevision: 1 }, { caseId: 'b', caseRevision: 2 }], nextAfterCaseId: 'b' },
  ]) assert.deepEqual(parseCaseListPage(value, query), value);
});

test('pages must be sorted, unique and strictly beyond the requested boundary', () => {
  const query = { limit: 2, afterCaseId: 'b' };
  for (const ids of [['b'], ['a'], ['d', 'c'], ['c', 'c'], ['c', 'd', 'e']]) {
    assert.throws(() => parseCaseListPage({
      cases: ids.map(caseId => ({ caseId, caseRevision: 1 })), nextAfterCaseId: null,
    }, query));
  }
  const ids = ['\ue000', '\u{10000}'];
  assert.deepEqual(parseCaseListPage({
    cases: ids.map(caseId => ({ caseId, caseRevision: 1 })), nextAfterCaseId: null,
  }, { limit: 2, afterCaseId: 'z' }).cases.map(item => item.caseId), ids);
});

test('continuation cursors require a full page and equal its final case ID', () => {
  for (const page of [
    { cases: [], nextAfterCaseId: 'a' },
    { cases: [{ caseId: 'a', caseRevision: 1 }], nextAfterCaseId: 'a' },
    { cases: [{ caseId: 'a', caseRevision: 1 }, { caseId: 'b', caseRevision: 1 }], nextAfterCaseId: 'a' },
    { cases: [{ caseId: 'a', caseRevision: 1 }, { caseId: 'b', caseRevision: 1 }], nextAfterCaseId: 'c' },
    { cases: [], nextAfterCaseId: false },
  ]) assert.throws(() => parseCaseListPage(page, { limit: 2, afterCaseId: null }));
});

test('page parsing rejects extra private fields and malformed summaries', () => {
  const query = { limit: 2, afterCaseId: null };
  for (const value of [null, [], {}, { cases: [] },
    { cases: [], nextAfterCaseId: null, ownerId: 'PRIVATE' },
    { cases: 'PRIVATE', nextAfterCaseId: null },
    ...[null, [], {}, { caseId: 'a' }, { caseId: 'a', caseRevision: 1, profile: 'PRIVATE' },
      ...[0, 1.5, '1', true, null, Infinity, Number.MAX_SAFE_INTEGER + 1].map(caseRevision => ({ caseId: 'a', caseRevision })),
      ...['', ' leading', '\ud800', '🙂'.repeat(201)].map(caseId => ({ caseId, caseRevision: 1 })),
    ].map(item => ({ cases: [item], nextAfterCaseId: null })),
  ]) assert.throws(() => parseCaseListPage(value, query));
});

test('adapter pages cannot contain sparse array holes', () => {
  assert.throws(() => parseCaseListPage({ cases: new Array(1), nextAfterCaseId: null },
    { limit: 2, afterCaseId: null }));
});

test('parsed queries and pages are detached from their caller-owned inputs', () => {
  const query = { limit: 2, afterCaseId: 'a' };
  const parsedQuery = parseCaseListQuery(query);
  const page = { cases: [{ caseId: 'b', caseRevision: 1 }], nextAfterCaseId: null };
  const parsedPage = parseCaseListPage(page, query);
  query.limit = 20; query.afterCaseId = 'z';
  page.cases[0]!.caseId = 'PRIVATE'; page.cases[0]!.caseRevision = 99;
  assert.deepEqual(parsedQuery, { limit: 2, afterCaseId: 'a' });
  assert.deepEqual(parsedPage, { cases: [{ caseId: 'b', caseRevision: 1 }], nextAfterCaseId: null });
});

test('authentication failure takes precedence over invalid requests and never reaches private storage', async () => {
  for (const token of [null, '', 'bad token', '\ttoken', 'unknown-token']) {
    const state = setup();
    failure(await state.send({ ownerId: 'PRIVATE' }, token), 401, 'UNAUTHENTICATED');
    assert.equal(state.calls.length, 0);
  }
});

test('authenticated malformed requests fail before repository access', async () => {
  const state = setup();
  for (const body of [null, {}, { ...request(), limit: 21 }, { ...request(), userId: 'bob' },
    { ...request(), afterCaseId: ' PRIVATE ' }, { ...request(), schemaVersion: '2' }]) {
    failure(await state.send(body), 400, 'INVALID_REQUEST');
  }
  assert.equal(state.calls.length, 0);
});

test('listing returns only the authenticated owner’s minimal case metadata', async () => {
  const state = setup();
  const alice = success(await state.send());
  assert.deepEqual(alice, { schemaVersion: '1', cases: [
    { caseId: 'alice-a', caseRevision: 3 }, { caseId: 'alice-c', caseRevision: 7 },
  ], nextAfterCaseId: null });
  const bob = success(await state.send(request(), 'bob-token'));
  assert.deepEqual(bob.cases, [{ caseId: 'bob-b', caseRevision: 4 }]);
  assert.deepEqual(state.calls.map(call => call.userId), ['alice', 'bob']);
  for (const result of [alice, bob]) {
    assert.ok(!JSON.stringify(result).includes('PRIVATE'));
    assert.deepEqual(Object.keys(result).sort(), ['cases', 'nextAfterCaseId', 'schemaVersion']);
    for (const item of result.cases) assert.deepEqual(Object.keys(item).sort(), ['caseId', 'caseRevision']);
  }
});

test('an authenticated owner with no cases receives an empty page without identity details', async () => {
  const state = setup(); state.deps.authenticate = async () => ({ userId: 'new-owner' });
  assert.deepEqual(success(await state.send()), { schemaVersion: '1', cases: [], nextAfterCaseId: null });
});

test('memory pagination traverses all owned cases in UTF-8 order with no duplicate final page', async () => {
  const ids = ['\u{10000}', 'c', '\ue000', 'a', 'b', 'é'];
  const repository = new MemoryCaseRepository([
    ...ids.map(caseId => ({ userId: 'alice', snapshot: snapshot(caseId) })),
    { userId: 'bob', snapshot: snapshot('aa') },
  ]);
  let afterCaseId: string | null = null;
  const seen: string[] = [];
  const cursors: (string | null)[] = [];
  do {
    const page = await repository.listForUser('alice', { limit: 2, afterCaseId });
    seen.push(...page.cases.map(item => item.caseId));
    afterCaseId = page.nextAfterCaseId; cursors.push(afterCaseId);
  } while (afterCaseId !== null);
  assert.deepEqual(seen, [...ids].sort(compareCaseIds));
  assert.equal(new Set(seen).size, ids.length);
  assert.deepEqual(cursors, ['b', 'é', null]);
});

test('a cursor is only a sort boundary and does not reveal whether another owner has that ID', async () => {
  const alice = [{ userId: 'alice', snapshot: snapshot('a') },
    { userId: 'alice', snapshot: snapshot('c') }];
  const absent = new MemoryCaseRepository(alice);
  const privateCase = new MemoryCaseRepository([...alice, { userId: 'bob', snapshot: snapshot('b') }]);
  const query = { limit: 2, afterCaseId: 'b' };
  assert.deepEqual(await privateCase.listForUser('alice', query), await absent.listForUser('alice', query));
  assert.deepEqual(await privateCase.listForUser('alice', query), {
    cases: [{ caseId: 'c', caseRevision: 1 }], nextAfterCaseId: null,
  });
});

test('memory summaries reflect current revisions and returned objects cannot alter stored cases', async () => {
  const state = setup();
  const first = success(await state.send()); first.cases[0]!.caseRevision = 999;
  const current = (await state.repository.loadForUser('alice', 'alice-a'))!;
  assert.equal(current.revision, 3);
  const { revision: _revision, ...draft } = current;
  draft.profile.city = 'A different fictional city';
  const saved = await state.repository.replaceIfCurrent('alice', current.caseId, current.revision, draft);
  assert.equal(saved.status, 'saved');
  assert.equal(success(await state.send()).cases[0]!.caseRevision, 4);
});

test('the request boundary is captured before authentication awaits', async () => {
  const state = setup(); const body = request(1, 'alice-a');
  state.deps.authenticate = async () => {
    await Promise.resolve(); body.limit = 20; body.afterCaseId = 'z';
    return { userId: 'alice' };
  };
  assert.deepEqual(success(await state.send(body)).cases, [{ caseId: 'alice-c', caseRevision: 7 }]);
  assert.deepEqual(state.calls, [{ userId: 'alice', query: { limit: 1, afterCaseId: 'alice-a' } }]);
});

test('an invalid request cannot become valid while authentication is pending', async () => {
  const state = setup(); const body = request(0);
  state.deps.authenticate = async () => { await Promise.resolve(); body.limit = 2; return { userId: 'alice' }; };
  failure(await state.send(body), 400, 'INVALID_REQUEST'); assert.equal(state.calls.length, 0);
});

test('caller body and provider identity mutations during repository awaits cannot retarget the response', async () => {
  const state = setup(); const body = request(1, 'alice-a'); const user = { userId: 'alice' };
  state.deps.authenticate = async () => user;
  state.deps.cases.listForUser = async (userId, query) => {
    await Promise.resolve(); body.limit = 20; body.afterCaseId = 'z'; user.userId = 'bob';
    assert.equal(userId, 'alice'); assert.deepEqual(query, { limit: 1, afterCaseId: 'alice-a' });
    return state.repository.listForUser(userId, query);
  };
  assert.deepEqual(success(await state.send(body)).cases, [{ caseId: 'alice-c', caseRevision: 7 }]);
});

test('an adapter cannot weaken the retained request limit or boundary by mutating its query', async () => {
  for (const returned of [
    { cases: [{ caseId: 'alice-a', caseRevision: 3 }], nextAfterCaseId: null },
    { cases: [{ caseId: 'alice-c', caseRevision: 7 }, { caseId: 'alice-d', caseRevision: 1 }], nextAfterCaseId: null },
  ]) {
    const state = setup();
    state.deps.cases.listForUser = async (_userId, query) => {
      query.limit = 20; query.afterCaseId = null; await Promise.resolve(); return returned;
    };
    failure(await state.send(request(1, 'alice-a')), 500, 'INTERNAL_ERROR');
  }
});

test('returned pages are detached from repository-owned summary objects', async () => {
  const state = setup(); const page = { cases: [{ caseId: 'alice-a', caseRevision: 3 }], nextAfterCaseId: null };
  state.deps.cases.listForUser = async () => page;
  const result = success(await state.send());
  page.cases[0]!.caseId = 'PRIVATE'; page.cases[0]!.caseRevision = 999; page.cases.push({ caseId: 'z', caseRevision: 1 });
  assert.deepEqual(result.cases, [{ caseId: 'alice-a', caseRevision: 3 }]);
});

test('malformed or overbroad repository output fails closed instead of leaking private fields', async () => {
  for (const page of [undefined, null, [],
    { cases: [], nextAfterCaseId: null, profile: 'PRIVATE' },
    { cases: [{ caseId: 'a', caseRevision: 1, ownerId: 'PRIVATE' }], nextAfterCaseId: null },
    { cases: [{ caseId: 'a', caseRevision: 0 }], nextAfterCaseId: null },
    { cases: [{ caseId: 'b', caseRevision: 1 }, { caseId: 'a', caseRevision: 1 }], nextAfterCaseId: null },
    { cases: [], nextAfterCaseId: 'PRIVATE' },
    { cases: new Array(1), nextAfterCaseId: null },
  ]) {
    const state = setup(); state.deps.cases.listForUser = async () => page as never;
    failure(await state.send(), 500, 'INTERNAL_ERROR');
  }
});

test('provider and repository failures are sanitized and are not automatically retried', async () => {
  for (const stage of ['authenticate', 'list'] as const) {
    const state = setup(); let attempts = 0;
    const broken = async () => { attempts += 1; throw new Error('PRIVATE token and database row'); };
    if (stage === 'authenticate') state.deps.authenticate = broken;
    else state.deps.cases.listForUser = broken;
    failure(await state.send(), 503, 'SERVICE_UNAVAILABLE'); assert.equal(attempts, 1);
    if (stage === 'authenticate') assert.equal(state.calls.length, 0);
  }
});

test('account closure during either authentication or storage access requires a fresh authenticated account', async () => {
  for (const stage of ['authenticate', 'list'] as const) {
    const state = setup(); const closed = async () => { throw new AccountClosedError(); };
    if (stage === 'authenticate') state.deps.authenticate = closed;
    else state.deps.cases.listForUser = closed;
    failure(await state.send(), 401, 'UNAUTHENTICATED');
  }
});

test('malformed authenticated identities never reach the repository', async () => {
  for (const identity of [undefined, {}, { userId: '' }, { userId: ' alice ' },
    { userId: 'a\0b' }, { userId: '\ud800' }, { userId: 1 }, { userId: '🙂'.repeat(201) }]) {
    const state = setup(); state.deps.authenticate = async () => identity as never;
    failure(await state.send(), 500, 'INTERNAL_ERROR'); assert.equal(state.calls.length, 0);
  }
});
