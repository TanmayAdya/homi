import assert from 'node:assert/strict';
import { request } from 'node:http';
import type { AddressInfo } from 'node:net';
import test, { type TestContext } from 'node:test';
import { demoProgram } from '../fixtures/demo-program.ts';
import { createMatchingServer, MAX_REQUEST_BYTES } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import type { RequestUpdate } from '../src/requests/tracking.ts';
import type { CaseSnapshot } from '../src/types.ts';

const NOW = '2026-10-18T10:00:00.000Z';
const PROGRAM = 'scfhp-eaa';
const ID = '01000000-0000-4000-8000-000000000001';
const readBody = { schemaVersion: '1', caseId: 'case-alice', expectedCaseRevision: 1, programId: PROGRAM };
const update = (overrides: Partial<RequestUpdate> = {}): RequestUpdate => ({ updateId: ID, status: 'preparing',
  occurredOn: '2026-10-18', source: 'self_report', note: null, nextAction: null,
  responsibleParty: null, followUpOn: null, ...overrides });
const appendBody = () => ({ ...readBody, expectedRequestRevision: 0, update: update() });
const snapshot = (caseId: string): CaseSnapshot => ({ schemaVersion: '1', caseId, revision: 1,
  profile: { city: 'PRIVATE fictional city', county: null, healthPlan: null, tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: 0, ownerConsentReported: false },
  unresolvedFields: [], findings: [] });

async function start(t: TestContext, enabled = true) {
  const cases = new MemoryCaseRepository([{ userId: 'alice', snapshot: snapshot('case-alice') },
    { userId: 'bob', snapshot: snapshot('case-bob') }]);
  const deps = { cases, now: () => new Date(NOW),
    loadRegistry: async () => [{ ...demoProgram, programId: PROGRAM, isDemo: false }],
    authenticate: async (token: string) => ['alice', 'bob'].includes(token) ? { userId: token } : null };
  const server = createMatchingServer(deps, undefined, undefined, undefined, deps, undefined,
    { hosted: true, ...(enabled ? { requestTrackingDependencies: deps } : {}) });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve()); server.closeAllConnections();
  }));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/`;
  const send = (route: string, body: unknown, token = 'alice') => fetch(base + route,
    { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return { base, send, cases };
}

test('real HTTP records only user-reported history, resumes it and leaves the case revision unchanged', async t => {
  const { send } = await start(t);
  const empty = await send('read-request-history', readBody);
  assert.equal(empty.status, 200); assert.equal(empty.headers.get('cache-control'), 'no-store');
  assert.equal(empty.headers.get('x-content-type-options'), 'nosniff');
  assert.deepEqual(await empty.json(), { schemaVersion: '1', caseId: 'case-alice', caseRevision: 1,
    programId: PROGRAM, requestRevision: 0, provenance: 'user_reported', events: [] });
  const response = await send('append-request-update', appendBody());
  assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'no-store');
  const history = await response.json();
  assert.equal(history.requestRevision, 1); assert.equal(history.caseRevision, 1); assert.equal(history.provenance, 'user_reported');
  assert.deepEqual(history.events, [{ ...update(), revision: 1, caseRevision: 1, recordedAt: NOW }]);
  assert.deepEqual(await (await send('read-request-history', readBody)).json(), history);
  assert.deepEqual(await (await send('append-request-update', appendBody())).json(), history);
  const unchanged = await (await send('read-case', { schemaVersion: '1', caseId: 'case-alice' })).json();
  assert.equal(unchanged.revision, 1);
  for (const route of ['read-request-history', 'append-request-update']) {
    const denied = await send(route, route === 'read-request-history' ? readBody : appendBody(), 'bob');
    assert.equal(denied.status, 404); assert.equal((await denied.json()).error.code, 'CASE_NOT_FOUND');
  }
});

test('tracking requires explicit route composition and rejects variants and non-POST methods', async t => {
  const disabled = await start(t, false);
  for (const route of ['read-request-history', 'append-request-update']) {
    assert.equal((await disabled.send(route, readBody)).status, 404);
  }
  const { base, send } = await start(t);
  for (const route of ['read-request-history/', 'read-request-history?caseId=case-bob', 'append-request-update/']) {
    assert.equal((await send(route, readBody)).status, 404);
  }
  for (const route of ['read-request-history', 'append-request-update']) {
    const response = await fetch(base + route);
    assert.equal(response.status, 405); assert.equal(response.headers.get('allow'), 'POST');
  }
});

test('tracking HTTP rejects ambiguous auth, extra fields, bad encoding and oversized request bytes', async t => {
  const { base, send } = await start(t);
  for (const route of ['read-request-history', 'append-request-update']) {
    assert.equal((await send(route, {}, 'invalid')).status, 401);
    const auth = await send(route, {}, 'x'.repeat(4097)); assert.equal(auth.status, 401);
    assert.equal(auth.headers.get('www-authenticate'), 'Bearer');
  }
  assert.equal((await send('append-request-update', { ...appendBody(), ownerId: 'bob' })).status, 400);
  assert.equal((await send('append-request-update', { ...appendBody(), update: { ...update(), recordedAt: NOW } })).status, 400);
  const encoded = await fetch(base + 'append-request-update', { method: 'POST', headers: {
    Authorization: 'Bearer alice', 'Content-Type': 'application/json', 'Content-Encoding': 'gzip' }, body: '{}' });
  assert.equal(encoded.status, 415);
  const wrongType = await fetch(base + 'read-request-history', { method: 'POST', headers: {
    Authorization: 'Bearer alice', 'Content-Type': 'text/plain' }, body: JSON.stringify(readBody) });
  assert.equal(wrongType.status, 415);
  const oversized = await send('append-request-update', { ...appendBody(), padding: '🙂'.repeat(MAX_REQUEST_BYTES) });
  assert.equal(oversized.status, 413);
  const duplicate = await new Promise<number>((resolve, reject) => {
    const req = request(base + 'read-request-history', { method: 'POST', headers: [
      'Host', new URL(base).host, 'Authorization', 'Bearer alice', 'Authorization', 'Bearer bob', 'Content-Type', 'application/json',
    ] }, response => { response.resume(); response.on('end', () => resolve(response.statusCode!)); });
    req.on('error', reject); req.end(JSON.stringify(readBody));
  });
  assert.equal(duplicate, 401);
});

test('the maximum Unicode history remains under the client response bound with no private case fields', async t => {
  const { send, cases } = await start(t);
  for (let index = 0; index < 50; index++) {
    const stored = await cases.appendRequestUpdateForUser({ userId: 'alice', caseId: 'case-alice', revision: 1,
      programId: PROGRAM, expectedRequestRevision: index, recordedAt: NOW,
      update: update({ updateId: `01000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`,
        note: '🙂'.repeat(500), nextAction: '🙂'.repeat(250), responsibleParty: 'resident', followUpOn: '2026-10-20' }) });
    assert.equal(stored.status, 'found');
  }
  const response = await send('read-request-history', readBody); assert.equal(response.status, 200);
  const raw = await response.text(); assert.ok(Buffer.byteLength(raw) < 256 * 1024);
  assert.equal(JSON.parse(raw).events.length, 50); assert.ok(!raw.includes('PRIVATE'));
  const full = await send('append-request-update', { ...appendBody(), expectedRequestRevision: 50,
    update: update({ updateId: '01000000-0000-4000-8000-000000000051' }) });
  assert.equal(full.status, 409); assert.equal((await full.json()).error.code, 'REQUEST_HISTORY_FULL');
});
