import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import test from 'node:test';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { draft } from './postgres/fixtures.ts';
import { demoProgram } from '../fixtures/demo-program.ts';
test('tracking HTTP is authenticated, owner scoped, versioned, bounded, and default off', async t => {
  const cases = new MemoryCaseRepository([{ userId: 'alice', snapshot: { ...draft('fictional-case'), revision: 1 } }]);
  let calls = 0;
  const deps = { cases, loadRegistry: async () => [demoProgram], allowDemoPrograms: true, now: () => new Date('2026-10-24T12:00:00.000Z'), authenticate: async (token: string) => { calls++; return ['alice','bob'].includes(token) ? { userId: token } : null; } };
  const server = createMatchingServer(deps, undefined, undefined, undefined, deps, undefined, { hosted: true, progressDependencies: deps });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const post = (route: string, body: unknown, token = 'alice') => fetch(base + route, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const read = { schemaVersion: '3', caseId: 'fictional-case', offset: 0, limit: 20, expectedProgressRevision: null, expectedCaseRevision: null, expectedHistoryVersion: null };
  let response = await post('/v3/read-progress', read); assert.equal(response.status, 200); assert.equal(calls, 1); assert.equal(response.headers.get('cache-control'), 'no-store');
  const request = { schemaVersion: '3', caseId: 'fictional-case', expectedCaseRevision: 1, expectedProgressRevision: 0, mutationId: 'fictional-track', operation: { type: 'track_program', programId: demoProgram.programId } };
  response = await post('/v3/save-progress', request); assert.equal(response.status, 200); assert.equal((await response.json()).programs[0].latest, null);
  response = await post('/v3/save-progress', request); assert.equal(response.status, 200); assert.equal((await response.json()).revision, 1);
  assert.equal((await post('/v3/read-progress', read, 'bob')).status, 404);
  assert.equal((await post('/v3/read-progress', { ...read, invalid: true }, 'expired')).status, 401);
  assert.equal((await post('/v3/read-progress', { ...read, invalid: true })).status, 400);
  assert.equal((await post('/v3/read-progress', { ...read, extra: 'x'.repeat(17 * 1024) })).status, 413);
  assert.equal((await post('/v3/read-progress', { ...read, expectedProgressRevision: 0 })).status, 409);
  assert.equal((await post('/v3/read-progress-history', { ...read, programId: demoProgram.programId })).status, 200);
  const stable = await (await post('/v3/read-progress', read)).json();
  await cases.appendRequestUpdateForUser({ userId: 'alice', caseId: read.caseId, revision: 1, programId: demoProgram.programId, expectedRequestRevision: 0, recordedAt: '2026-10-24T12:00:00.000Z', update: {
    updateId: '11111111-0000-4000-8000-000000000001', status: 'preparing', occurredOn: '2026-10-24', source: 'self_report', note: null, nextAction: null, responsibleParty: null, followUpOn: null } });
  assert.equal((await post('/v3/read-progress', { ...read, expectedHistoryVersion: stable.historyVersion })).status, 409);

  assert.equal((await post('/v3/read-progress?case=x', read)).status, 404);
  const disabled = createMatchingServer(deps);
  await new Promise<void>(resolve => disabled.listen(0, '127.0.0.1', resolve)); t.after(() => { disabled.closeAllConnections(); disabled.close(); });
  assert.equal((await fetch(`http://127.0.0.1:${(disabled.address() as AddressInfo).port}/v3/read-progress`, { method: 'POST', headers: { Authorization: 'Bearer alice', 'Content-Type': 'application/json' }, body: JSON.stringify(read) })).status, 404);
});
