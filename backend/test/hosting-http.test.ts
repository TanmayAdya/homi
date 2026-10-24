import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import type { AddressInfo } from 'node:net';
import test, { type TestContext } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { createMatchingServer, type HttpServerOptions } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import type { AuthenticatedUser } from '../src/api/match-case.ts';
import { createHostedAdmission, HOSTED_MAX_ACTIVE_REQUESTS, HOSTED_REQUESTS_PER_MINUTE } from '../src/api/request-admission.ts';

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function start(t: TestContext,
  authenticate: (token: string) => Promise<AuthenticatedUser | null> = async () => null,
  options: HttpServerOptions = { hosted: true },
) {
  const dependencies = { authenticate, cases: new MemoryCaseRepository([]), now: () => new Date(),
    loadRegistry: async () => [], loadFormTemplate: async () => null };
  const server = createMatchingServer(dependencies, dependencies, dependencies, dependencies,
    dependencies, dependencies, options);
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const send = (path = '/v1/read-case', extraHeaders: Record<string, string> = {}) => fetch(base + path, {
    method: 'POST', headers: { Authorization: 'Bearer fictional-token', 'Content-Type': 'application/json', ...extraHeaders },
    body: '{}',
  });
  return { server, base, send };
}

test('hosted health is exact GET/HEAD, private-data-free and independent of auth/database work', async t => {
  let authentications = 0;
  const { server, base } = await start(t, async () => { authentications++; throw new Error('Must not run'); });
  assert.equal(server.maxConnections, 64);
  assert.equal(server.maxRequestsPerSocket, 100);
  for (const method of ['GET', 'HEAD']) {
    const response = await fetch(`${base}/healthz`, { method });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(await response.text(), method === 'GET' ? '{"status":"ok"}' : '');
  }
  const wrongMethod = await fetch(`${base}/healthz`, { method: 'POST' });
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.headers.get('allow'), 'GET, HEAD');
  assert.equal((await fetch(`${base}/healthz?debug=true`)).status, 404);
  assert.equal((await fetch(`${base}/healthz/`)).status, 404);
  assert.equal((await fetch(`${base}/v1/read-case`)).status, 405);
  assert.equal(authentications, 0);
});

test('demo/default factory has no hosted health route or new admission limits', async t => {
  const { server, base, send } = await start(t, async () => null, {});
  assert.equal(server.maxConnections, undefined);
  assert.equal(server.maxRequestsPerSocket, 0);
  assert.equal((await fetch(`${base}/healthz`)).status, 404);
  for (let index = 0; index <= HOSTED_REQUESTS_PER_MINUTE; index++) assert.equal((await send()).status, 401);
});

test('minute budget rejects before authentication and ignores forged forwarded identities', async t => {
  let clock = 0;
  let authentications = 0;
  const { base, send } = await start(t, async () => { authentications++; return null; },
    { hosted: true, admissionNow: () => clock });
  for (let index = 0; index < HOSTED_REQUESTS_PER_MINUTE; index++) assert.equal((await send()).status, 401);
  const full = await send('/v1/read-case', { 'X-Forwarded-For': '127.0.0.1', 'X-Real-IP': '192.0.2.1' });
  assert.equal(full.status, 503);
  assert.equal((await full.json()).error.code, 'SERVICE_UNAVAILABLE');
  assert.equal(full.headers.get('retry-after'), '60');
  assert.equal(authentications, HOSTED_REQUESTS_PER_MINUTE);
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  clock = 59_999;
  assert.equal((await send()).headers.get('retry-after'), '1');
  clock = 60_000;
  assert.equal((await send()).status, 401);
  assert.equal(authentications, HOSTED_REQUESTS_PER_MINUTE + 1);
});

test('global active bound rejects before auth and releases every completed failure', async t => {
  const blocked = deferred<null>();
  const reached = deferred<void>();
  let authentications = 0;
  const { send, base } = await start(t, async () => {
    authentications++;
    if (authentications === HOSTED_MAX_ACTIVE_REQUESTS) reached.resolve();
    return blocked.promise;
  });
  const running = Array.from({ length: HOSTED_MAX_ACTIVE_REQUESTS }, () => send());
  try {
    await reached.promise;
    const busy = await send();
    assert.equal(busy.status, 503);
    assert.equal(busy.headers.get('retry-after'), '1');
    assert.equal(authentications, HOSTED_MAX_ACTIVE_REQUESTS);
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
  } finally { blocked.resolve(null); }
  assert.equal((await Promise.all(running)).every(response => response.status === 401), true);
  assert.equal((await send()).status, 401);
  assert.equal(authentications, HOSTED_MAX_ACTIVE_REQUESTS + 1);
});

test('disconnect cannot free the shared heavy slot before asynchronous work settles', async t => {
  const blocked = deferred<null>();
  const reached = deferred<void>();
  let authentications = 0;
  const { base, send } = await start(t, async () => {
    authentications++;
    if (authentications === 1) { reached.resolve(); return blocked.promise; }
    return null;
  });
  const request = httpRequest(`${base}/v1/download-evidence`, { method: 'POST',
    headers: { Authorization: 'Bearer fictional-token', 'Content-Type': 'application/json' } });
  request.on('error', () => {});
  request.end('{}');
  try {
    await reached.promise;
    request.destroy();
    const busy = await send('/v1/create-draft-export');
    assert.equal(busy.status, 503);
    assert.equal(authentications, 1);
    blocked.reject(new Error('Fictional dependency failure'));
    let response: Response | undefined;
    for (let attempt = 0; attempt < 20; attempt++) {
      response = await send('/v1/download-draft-export');
      if (response.status !== 503) break;
      await delay(5);
    }
    assert.equal(response?.status, 401);
    assert.equal(authentications, 2);
  } finally { blocked.resolve(null); request.destroy(); }
});

test('abandoned upload pre-auth retains hosted admission until the provider settles', async t => {
  const blocked = deferred<null>();
  const reached = deferred<void>();
  const closed = deferred<void>();
  let authentications = 0;
  const { server, base, send } = await start(t, async () => {
    authentications++;
    if (authentications === 1) { reached.resolve(); return blocked.promise; }
    return null;
  });
  server.once('request', (_request, response) => {
    response.once('close', () => setImmediate(() => closed.resolve()));
  });
  const request = httpRequest(`${base}/v1/upload-evidence`, { method: 'POST',
    headers: { Authorization: 'Bearer fictional-token', 'Content-Type': 'application/json', 'Content-Length': '2' } });
  request.on('error', () => {});
  request.flushHeaders();
  try {
    await reached.promise;
    request.destroy();
    await closed.promise;
    assert.equal((await send('/v1/download-evidence')).status, 503);
    assert.equal(authentications, 1);
    blocked.resolve(null);
    let response: Response | undefined;
    for (let attempt = 0; attempt < 20; attempt++) {
      response = await send('/v1/download-evidence');
      if (response.status !== 503) break;
      await delay(5);
    }
    assert.equal(response?.status, 401);
    assert.equal(authentications, 2);
  } finally { blocked.resolve(null); request.destroy(); }
});

test('abandoned upload post-body auth also retains the hosted heavy slot', async t => {
  const blocked = deferred<null>();
  const reached = deferred<void>();
  const closed = deferred<void>();
  let authentications = 0;
  const { server, base, send } = await start(t, async () => {
    authentications++;
    if (authentications === 1) return { userId: 'fictional-owner' };
    if (authentications === 2) { reached.resolve(); return blocked.promise; }
    return null;
  });
  server.once('request', (_request, response) => {
    response.once('close', () => setImmediate(() => closed.resolve()));
  });
  const request = httpRequest(`${base}/v1/upload-evidence`, { method: 'POST',
    headers: { Authorization: 'Bearer fictional-token', 'Content-Type': 'application/json' } });
  request.on('error', () => {});
  request.end(JSON.stringify({ schemaVersion: '1', caseId: 'fictional-case', expectedCaseRevision: 1,
    expectedCatalogRevision: 0, evidenceId: 'fictional-photo', expectedEvidenceRevision: 0,
    findingId: 'fictional-finding', capturedAt: null, imageBase64: 'iVBORw0KGgo=' }));
  try {
    await reached.promise;
    request.destroy();
    await closed.promise;
    assert.equal((await send('/v1/download-evidence')).status, 503);
    assert.equal(authentications, 2);
    blocked.resolve(null);
    let response: Response | undefined;
    for (let attempt = 0; attempt < 20; attempt++) {
      response = await send('/v1/download-evidence');
      if (response.status !== 503) break;
      await delay(5);
    }
    assert.equal(response?.status, 401);
    assert.equal(authentications, 3);
  } finally { blocked.resolve(null); request.destroy(); }
});

test('settled heavy handler retains admission until its response finishes', async t => {
  const { server, send } = await start(t);
  const held = deferred<void>();
  let flush: () => void = () => {};
  let intercept = true;
  server.prependListener('request', (request, response) => {
    if (!intercept || request.url !== '/v1/download-evidence') return;
    intercept = false;
    const end = response.end.bind(response);
    response.end = function(chunk?: any, encoding?: any, callback?: any) {
      flush = () => { end(chunk, encoding, callback); };
      held.resolve();
      return response;
    };
  });
  const first = send('/v1/download-evidence');
  try {
    await held.promise;
    assert.equal((await send('/v1/download-draft-export')).status, 503);
  } finally { flush(); }
  assert.equal((await first).status, 401);
  assert.equal((await send('/v1/download-draft-export')).status, 401);
});

test('admission release is idempotent and clock rollback does not reset the budget', () => {
  let clock = 50_000;
  const admission = createHostedAdmission(() => clock);
  for (let index = 0; index < HOSTED_REQUESTS_PER_MINUTE; index++) {
    const permit = admission.acquire(false);
    assert.equal(permit.accepted, true);
    if (permit.accepted) { permit.release(); permit.release(); }
  }
  clock = 0;
  assert.deepEqual(admission.acquire(false), { accepted: false, retryAfter: 60 });
  clock = 110_000;
  const permits = Array.from({ length: HOSTED_MAX_ACTIVE_REQUESTS }, () => admission.acquire(false));
  assert.equal(permits.every(permit => permit.accepted), true);
  assert.deepEqual(admission.acquire(false), { accepted: false, retryAfter: 1 });
  permits.forEach(permit => { if (permit.accepted) permit.release(); });
});
