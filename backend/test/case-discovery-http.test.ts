import assert from 'node:assert/strict';
import { request } from 'node:http';
import type { AddressInfo } from 'node:net';
import test, { type TestContext } from 'node:test';
import { createMatchingServer, MAX_REQUEST_BYTES } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import type { CaseSnapshot } from '../src/types.ts';

const snapshot = (caseId: string): CaseSnapshot => ({ schemaVersion: '1', caseId, revision: 1,
  profile: { city: 'PRIVATE CITY', county: null, healthPlan: null, tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: 0, ownerConsentReported: false },
  unresolvedFields: [], findings: [] });
async function start(t: TestContext, enabled = true) {
  const cases = new MemoryCaseRepository([
    { userId: 'alice', snapshot: snapshot('a') }, { userId: 'alice', snapshot: snapshot('c') },
    { userId: 'bob', snapshot: snapshot('b') },
  ]);
  const deps = { cases, now: () => new Date('2026-10-18T05:00:00Z'), loadRegistry: async () => [],
    authenticate: async (token: string) => ['alice', 'bob', 'empty'].includes(token) ? { userId: token } : null };
  const server = createMatchingServer(deps, undefined, undefined, undefined, deps, undefined,
    { hosted: true, ...(enabled ? { caseListDependencies: deps } : {}) });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve()); server.closeAllConnections();
  }));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/`;
  const send = (route: string, body: unknown, token = 'alice') => fetch(base + route,
    { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return { base, send, cases };
}
const first = { schemaVersion: '1', limit: 1, afterCaseId: null };

test('real HTTP discovers only owned summaries and resumes the newest saved case', async t => {
  const { send } = await start(t);
  const response = await send('list-cases', first);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  assert.deepEqual(await response.json(), { schemaVersion: '1', cases: [{ caseId: 'a', caseRevision: 1 }], nextAfterCaseId: 'a' });
  assert.deepEqual(await (await send('list-cases', { ...first, afterCaseId: 'a' })).json(),
    { schemaVersion: '1', cases: [{ caseId: 'c', caseRevision: 1 }], nextAfterCaseId: null });
  assert.deepEqual(await (await send('list-cases', first, 'bob')).json(),
    { schemaVersion: '1', cases: [{ caseId: 'b', caseRevision: 1 }], nextAfterCaseId: null });
  assert.deepEqual(await (await send('list-cases', first, 'empty')).json(),
    { schemaVersion: '1', cases: [], nextAfterCaseId: null });
  const { revision, ...draft } = snapshot('a');
  assert.equal((await send('save-case', { ...draft, expectedCaseRevision: revision,
    profile: { ...draft.profile, city: 'UPDATED PRIVATE CITY' } })).status, 200);
  const resumed = await (await send('read-case', { schemaVersion: '1', caseId: 'a' })).json();
  assert.equal(resumed.revision, 2); assert.equal(resumed.profile.city, 'UPDATED PRIVATE CITY');
  const refreshed = await (await send('list-cases', first)).json();
  assert.equal(refreshed.cases[0].caseRevision, 2);
  assert.ok(!JSON.stringify(refreshed).includes('PRIVATE'));
  assert.equal((await send('read-case', { schemaVersion: '1', caseId: 'a' }, 'bob')).status, 404);
});

test('discovery requires explicit composition and exact route/method', async t => {
  const disabled = await start(t, false);
  assert.equal((await disabled.send('list-cases', first)).status, 404);
  const { base, send } = await start(t);
  assert.equal((await send('list-cases/', first)).status, 404);
  assert.equal((await send('list-cases?owner=bob', first)).status, 404);
  const get = await fetch(base + 'list-cases');
  assert.equal(get.status, 405); assert.equal(get.headers.get('allow'), 'POST');
});

test('discovery rejects ambiguous auth, unknown fields, unsupported encoding and excessive bodies', async t => {
  const { base, send } = await start(t);
  assert.equal((await send('list-cases', first, 'invalid')).status, 401);
  assert.equal((await send('list-cases', { ...first, ownerId: 'bob' })).status, 400);
  assert.equal((await send('list-cases', { ...first, limit: 21 })).status, 400);
  const encoded = await fetch(base + 'list-cases', { method: 'POST',
    headers: { Authorization: 'Bearer alice', 'Content-Type': 'application/json', 'Content-Encoding': 'gzip' }, body: '{}' });
  assert.equal(encoded.status, 415);
  const large = await send('list-cases', { ...first, padding: 'x'.repeat(MAX_REQUEST_BYTES) });
  assert.equal(large.status, 413);
  const duplicate = await new Promise<number>((resolve, reject) => {
    const req = request(base + 'list-cases', { method: 'POST', headers:
      ['Host', new URL(base).host, 'Authorization', 'Bearer alice', 'Authorization', 'Bearer bob', 'Content-Type', 'application/json'] }, res => {
      res.resume(); res.on('end', () => resolve(res.statusCode!));
    });
    req.on('error', reject); req.end(JSON.stringify(first));
  });
  assert.equal(duplicate, 401);
});
