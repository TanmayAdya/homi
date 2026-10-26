import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import test from 'node:test';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { draft } from './postgres/fixtures.ts';

test('v3 uses real HTTP authentication/admission, bounded input, private owner responses and exact paths', async t => {
  const cases = new MemoryCaseRepository([{ userId: 'alice', snapshot: { ...draft('fictional-case'), revision: 1 } }]);
  let calls = 0;
  const deps = { cases, loadRegistry: async () => [], now: () => new Date('2026-10-24T12:00:00.000Z'),
    authenticate: async (token: string) => { calls++; return ['alice', 'bob'].includes(token) ? { userId: token } : null; } };
  const server = createMatchingServer(deps, undefined, undefined, undefined, deps, undefined, { hosted: true, homeSafetyDependencies: deps });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const post = (route: string, body: unknown, token = 'alice') => fetch(base + route, { method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const read = { schemaVersion: '3', caseId: 'fictional-case' };
  let response = await post('/v3/read-home-safety', read); assert.equal(response.status, 200); assert.equal(calls, 1);
  assert.equal(response.headers.get('cache-control'), 'no-store'); assert.equal((await response.json()).safety.revision, 0);
  response = await post('/v3/save-home-safety', { ...read, expectedCaseRevision: 1, expectedSafetyRevision: 0, mutationId: 'fictional-first',
    operation: { type: 'add_room', room: { id: 'fictional-room', type: 'bedroom', name: null } } });
  assert.equal(response.status, 200); assert.equal((await response.json()).case.revision, 1);
  assert.equal((await post('/v3/read-home-safety', read, 'bob')).status, 404);
  assert.equal((await post('/v3/read-home-safety', { ...read, caseId: null }, 'expired')).status, 401);
  assert.equal((await post('/v3/read-home-safety', { ...read, extra: true })).status, 400);
  assert.equal((await post('/v3/read-home-safety', { ...read, extra: 'x'.repeat(17 * 1024) })).status, 413);
  assert.equal((await post('/v3/read-home-safety?case=other', read)).status, 404);
  assert.equal((await fetch(base + '/v3/read-home-safety', { headers: { Authorization: 'Bearer alice' } })).status, 405);
});
