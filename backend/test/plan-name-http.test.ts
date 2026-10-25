import assert from 'node:assert/strict';
import { request } from 'node:http';
import type { AddressInfo } from 'node:net';
import test, { type TestContext } from 'node:test';
import { createMatchingServer, MAX_REQUEST_BYTES } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { draft } from './postgres/fixtures.ts';

async function start(t: TestContext, enabled = true) {
  const cases = new MemoryCaseRepository([{ userId: 'alice', snapshot: { ...draft('a'), revision: 1 } },
    { userId: 'alice', snapshot: { ...draft('c'), revision: 1 } }, { userId: 'bob', snapshot: { ...draft('b'), revision: 1 } }]);
  let authCalls = 0;
  const deps = { cases, now: () => new Date(), loadRegistry: async () => [],
    authenticate: async (token: string) => { authCalls++; return ['alice', 'bob'].includes(token) ? { userId: token } : null; } };
  const server = createMatchingServer(deps, undefined, undefined, undefined, deps, undefined,
    { hosted: true, caseListDependencies: deps, ...(enabled ? { planNameDependencies: deps } : {}) });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>((resolve, reject) => { server.close(error => error ? reject(error) : resolve()); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const send = (route: string, body: unknown, token = 'alice') => fetch(`${base}${route}`,
    { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return { base, send, authCalls: () => authCalls };
}
const read = { schemaVersion: '2', caseId: 'a' };
const save = { ...read, name: 'Fictional family home', expectedNameRevision: 0, mutationId: 'fictional-first-name' };
test('real hosted HTTP exposes names only to owners, preserves v1 metadata and returns latest exact retry', async t => {
  const { send, authCalls } = await start(t);
  const result = await send('/v2/save-plan-name', save);
  assert.equal(result.status, 200); assert.equal(authCalls(), 1);
  assert.equal(result.headers.get('cache-control'), 'no-store'); assert.equal(result.headers.get('x-content-type-options'), 'nosniff');
  const state = await result.json(); assert.equal(state.nameRevision, 1);
  assert.deepEqual(await (await send('/v2/save-plan-name', save)).json(), state);
  assert.deepEqual(await (await send('/v2/read-plan-name', read)).json(), state);
  assert.equal((await send('/v2/read-plan-name', read, 'bob')).status, 404);
  assert.equal((await send('/v2/save-plan-name', save, 'bob')).status, 404);
  const conflict = await send('/v2/save-plan-name', { ...save, name: 'Stale edit' });
  assert.equal(conflict.status, 409); assert.equal((await conflict.json()).error.code, 'PLAN_NAME_CONFLICT');
  assert.deepEqual(await (await send('/v1/list-cases', { schemaVersion: '1', limit: 1, afterCaseId: null })).json(),
    { schemaVersion: '1', cases: [{ caseId: 'a', caseRevision: 1 }], nextAfterCaseId: 'a' });
  const first = await (await send('/v2/list-cases', { schemaVersion: '2', limit: 1, afterCaseId: null })).json();
  assert.deepEqual(first, { schemaVersion: '2', cases: [{ caseId: 'a', caseRevision: 1, name: save.name,
    nameRevision: 1, lastMutationId: save.mutationId }], nextAfterCaseId: 'a' });
  const next = await (await send('/v2/list-cases', { schemaVersion: '2', limit: 1, afterCaseId: first.nextAfterCaseId })).json();
  assert.deepEqual(next.cases, [{ caseId: 'c', caseRevision: 1, name: null, nameRevision: 0, lastMutationId: null }]);
});
test('new routes require explicit injection and exact path, method and bounded authenticated JSON', async t => {
  const disabled = await start(t, false); assert.equal((await disabled.send('/v2/read-plan-name', read)).status, 404);
  const { base, send } = await start(t);
  for (const route of ['/v2/read-plan-name', '/v2/save-plan-name', '/v2/list-cases']) {
    assert.equal((await fetch(base + route)).status, 405);
    assert.equal((await send(route + '?owner=bob', read)).status, 404);
    assert.equal((await send(route, read, 'invalid')).status, 401);
  }
  assert.equal((await send('/v2/save-plan-name', { ...save, ownerId: 'bob' })).status, 400);
  assert.equal((await send('/v2/save-plan-name', { ...save, name: 'x'.repeat(MAX_REQUEST_BYTES) })).status, 413);
  const duplicate = await new Promise<number>((resolve, reject) => {
    const req = request(base + '/v2/read-plan-name', { method: 'POST', headers:
      ['Host', new URL(base).host, 'Authorization', 'Bearer alice', 'Authorization', 'Bearer bob', 'Content-Type', 'application/json'] }, res => {
      res.resume(); res.on('end', () => resolve(res.statusCode!));
    }); req.on('error', reject); req.end(JSON.stringify(read));
  });
  assert.equal(duplicate, 401);
});
