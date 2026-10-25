import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import type { AddressInfo } from 'node:net';
import test, { type TestContext } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { createMatchingServer, MAX_REQUEST_BYTES, type HttpServerOptions } from '../src/api/http-server.ts';
import type { LifecycleDependencies } from '../src/api/lifecycle.ts';
import { RecentAuthenticationRequiredError, type AccountDeletionState, type LifecycleRepository } from '../src/lifecycle/types.ts';
import { RECEIPT_REQUEST_BURST } from '../src/api/account-admission.ts';
import { HOSTED_REQUESTS_PER_MINUTE } from '../src/api/request-admission.ts';

const pending: AccountDeletionState = { status: 'auth_pending', applicationDataDeleted: true, providerIdentityDeleted: false };
const complete: AccountDeletionState = { status: 'complete', applicationDataDeleted: true, providerIdentityDeleted: true };
const requestBody = { schemaVersion: '1', caseId: 'fictional-case', expectedCaseRevision: 2,
  expectedCatalogRevision: 3, confirmation: 'DELETE_CASE' };

function fakeLifecycle() {
  let removed = false;
  let providerGone = false;
  let confirmed = false;
  let savedHash: string | null = null;
  let authentications = 0;
  let receiptReads = 0;
  const lifecycle: LifecycleRepository = {
    isAccountClosed: async () => confirmed,
    deleteCaseIfCurrent: async value => {
      if (value.userId !== 'alice' || value.caseId !== 'fictional-case') return { status: 'not_found' };
      if (removed) return { status: 'deleted' };
      if (value.revision !== 2) return { status: 'conflict' };
      if (value.expectedCatalogRevision !== 3) return { status: 'evidence_conflict' };
      removed = true;
      return { status: 'deleted' };
    },
    prepareAccountDeletion: async value => {
      savedHash = value.tokenHash;
      return { status: 'ready', expiresAt: '2026-10-17T20:05:00Z', counts: { cases: 1, evidence: 0, exports: 0, storedBytes: 0 } };
    },
    confirmAccountDeletion: async value => {
      if (value.userId !== 'alice' || value.tokenHash !== savedHash) return { status: 'not_found' };
      confirmed = true;
      return { status: 'confirmed', deletion: pending };
    },
    readAccountDeletionReceipt: async hash => {
      receiptReads++;
      if (hash !== savedHash) return null;
      return providerGone ? complete : confirmed ? pending
        : { status: 'awaiting_confirmation', applicationDataDeleted: false, providerIdentityDeleted: false };
    },
  };
  const authenticate: LifecycleDependencies['authenticate'] = async token => {
    authentications++;
    return !providerGone && (token === 'alice' || token === 'bob') ? { userId: token } : null;
  };
  return { lifecycle, dependencies: { lifecycle, authenticate, authenticateForDeletion: authenticate },
    removeProviderIdentity: () => { providerGone = true; }, authenticationCount: () => authentications,
    receiptReadCount: () => receiptReads };
}

async function start(t: TestContext, options: HttpServerOptions = {}) {
  const deps = { authenticate: async () => null, cases: { loadForUser: async () => null,
    saveMatchIfCurrent: async () => 'not_found' as const }, loadRegistry: async () => [], now: () => new Date() };
  const server = createMatchingServer(deps, undefined, undefined, undefined, undefined, undefined, options);
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const post = (route: string, body: unknown = { schemaVersion: '1' }, token = 'alice') => fetch(`${base}/v1/${route}`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  return { server, base, post };
}

test('lifecycle routes are absent unless dependencies are explicitly configured', async t => {
  const { post } = await start(t, { hosted: true });
  for (const route of ['delete-case', 'prepare-account-deletion', 'confirm-account-deletion', 'account-deletion-status']) {
    const response = await post(route);
    assert.equal(response.status, 404);
    assert.equal((await response.json()).error.code, 'NOT_FOUND');
  }
});

test('real HTTP case deletion preserves CAS, ownership and same-owner replay', async t => {
  const fake = fakeLifecycle();
  const { post } = await start(t, { hosted: true, lifecycleDependencies: fake.dependencies });
  const other = await post('delete-case', requestBody, 'bob');
  const missing = await post('delete-case', { ...requestBody, caseId: 'missing' }, 'bob');
  assert.equal(other.status, 404); assert.deepEqual(await other.json(), await missing.json());
  const staleCase = await post('delete-case', { ...requestBody, expectedCaseRevision: 1 });
  assert.equal(staleCase.status, 409); assert.equal((await staleCase.json()).error.code, 'CASE_REVISION_MISMATCH');
  const staleEvidence = await post('delete-case', { ...requestBody, expectedCatalogRevision: 2 });
  assert.equal(staleEvidence.status, 409); assert.equal((await staleEvidence.json()).error.code, 'EVIDENCE_CONFLICT');
  const first = await post('delete-case', requestBody);
  const retry = await post('delete-case', requestBody);
  assert.equal(first.status, 200); assert.equal(retry.status, 200);
  assert.deepEqual(await first.json(), await retry.json());
  assert.equal(first.headers.get('cache-control'), 'no-store');
  assert.equal(first.headers.get('x-content-type-options'), 'nosniff');
});

test('real HTTP account receipt survives provider deletion and never claims pending Auth is complete', async t => {
  const fake = fakeLifecycle();
  const { post } = await start(t, { hosted: true, lifecycleDependencies: fake.dependencies });
  const previewResponse = await post('prepare-account-deletion');
  assert.equal(previewResponse.status, 200);
  const preview = await previewResponse.json();
  assert.match(preview.deletionToken, /^[a-f0-9]{64}$/);
  const waiting = await post('account-deletion-status', { schemaVersion: '1' }, preview.deletionToken);
  assert.deepEqual(await waiting.json(), { schemaVersion: '1', status: 'awaiting_confirmation',
    applicationDataDeleted: false, providerIdentityDeleted: false });
  const confirm = { schemaVersion: '1', deletionToken: preview.deletionToken, confirmation: 'DELETE_ACCOUNT' };
  const wrongOwner = await post('confirm-account-deletion', confirm, 'bob');
  assert.equal(wrongOwner.status, 404); assert.equal((await wrongOwner.json()).error.code, 'DELETION_NOT_FOUND');
  const accepted = await post('confirm-account-deletion', confirm);
  assert.equal(accepted.status, 202); assert.deepEqual(await accepted.json(), { schemaVersion: '1', ...pending });
  const replay = await post('confirm-account-deletion', confirm);
  assert.equal(replay.status, 202); assert.deepEqual(await replay.json(), { schemaVersion: '1', ...pending });
  fake.removeProviderIdentity();
  const count = fake.authenticationCount();
  const finished = await post('account-deletion-status', { schemaVersion: '1' }, preview.deletionToken);
  assert.equal(finished.status, 200); assert.deepEqual(await finished.json(), { schemaVersion: '1', ...complete });
  assert.equal(fake.authenticationCount(), count);
  const noUser = await post('confirm-account-deletion', confirm);
  assert.equal(noUser.status, 401);
});

test('receipt status is exact POST JSON and rejects query tokens, duplicate auth and wrong token form', async t => {
  const fake = fakeLifecycle();
  const { post, base } = await start(t, { hosted: true, lifecycleDependencies: fake.dependencies });
  for (const path of ['/v1/account-deletion-status?token=secret', '/v1/account-deletion-status/']) {
    assert.equal((await fetch(base + path)).status, 404);
  }
  const get = await fetch(`${base}/v1/account-deletion-status`);
  assert.equal(get.status, 405); assert.equal(get.headers.get('allow'), 'POST');
  assert.equal((await post('account-deletion-status')).status, 401);
  assert.equal((await post('account-deletion-status', { schemaVersion: '1', owner: 'alice' }, 'a'.repeat(64))).status, 400);
  const duplicate = await new Promise<number>(resolve => {
    const url = new URL(base);
    const req = httpRequest(`${base}/v1/account-deletion-status`, { method: 'POST', headers: [
      'Host', url.host, 'Authorization', `Bearer ${'a'.repeat(64)}`, 'Authorization', `Bearer ${'b'.repeat(64)}`,
      'Content-Type', 'application/json',
    ] }, response => { response.resume(); response.on('end', () => resolve(response.statusCode!)); });
    req.end('{"schemaVersion":"1"}');
  });
  assert.equal(duplicate, 401);
  assert.equal(fake.receiptReadCount(), 0);
});

test('lifecycle routes retain HTTP body limits, JSON encoding rules and sanitized recent-auth errors', async t => {
  const fake = fakeLifecycle();
  const { post, base } = await start(t, { hosted: true, lifecycleDependencies: {
    ...fake.dependencies, authenticateForDeletion: async () => { throw new RecentAuthenticationRequiredError(); },
  } });
  const stale = await post('prepare-account-deletion');
  assert.equal(stale.status, 403); assert.equal((await stale.json()).error.code, 'RECENT_AUTHENTICATION_REQUIRED');
  const oversized = await fetch(`${base}/v1/prepare-account-deletion`, { method: 'POST',
    headers: { Authorization: 'Bearer alice', 'Content-Type': 'application/json' }, body: ' '.repeat(MAX_REQUEST_BYTES + 1) });
  assert.equal(oversized.status, 413); assert.equal((await oversized.json()).error.code, 'PAYLOAD_TOO_LARGE');
  const unsupportedHeaders: Record<string, string>[] = [{ 'Content-Type': 'text/plain' },
    { 'Content-Type': 'application/json', 'Content-Encoding': 'gzip' }];
  for (const headers of unsupportedHeaders) {
    const response = await fetch(`${base}/v1/prepare-account-deletion`, { method: 'POST',
      headers: { Authorization: 'Bearer alice', ...headers }, body: '{}' });
    assert.equal(response.status, 415);
  }
  const malformed = await fetch(`${base}/v1/prepare-account-deletion`, { method: 'POST',
    headers: { Authorization: 'Bearer alice', 'Content-Type': 'application/json' }, body: '{' });
  assert.equal(malformed.status, 400);
});

test('receipt capability checks remain inside the hosted request budget', async t => {
  const fake = fakeLifecycle();
  const { post, base } = await start(t, { hosted: true, admissionNow: () => 0, lifecycleDependencies: fake.dependencies });
  for (let index = 0; index < HOSTED_REQUESTS_PER_MINUTE; index++) {
    const response = await post('account-deletion-status', { schemaVersion: '1' }, 'a'.repeat(64));
    assert.equal(response.status, index < RECEIPT_REQUEST_BURST ? 404 : 503);
    if (index >= RECEIPT_REQUEST_BURST) assert.equal(response.headers.get('retry-after'), '3');
  }
  const blocked = await post('account-deletion-status', { schemaVersion: '1' }, 'a'.repeat(64));
  assert.equal(blocked.status, 503);
  assert.equal(blocked.headers.get('retry-after'), '60');
  assert.equal(fake.receiptReadCount(), RECEIPT_REQUEST_BURST);
  assert.equal(fake.authenticationCount(), 0);
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
});

test('disconnect during deletion cannot release the hosted heavy slot while its transaction is pending', async t => {
  const fake = fakeLifecycle();
  let settle!: () => void;
  let entered!: () => void;
  const transaction = new Promise<void>(resolve => { settle = resolve; });
  const started = new Promise<void>(resolve => { entered = resolve; });
  let calls = 0;
  fake.lifecycle.deleteCaseIfCurrent = async () => {
    calls++;
    if (calls === 1) { entered(); await transaction; }
    return { status: 'deleted' };
  };
  const { post, base } = await start(t, { hosted: true, lifecycleDependencies: fake.dependencies });
  const request = httpRequest(`${base}/v1/delete-case`, { method: 'POST',
    headers: { Authorization: 'Bearer alice', 'Content-Type': 'application/json' } });
  request.on('error', () => {});
  request.end(JSON.stringify(requestBody));
  try {
    await started;
    request.destroy();
    const blocked = await post('confirm-account-deletion', { schemaVersion: '1', deletionToken: 'a'.repeat(64), confirmation: 'DELETE_ACCOUNT' });
    assert.equal(blocked.status, 503);
    assert.equal(fake.authenticationCount(), 1);
    settle();
    let response: Response | undefined;
    for (let attempt = 0; attempt < 20; attempt++) {
      response = await post('delete-case', requestBody);
      if (response.status !== 503) break;
      await delay(5);
    }
    assert.equal(response?.status, 200);
  } finally { settle(); request.destroy(); }
});
