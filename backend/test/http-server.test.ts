import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import { request as httpRequest } from 'node:http';
import type { AddressInfo } from 'node:net';
import { demoContext, demoProgram } from '../fixtures/demo-program.ts';
import type { CaseSnapshot } from '../src/types.ts';
import { createMatchingServer, MAX_REQUEST_BYTES } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';

const snapshot: CaseSnapshot = {
  schemaVersion: '1', caseId: 'http-case-alice', revision: 1,
  profile: { city: 'Demo City', county: null, healthPlan: 'Example Plan', tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null },
  findings: [], unresolvedFields: [],
};
const requestBody = { schemaVersion: '1', caseId: snapshot.caseId, expectedCaseRevision: 1 };

async function start(t: TestContext) {
  const cases = new MemoryCaseRepository([{ userId: 'alice', snapshot }]);
  const dependencies = {
    authenticate: async (token: string) => token === 'alice-token' ? { userId: 'alice' } : token === 'bob-token' ? { userId: 'bob' } : null,
    cases,
    loadRegistry: async () => [structuredClone(demoProgram)],
    now: () => new Date(demoContext.evaluatedAt),
    allowDemoPrograms: true,
  };
  const server = createMatchingServer(dependencies, dependencies);
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
    server.closeAllConnections();
  }));
  return { cases, endpoint: `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/match-case` };
}

const send = (endpoint: string, body: unknown = requestBody, token = 'alice-token') => fetch(endpoint, {
  method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
});

test('real HTTP returns and saves an owner-scoped match without cacheable personal data', async t => {
  const { endpoint, cases } = await start(t);
  const response = await send(endpoint);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  const result = await response.json();
  assert.equal(result.caseId, snapshot.caseId);
  assert.equal(result.matches[0].status, 'meets_known_criteria');
  assert.deepEqual(await cases.readSavedMatchForUser('alice', snapshot.caseId), result);
  assert.equal(await cases.readSavedMatchForUser('bob', snapshot.caseId), null);
});

test('missing and invalid bearer credentials return 401 with a challenge', async t => {
  const { endpoint } = await start(t);
  for (const response of [await fetch(endpoint, { method: 'POST' }), await send(endpoint, requestBody, 'unknown-token')]) {
    assert.equal(response.status, 401);
    assert.equal(response.headers.get('www-authenticate'), 'Bearer');
    assert.equal((await response.json()).error.code, 'UNAUTHENTICATED');
  }
});

test('another user sees the same 404 as a nonexistent case', async t => {
  const { endpoint } = await start(t);
  const denied = await send(endpoint, requestBody, 'bob-token');
  const missing = await send(endpoint, { ...requestBody, caseId: 'missing' });
  assert.equal(denied.status, 404);
  assert.equal(missing.status, 404);
  assert.deepEqual(await denied.json(), await missing.json());
});

test('revision mismatch and injected owner/profile fields cannot write results', async t => {
  const { endpoint, cases } = await start(t);
  assert.equal((await send(endpoint, { ...requestBody, expectedCaseRevision: 2 })).status, 409);
  assert.equal((await send(endpoint, { ...requestBody, ownerId: 'alice', profile: snapshot.profile })).status, 400);
  assert.equal(await cases.readSavedMatchForUser('alice', snapshot.caseId), null);
});

test('malformed JSON, media types, compression and methods are rejected', async t => {
  const { endpoint } = await start(t);
  const headers = { Authorization: 'Bearer alice-token', 'Content-Type': 'application/json' };
  assert.equal((await fetch(endpoint, { method: 'POST', headers, body: '{' })).status, 400);
  assert.equal((await fetch(endpoint, { method: 'POST', headers: { ...headers, 'Content-Type': 'text/plain' }, body: '{}' })).status, 415);
  assert.equal((await fetch(endpoint, { method: 'POST', headers: { ...headers, 'Content-Encoding': 'gzip' }, body: '{}' })).status, 415);
  const method = await fetch(endpoint);
  assert.equal(method.status, 405);
  assert.equal(method.headers.get('allow'), 'POST');
  assert.equal((await fetch(`${endpoint}?owner=alice`)).status, 404);
});

function rawRequest(endpoint: string, headers: string[], chunks: Buffer[]): Promise<{ status: number; body: any }> {
  return new Promise((resolve, reject) => {
    const request = httpRequest(endpoint, { method: 'POST', headers: ['Host', new URL(endpoint).host, ...headers] }, response => {
      const bytes: Buffer[] = [];
      response.on('data', chunk => bytes.push(chunk));
      response.on('end', () => {
        try { resolve({ status: response.statusCode!, body: JSON.parse(Buffer.concat(bytes).toString('utf8')) }); }
        catch (error) { reject(error); }
      });
      response.on('error', reject);
    });
    request.on('error', reject);
    for (const chunk of chunks) request.write(chunk);
    request.end();
  });
}

test('actual chunked byte limit returns 413 rather than trusting Content-Length', async t => {
  const { endpoint } = await start(t);
  const response = await rawRequest(endpoint, ['Authorization', 'Bearer alice-token', 'Content-Type', 'application/json', 'Transfer-Encoding', 'chunked'], [
    Buffer.from('{"padding":"'), Buffer.alloc(MAX_REQUEST_BYTES, 'x'), Buffer.from('"}'),
  ]);
  assert.equal(response.status, 413);
  assert.equal(response.body.error.code, 'PAYLOAD_TOO_LARGE');
});

test('ambiguous duplicate authorization headers and invalid UTF-8 cannot enter matching', async t => {
  const { endpoint } = await start(t);
  const duplicate = await rawRequest(endpoint, ['Authorization', 'Bearer alice-token', 'Authorization', 'Bearer bob-token', 'Content-Type', 'application/json'], [Buffer.from(JSON.stringify(requestBody))]);
  assert.equal(duplicate.status, 401);
  const invalid = await rawRequest(endpoint, ['Authorization', 'Bearer alice-token', 'Content-Type', 'application/json'], [Buffer.from([0xc3, 0x28])]);
  assert.equal(invalid.status, 400);
});

test('memory adapter copies inputs and outputs and rejects wrong revision/ownership', async () => {
  const input = structuredClone(snapshot);
  const cases = new MemoryCaseRepository([{ userId: 'alice', snapshot: input }]);
  input.profile.city = 'Changed outside repository';
  const loaded = (await cases.loadForUser('alice', snapshot.caseId))!;
  assert.equal(loaded.profile.city, 'Demo City');
  loaded.profile.city = 'Changed returned object';
  assert.equal((await cases.loadForUser('alice', snapshot.caseId))!.profile.city, 'Demo City');
  assert.equal(await cases.loadForUser('bob', snapshot.caseId), null);
  const result = { schemaVersion: '1' as const, caseId: snapshot.caseId, caseRevision: 1, ...demoContext, matches: [] };
  assert.equal(await cases.saveMatchIfCurrent('bob', snapshot.caseId, 1, result), 'not_found');
  assert.equal(await cases.saveMatchIfCurrent('alice', snapshot.caseId, 2, result), 'conflict');
  await assert.rejects(cases.saveMatchIfCurrent('alice', snapshot.caseId, 1, { ...result, caseId: 'different' }));
  assert.equal(await cases.saveMatchIfCurrent('alice', snapshot.caseId, 1, result), 'saved');
  result.caseRevision = 2;
  assert.equal((await cases.readSavedMatchForUser('alice', snapshot.caseId))!.caseRevision, 1);
});

const packetRequest = { ...requestBody, programId: demoProgram.programId, generationKey: 'http-draft-001' };

test('packet HTTP route returns an exact idempotent draft and leaves the matching endpoint available', async t => {
  const { endpoint } = await start(t);
  const packetEndpoint = endpoint.replace('/match-case', '/prepare-packet');
  const first = await send(packetEndpoint, packetRequest);
  assert.equal(first.status, 200);
  assert.equal(first.headers.get('cache-control'), 'no-store');
  const draft = await first.json();
  assert.equal(draft.status, 'draft'); assert.equal(draft.storageReference, null);
  assert.deepEqual(draft.attachments, []);
  assert.deepEqual(await (await send(packetEndpoint, packetRequest)).json(), draft);
  assert.equal((await send(endpoint)).status, 200);
});

test('packet HTTP route applies bearer parsing, owner isolation and strict request validation', async t => {
  const { endpoint } = await start(t);
  const packetEndpoint = endpoint.replace('/match-case', '/prepare-packet');
  const unsigned = await fetch(packetEndpoint, { method: 'POST' });
  assert.equal(unsigned.status, 401); assert.equal(unsigned.headers.get('www-authenticate'), 'Bearer');
  assert.equal((await send(packetEndpoint, packetRequest, 'bob-token')).status, 404);
  assert.equal((await send(packetEndpoint, { ...packetRequest, programId: 'missing' })).status, 404);
  assert.equal((await send(packetEndpoint, { ...packetRequest, ownerId: 'alice' })).status, 400);
  assert.equal((await send(packetEndpoint, { ...packetRequest, generationKey: 'valid-key\n' })).status, 400);
  const duplicate = await rawRequest(packetEndpoint, ['Authorization', 'Bearer alice-token', 'Authorization', 'Bearer bob-token', 'Content-Type', 'application/json'], [Buffer.from(JSON.stringify(packetRequest))]);
  assert.equal(duplicate.status, 401);
});

test('packet HTTP route reuses body byte limits, UTF-8 parsing, media types and method restrictions', async t => {
  const { endpoint } = await start(t);
  const packetEndpoint = endpoint.replace('/match-case', '/prepare-packet');
  const headers = { Authorization: 'Bearer alice-token', 'Content-Type': 'application/json' };
  assert.equal((await fetch(packetEndpoint, { method: 'POST', headers, body: '{' })).status, 400);
  assert.equal((await fetch(packetEndpoint, { method: 'POST', headers: { ...headers, 'Content-Type': 'text/plain' }, body: '{}' })).status, 415);
  assert.equal((await fetch(packetEndpoint)).status, 405);
  const oversized = await rawRequest(packetEndpoint, ['Authorization', 'Bearer alice-token', 'Content-Type', 'application/json', 'Transfer-Encoding', 'chunked'], [Buffer.alloc(MAX_REQUEST_BYTES + 1, 'x')]);
  assert.equal(oversized.status, 413);
  const invalid = await rawRequest(packetEndpoint, ['Authorization', 'Bearer alice-token', 'Content-Type', 'application/json'], [Buffer.from([0xc3, 0x28])]);
  assert.equal(invalid.status, 400);
});
