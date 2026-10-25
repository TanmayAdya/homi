import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import type { AddressInfo } from 'node:net';
import test, { type TestContext } from 'node:test';
import { ACCOUNT_HEAVY_BURST, ACCOUNT_MAX_ACTIVE_REQUESTS, ACCOUNT_REQUEST_BURST,
  RECEIPT_REQUEST_BURST } from '../src/api/account-admission.ts';
import { createMatchingServer, MAX_UPLOAD_REQUEST_BYTES, type HttpServerOptions } from '../src/api/http-server.ts';
import type { AuthenticatedUser } from '../src/api/match-case.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import type { LifecycleDependencies } from '../src/api/lifecycle.ts';
import { RecentAuthenticationRequiredError, type LifecycleRepository } from '../src/lifecycle/types.ts';
import type { CaseSnapshot } from '../src/types.ts';

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(yes => { resolve = yes; });
  return { promise, resolve };
}
const snapshot = (owner: string): CaseSnapshot => ({ schemaVersion: '1', caseId: `case-${owner}`, revision: 1,
  profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null,
    householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [],
  findings: [{ id: 'finding', room: 'entrance', observation: 'Fictional doorway', reviewState: 'confirmed',
    evidenceIds: ['photo'], measurements: [] }] });
const readBody = (owner = 'alice') => ({ schemaVersion: '1', caseId: `case-${owner}` });
const exportBody = (owner = 'alice') => ({ ...readBody(owner), expectedCaseRevision: 1, artifactId: 'missing-draft' });
const uploadBody = { ...readBody(), expectedCaseRevision: 1, expectedCatalogRevision: 0,
  evidenceId: 'photo', expectedEvidenceRevision: 0, findingId: 'finding', capturedAt: null,
  imageBase64: 'iVBORw0KGgo=' };

function state(authenticate?: (token: string) => Promise<AuthenticatedUser | null>) {
  const cases = new MemoryCaseRepository(['alice', 'bob'].map(userId => ({ userId, snapshot: snapshot(userId) })));
  const authCalls: string[] = [], reads: string[] = [];
  const load = cases.loadForUser.bind(cases);
  const hooks = { beforeRead: async (_owner: string) => {} };
  cases.loadForUser = async (owner, caseId) => {
    reads.push(owner);
    await hooks.beforeRead(owner);
    return load(owner, caseId);
  };
  const dependencies = { cases, now: () => new Date('2026-10-18T19:00:00Z'),
    loadRegistry: async () => [], loadFormTemplate: async () => null,
    authenticate: async (token: string) => {
      authCalls.push(token);
      return authenticate ? authenticate(token)
        : token.startsWith('alice') ? { userId: 'alice' } : token === 'bob' ? { userId: 'bob' } : null;
    } };
  return { dependencies, cases, authCalls, reads, hooks };
}
async function start(t: TestContext, fixture = state(), options: HttpServerOptions = {}) {
  const deps = fixture.dependencies;
  const server = createMatchingServer(deps, deps, deps, deps, deps, deps,
    { hosted: true, admissionNow: () => 0, caseListDependencies: deps, requestTrackingDependencies: deps, ...options });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const post = (route = 'read-case', body: unknown = readBody(), token = 'alice', headers: Record<string, string> = {}) => fetch(`${base}/v1/${route}`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body),
  });
  return { ...fixture, server, base, post };
}
async function error(response: Response, status: number, code: string, retry?: string) {
  assert.equal(response.status, status);
  const body = await response.json();
  assert.equal(body.error.code, code);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(JSON.stringify(body).includes('Private provider details'), false);
  if (retry) assert.equal(response.headers.get('retry-after'), retry);
}

test('verified owner shares rate budget across tokens and forged headers, with fresh authentication on every request', async t => {
  let clock = 0, revoked = false;
  const fixture = state(async token => token === 'bob' ? { userId: 'bob' }
    : token.startsWith('alice') && !revoked ? { userId: 'alice' } : null);
  const { post, authCalls, reads } = await start(t, fixture, { admissionNow: () => clock });
  for (let index = 0; index < ACCOUNT_REQUEST_BURST; index++) {
    assert.equal((await post('read-case', readBody(), `alice-${index}`)).status, 200);
  }
  await error(await post('read-case', readBody(), 'alice-new', {
    'X-Forwarded-For': '192.0.2.44', 'X-Real-IP': '198.51.100.12', 'X-User-Id': 'bob',
  }), 429, 'RATE_LIMITED', '1');
  assert.equal(reads.length, ACCOUNT_REQUEST_BURST);
  assert.equal(authCalls.length, ACCOUNT_REQUEST_BURST + 1);
  assert.equal((await post('read-case', readBody('bob'), 'bob')).status, 200);
  clock = 1000;
  assert.equal((await post('read-case', readBody(), 'alice-next')).status, 200);
  await error(await post(), 429, 'RATE_LIMITED', '1');
  revoked = true;
  await error(await post(), 401, 'UNAUTHENTICATED');
  assert.equal(authCalls.length, ACCOUNT_REQUEST_BURST + 5);
  assert.equal(reads.length, ACCOUNT_REQUEST_BURST + 2);
});

test('private binary work has its own budget while ordinary reads and deletions remain available', async t => {
  let clock = 0;
  const { post } = await start(t, state(), { admissionNow: () => clock });
  for (let index = 0; index < ACCOUNT_HEAVY_BURST; index++) {
    await error(await post('download-draft-export', exportBody()), 404, 'ARTIFACT_NOT_FOUND');
  }
  await error(await post('download-draft-export', exportBody()), 429, 'RATE_LIMITED', '5');
  assert.equal((await post()).status, 200);
  await error(await post('download-draft-export', exportBody('bob'), 'bob'), 404, 'ARTIFACT_NOT_FOUND');
  await error(await post('delete-evidence', { ...readBody(), expectedCaseRevision: 1,
    expectedCatalogRevision: 0, evidenceId: 'photo', expectedEvidenceRevision: 1 }), 409, 'EVIDENCE_CONFLICT');
  clock = 5000;
  await error(await post('download-draft-export', exportBody()), 404, 'ARTIFACT_NOT_FOUND');
});

test('rate-limited uploads reply before any large body or second authentication is received', async t => {
  const { post, base, authCalls, reads } = await start(t);
  for (let index = 0; index < ACCOUNT_REQUEST_BURST; index++) assert.equal((await post()).status, 200);
  const result = await new Promise<{ status: number; body: any; retry: string | undefined }>((resolve, reject) => {
    const request = httpRequest(`${base}/v1/upload-evidence`, { method: 'POST', headers: {
      Authorization: 'Bearer alice-new', 'Content-Type': 'application/json', 'Content-Length': MAX_UPLOAD_REQUEST_BYTES,
    } }, response => {
      const chunks: Buffer[] = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => { resolve({ status: response.statusCode!, body: JSON.parse(Buffer.concat(chunks).toString()),
        retry: response.headers['retry-after'] }); request.destroy(); });
      response.on('error', reject);
    });
    request.on('error', reject);
    request.setTimeout(2000, () => { request.destroy(); reject(new Error('Admission waited for upload body.')); });
    request.flushHeaders();
  });
  assert.equal(result.status, 429); assert.equal(result.body.error.code, 'RATE_LIMITED'); assert.equal(result.retry, '1');
  assert.equal(authCalls.length, ACCOUNT_REQUEST_BURST + 1);
  assert.equal(reads.length, ACCOUNT_REQUEST_BURST);
  assert.equal((await post('read-case', readBody('bob'), 'bob')).status, 200);
});

test('uploads reauthenticate after body receipt and reject revoked or changed owners before storage', async t => {
  for (const changed of [null, { userId: 'bob' }]) {
    let calls = 0;
    const fixture = state(async () => ++calls === 1 ? { userId: 'alice' } : changed);
    const { post, reads } = await start(t, fixture);
    await error(await post('upload-evidence', uploadBody), changed === null ? 401 : 503,
      changed === null ? 'UNAUTHENTICATED' : 'SERVICE_UNAVAILABLE');
    assert.equal(calls, 2); assert.equal(reads.length, 0);
  }
});

test('failed or malformed authentication is never admitted or hidden by cached cross-request success', async t => {
  const fixture = state(async token => {
    if (token === 'unavailable') throw new Error('Private provider details');
    if (token === 'malformed') return { userId: 'alice', extra: true } as AuthenticatedUser;
    if (token === 'undefined') return undefined as unknown as AuthenticatedUser;
    return token === 'alice' ? { userId: 'alice' } : null;
  });
  const { post, authCalls, reads } = await start(t, fixture);
  for (const [token, status, code] of [['bad', 401, 'UNAUTHENTICATED'], ['unavailable', 503, 'SERVICE_UNAVAILABLE'],
    ['malformed', 500, 'INTERNAL_ERROR'], ['undefined', 500, 'INTERNAL_ERROR']] as const) {
    await error(await post('read-case', readBody(), token), status, code);
  }
  assert.equal(reads.length, 0); assert.equal(authCalls.length, 4);
  for (let index = 0; index < ACCOUNT_REQUEST_BURST; index++) assert.equal((await post()).status, 200);
  await error(await post(), 429, 'RATE_LIMITED');
  assert.equal(reads.length, ACCOUNT_REQUEST_BURST);
  assert.equal(authCalls.length, ACCOUNT_REQUEST_BURST + 5);
});

function lifecycleFixture() {
  let closed = false, stale = false, normalCalls = 0, recentCalls = 0, receiptReads = 0;
  const lifecycle: LifecycleRepository = {
    isAccountClosed: async () => closed,
    deleteCaseIfCurrent: async () => ({ status: 'deleted' }),
    prepareAccountDeletion: async () => ({ status: 'ready', counts: { cases: 0, evidence: 0, exports: 0, storedBytes: 0 },
      expiresAt: '2026-10-18T19:05:00Z' }),
    confirmAccountDeletion: async () => { closed = true; return { status: 'confirmed', deletion: {
      status: 'auth_pending', applicationDataDeleted: true, providerIdentityDeleted: false } }; },
    readAccountDeletionReceipt: async () => { receiptReads++; return null; },
  };
  const dependencies: LifecycleDependencies = { lifecycle,
    authenticate: async () => { normalCalls++; return closed ? null : { userId: 'alice' }; },
    authenticateForDeletion: async () => { recentCalls++;
      if (stale) throw new RecentAuthenticationRequiredError();
      return { userId: 'alice' };
    } };
  return { dependencies, stale: (value: boolean) => { stale = value; },
    counts: () => ({ normalCalls, recentCalls, receiptReads }) };
}

test('recent-auth errors retain 403 and confirmed account deletion remains retryable after ordinary access closes', async t => {
  const lifecycle = lifecycleFixture();
  const { post } = await start(t, state(), { lifecycleDependencies: lifecycle.dependencies });
  lifecycle.stale(true);
  await error(await post('prepare-account-deletion', { schemaVersion: '1' }), 403, 'RECENT_AUTHENTICATION_REQUIRED');
  assert.deepEqual(lifecycle.counts(), { normalCalls: 0, recentCalls: 1, receiptReads: 0 });
  lifecycle.stale(false);
  const prepared = await post('prepare-account-deletion', { schemaVersion: '1' });
  assert.equal(prepared.status, 200);
  const token = (await prepared.json()).deletionToken;
  const body = { schemaVersion: '1', deletionToken: token, confirmation: 'DELETE_ACCOUNT' };
  assert.equal((await post('confirm-account-deletion', body)).status, 202);
  assert.equal((await post('confirm-account-deletion', body, 'alice-rotated')).status, 202);
  await error(await post('delete-case', { ...readBody(), expectedCaseRevision: 1,
    expectedCatalogRevision: 0, confirmation: 'DELETE_CASE' }), 401, 'UNAUTHENTICATED');
  assert.deepEqual(lifecycle.counts(), { normalCalls: 1, recentCalls: 4, receiptReads: 0 });
});

test('receipt polling uses bounded shared admission without Auth or raw-receipt identities', async t => {
  let clock = 0;
  const lifecycle = lifecycleFixture();
  const { post, base } = await start(t, state(), { lifecycleDependencies: lifecycle.dependencies, admissionNow: () => clock });
  for (let index = 0; index < RECEIPT_REQUEST_BURST; index++) {
    await error(await post('account-deletion-status', { schemaVersion: '1' }, index.toString(16).padStart(64, 'a')),
      404, 'DELETION_NOT_FOUND');
  }
  await error(await post('account-deletion-status', { schemaVersion: '1' }, 'b'.repeat(64)), 503, 'SERVICE_UNAVAILABLE', '3');
  assert.deepEqual(lifecycle.counts(), { normalCalls: 0, recentCalls: 0, receiptReads: RECEIPT_REQUEST_BURST });
  assert.equal((await post()).status, 200);
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  clock = 3000;
  await error(await post('account-deletion-status', { schemaVersion: '1' }, 'c'.repeat(64)), 404, 'DELETION_NOT_FOUND');
  assert.equal(lifecycle.counts().receiptReads, RECEIPT_REQUEST_BURST + 1);
});

test('per-owner active requests hold through repository work; denied requests do not leak slots', async t => {
  const fixture = state(), started = deferred<void>(), finish = deferred<void>();
  let entered = 0;
  fixture.hooks.beforeRead = async owner => {
    if (owner !== 'alice') return;
    if (++entered <= ACCOUNT_MAX_ACTIVE_REQUESTS) {
      if (entered === ACCOUNT_MAX_ACTIVE_REQUESTS) started.resolve();
      await finish.promise;
    }
  };
  const { post, reads } = await start(t, fixture);
  const running = Array.from({ length: ACCOUNT_MAX_ACTIVE_REQUESTS }, () => post());
  try {
    await started.promise;
    for (let index = 0; index < 4; index++) await error(await post(), 429, 'RATE_LIMITED', '1');
    assert.equal(reads.length, ACCOUNT_MAX_ACTIVE_REQUESTS);
    assert.equal((await post('read-case', readBody('bob'), 'bob')).status, 200);
  } finally { finish.resolve(); }
  assert.equal((await Promise.all(running)).every(response => response.status === 200), true);
  assert.equal((await post()).status, 200);
});

test('per-owner active admission remains held until completed responses flush', async t => {
  const { post, server } = await start(t);
  const held = deferred<void>(), flushes: Array<() => void> = [];
  server.prependListener('request', (_request, response) => {
    if (flushes.length >= ACCOUNT_MAX_ACTIVE_REQUESTS) return;
    const end = response.end.bind(response);
    response.end = function(chunk?: any, encoding?: any, callback?: any) {
      flushes.push(() => { end(chunk, encoding, callback); });
      if (flushes.length === ACCOUNT_MAX_ACTIVE_REQUESTS) held.resolve();
      return response;
    };
  });
  const running = Array.from({ length: ACCOUNT_MAX_ACTIVE_REQUESTS }, () => post());
  try {
    await held.promise;
    await error(await post(), 429, 'RATE_LIMITED', '1');
  } finally { flushes.forEach(flush => flush()); }
  assert.equal((await Promise.all(running)).every(response => response.status === 200), true);
  assert.equal((await post()).status, 200);
});

test('disconnecting admitted requests cannot release an owner slot while repository work is running', async t => {
  const fixture = state(), started = deferred<void>(), finish = deferred<void>(), closed = deferred<void>();
  let entered = 0, disconnected = 0;
  fixture.hooks.beforeRead = async () => {
    if (++entered <= ACCOUNT_MAX_ACTIVE_REQUESTS) {
      if (entered === ACCOUNT_MAX_ACTIVE_REQUESTS) started.resolve();
      await finish.promise;
    }
  };
  const { post, server, base, reads } = await start(t, fixture);
  server.on('request', (_request, response) => {
    response.once('close', () => { if (++disconnected === ACCOUNT_MAX_ACTIVE_REQUESTS) closed.resolve(); });
  });
  const running = Array.from({ length: ACCOUNT_MAX_ACTIVE_REQUESTS }, () => {
    const request = httpRequest(`${base}/v1/read-case`, { method: 'POST', headers: {
      Authorization: 'Bearer alice', 'Content-Type': 'application/json' } });
    request.on('error', () => {}); request.end(JSON.stringify(readBody())); return request;
  });
  try {
    await started.promise;
    running.forEach(request => request.destroy());
    await closed.promise;
    await error(await post(), 429, 'RATE_LIMITED', '1');
    assert.equal(reads.length, ACCOUNT_MAX_ACTIVE_REQUESTS);
  } finally { finish.resolve(); running.forEach(request => request.destroy()); }
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal((await post()).status, 200);
});
