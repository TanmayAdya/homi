import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import type { AddressInfo } from 'node:net';
import test, { type TestContext } from 'node:test';
import sharp from 'sharp';
import { createDemoEvidenceImage } from '../fixtures/demo-evidence.ts';
import { demoContext, demoProgram } from '../fixtures/demo-program.ts';
import { createMatchingServer, MAX_REQUEST_BYTES, MAX_UPLOAD_REQUEST_BYTES } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';

const draft = () => ({ schemaVersion: '1' as const, caseId: randomUUID(),
  profile: { city: null, county: null, healthPlan: null, tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null },
  unresolvedFields: [], findings: [{ id: 'finding-1', room: 'entrance' as const, observation: 'Fictional raised threshold',
    reviewState: 'needs_review' as const, evidenceIds: ['photo-1'], measurements: [] }] });

async function start(t: TestContext, authenticate?: (token: string) => Promise<{ userId: string } | null>) {
  const cases = new MemoryCaseRepository([]);
  const dependencies = { cases, now: () => new Date(demoContext.evaluatedAt),
    loadRegistry: async () => [structuredClone(demoProgram)], allowDemoPrograms: true,
    authenticate: authenticate ?? (async (token: string) => token === 'alice' || token === 'bob' ? { userId: token } : null) };
  const server = createMatchingServer(dependencies, undefined, undefined, undefined, dependencies, dependencies);
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
    server.closeAllConnections();
  }));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/`;
  const send = (route: string, body: unknown, token = 'alice') => fetch(base + route, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  return { cases, base, send, server };
}

function upload(caseId: string, bytes: Uint8Array) {
  return { schemaVersion: '1', caseId, expectedCaseRevision: 1, expectedCatalogRevision: 0,
    evidenceId: 'photo-1', expectedEvidenceRevision: 0, findingId: 'finding-1', capturedAt: null,
    imageBase64: Buffer.from(bytes).toString('base64') };
}

test('real HTTP creates, saves and reloads owned cases; stale writes and owner spoofing fail', async t => {
  const { send } = await start(t);
  const proposed = draft();
  const created = await send('create-case', proposed);
  assert.equal(created.status, 200);
  assert.equal(created.headers.get('cache-control'), 'no-store');
  assert.equal(created.headers.get('x-content-type-options'), 'nosniff');
  assert.deepEqual(await created.json(), { ...proposed, revision: 1 });
  assert.equal((await send('create-case', proposed)).status, 409);
  const replacement = { ...proposed, expectedCaseRevision: 1, profile: { ...proposed.profile, city: 'Fictional City' } };
  assert.equal((await send('save-case', replacement, 'bob')).status, 404);
  assert.equal((await send('save-case', { ...replacement, userId: 'alice' })).status, 400);
  assert.equal((await send('save-case', replacement)).status, 200);
  assert.equal((await send('save-case', replacement)).status, 409);
  const read = await send('read-case', { schemaVersion: '1', caseId: proposed.caseId });
  const saved = await read.json();
  assert.equal(saved.revision, 2); assert.equal(saved.profile.city, 'Fictional City');
  assert.equal(saved.profile.annualIncomeUsd, null);
});

test('photo JSON above normal body limit is sanitized, private, revisioned and explicitly deleted', async t => {
  const { send, cases } = await start(t);
  const proposed = draft();
  assert.equal((await send('create-case', proposed)).status, 200);
  const png = await sharp(randomBytes(128 * 128 * 3), { raw: { width: 128, height: 128, channels: 3 } })
    .png().withMetadata({ exif: { IFD0: { ImageDescription: 'FICTIONAL PRIVATE METADATA' } } }).toBuffer();
  const body = upload(proposed.caseId, png);
  assert.ok(Buffer.byteLength(JSON.stringify(body)) > MAX_REQUEST_BYTES);
  assert.equal((await send('upload-evidence', body, 'bob')).status, 404);
  const response = await send('upload-evidence', body);
  assert.equal(response.status, 200);
  const saved = await response.json();
  assert.equal(saved.catalogRevision, 1); assert.equal(saved.evidence.evidenceRevision, 1);
  assert.equal(saved.caseRevision, 1); assert.equal(saved.evidence.mediaType, 'image/png');
  assert.equal(Object.hasOwn(saved, 'bytes'), false);
  const read = await cases.readEvidenceForUser({ userId: 'alice', caseId: proposed.caseId, revision: 1,
    expectedCatalogRevision: 1, evidenceId: 'photo-1', expectedEvidenceRevision: 1 });
  assert.equal(read.status, 'found');
  if (read.status === 'found') assert.equal(Buffer.from(read.asset.bytes).includes(Buffer.from('FICTIONAL PRIVATE METADATA')), false);
  assert.equal((await send('upload-evidence', body)).status, 409);
  assert.equal((await send('save-case', { ...proposed, findings: [], expectedCaseRevision: 1 })).status, 409);
  const remove = { schemaVersion: '1', caseId: proposed.caseId, expectedCaseRevision: 1,
    expectedCatalogRevision: 1, evidenceId: 'photo-1', expectedEvidenceRevision: 1 };
  assert.equal((await send('delete-evidence', remove, 'bob')).status, 404);
  const deletion = await send('delete-evidence', remove);
  assert.equal(deletion.status, 200);
  assert.deepEqual(await deletion.json(), { schemaVersion: '1', caseId: proposed.caseId, caseRevision: 1,
    catalogRevision: 2, evidenceId: 'photo-1', evidenceRevision: 2, deleted: true });
  assert.equal((await send('upload-evidence', { ...body, expectedCatalogRevision: 2, expectedEvidenceRevision: 2 })).status, 409);
  assert.equal((await send('save-case', { ...proposed, findings: [], expectedCaseRevision: 1 })).status, 200);
});

test('upload authenticates before waiting for a large request body', async t => {
  const { base } = await start(t);
  const status = await new Promise<number>((resolve, reject) => {
    const request = httpRequest(base + 'upload-evidence', { method: 'POST', headers: {
      Authorization: 'Bearer invalid', 'Content-Type': 'application/json', 'Content-Length': MAX_UPLOAD_REQUEST_BYTES,
    } }, response => { response.resume(); resolve(response.statusCode!); request.destroy(); });
    request.on('error', reject);
    request.flushHeaders();
  });
  assert.equal(status, 401);
});

test('one upload admission covers slow request buffering; other case reads remain available', async t => {
  let announce: () => void = () => {};
  const admitted = new Promise<void>(resolve => { announce = resolve; });
  const { base, send } = await start(t, async token => { if (token === 'uploading') announce(); return { userId: 'alice' }; });
  const proposed = draft();
  await send('create-case', proposed);
  const bytes = Buffer.from(JSON.stringify(upload(proposed.caseId, (await createDemoEvidenceImage()).bytes)));
  let finish: () => void = () => {};
  const pending = new Promise<number>((resolve, reject) => {
    const request = httpRequest(base + 'upload-evidence', { method: 'POST', headers: {
      Authorization: 'Bearer uploading', 'Content-Type': 'application/json', 'Content-Length': bytes.length,
    } }, response => { response.resume(); response.on('end', () => resolve(response.statusCode!)); });
    request.on('error', reject);
    request.flushHeaders();
    finish = () => request.end(bytes);
  });
  await admitted;
  const busy = await send('upload-evidence', {});
  assert.equal(busy.status, 429); assert.equal((await busy.json()).error.code, 'UPLOAD_BUSY');
  assert.equal((await send('read-case', { schemaVersion: '1', caseId: proposed.caseId })).status, 200);
  finish(); assert.equal(await pending, 200);
  assert.equal((await send('upload-evidence', {})).status, 400);
});

test('revoked upload session fails the second auth check after the body arrives', async t => {
  let calls = 0;
  const { send, cases } = await start(t, async token => token === 'revoked'
    ? (++calls === 1 ? { userId: 'alice' } : null) : { userId: 'alice' });
  const proposed = draft();
  await send('create-case', proposed);
  const response = await send('upload-evidence', upload(proposed.caseId, (await createDemoEvidenceImage()).bytes), 'revoked');
  assert.equal(response.status, 401);
  const catalog = await cases.readEvidenceCatalogForUser('alice', proposed.caseId);
  assert.equal(catalog.status, 'found');
  if (catalog.status === 'found') assert.equal(catalog.catalog.catalogRevision, 0);
});

test('abandoned pre-body authentication releases upload admission without awaiting the provider', async t => {
  let announce: () => void = () => {};
  const authenticating = new Promise<void>(resolve => { announce = resolve; });
  let resume: (value: { userId: string }) => void = () => {};
  const blocked = new Promise<{ userId: string }>(resolve => { resume = resolve; });
  const { base, send, server } = await start(t, async token => {
    if (token === 'stalled') { announce(); return blocked; }
    return { userId: 'alice' };
  });
  const abandoned = new Promise<void>(resolve => server.on('request', (incoming, response) => {
    if (incoming.headers.authorization === 'Bearer stalled') response.once('close', () => setImmediate(resolve));
  }));
  const request = httpRequest(base + 'upload-evidence', { method: 'POST', headers: {
    Authorization: 'Bearer stalled', 'Content-Type': 'application/json', 'Content-Length': 2,
  } });
  request.on('error', () => {});
  request.flushHeaders();
  await authenticating;
  const closed = new Promise<void>(resolve => request.once('close', resolve));
  request.destroy(); await closed; await abandoned;
  const response = await send('upload-evidence', {});
  assert.equal(response.status, 400);
  resume({ userId: 'alice' });
  assert.equal((await send('upload-evidence', {})).status, 400);
});

test('upload and case bodies keep distinct actual streaming limits; compression is refused', async t => {
  const { base, send } = await start(t);
  const streamStatus = (route: string, size: number) => new Promise<number>((resolve, reject) => {
    const request = httpRequest(base + route, { method: 'POST', headers: {
      Authorization: 'Bearer alice', 'Content-Type': 'application/json', 'Transfer-Encoding': 'chunked',
    } }, response => { response.resume(); response.on('end', () => resolve(response.statusCode!)); });
    request.on('error', reject);
    request.end(Buffer.alloc(size, 'x'));
  });
  assert.equal(await streamStatus('upload-evidence', MAX_UPLOAD_REQUEST_BYTES + 1), 413);
  assert.equal(await streamStatus('save-case', MAX_REQUEST_BYTES + 1), 413);
  assert.equal((await send('upload-evidence', {})).status, 400);
  assert.equal((await fetch(base + 'upload-evidence', { method: 'POST', headers: {
    Authorization: 'Bearer alice', 'Content-Type': 'application/json', 'Content-Encoding': 'gzip',
  }, body: '{}' })).status, 415);
});

test('disconnect during post-body authentication releases both upload guards and prevents a late write', async t => {
  let announce: () => void = () => {};
  const authenticating = new Promise<void>(resolve => { announce = resolve; });
  let resume: (value: { userId: string }) => void = () => {};
  const blocked = new Promise<{ userId: string }>(resolve => { resume = resolve; });
  let calls = 0;
  const { base, send, cases, server } = await start(t, async token => {
    if (token === 'stalled' && ++calls === 2) { announce(); return blocked; }
    return { userId: 'alice' };
  });
  const proposed = draft();
  await send('create-case', proposed);
  const abandoned = new Promise<void>(resolve => server.on('request', (incoming, response) => {
    if (incoming.headers.authorization === 'Bearer stalled') response.once('close', () => setImmediate(resolve));
  }));
  const bytes = Buffer.from(JSON.stringify(upload(proposed.caseId, (await createDemoEvidenceImage()).bytes)));
  const request = httpRequest(base + 'upload-evidence', { method: 'POST', headers: {
    Authorization: 'Bearer stalled', 'Content-Type': 'application/json', 'Content-Length': bytes.length,
  } });
  request.on('error', () => {});
  request.end(bytes);
  await authenticating;
  const closed = new Promise<void>(resolve => request.once('close', resolve));
  request.destroy(); await closed; await abandoned;
  assert.equal((await send('upload-evidence', {})).status, 400);
  resume({ userId: 'alice' });
  const response = await send('read-case', { schemaVersion: '1', caseId: proposed.caseId });
  assert.equal(response.status, 200);
  const catalog = await cases.readEvidenceCatalogForUser('alice', proposed.caseId);
  assert.equal(catalog.status, 'found');
  if (catalog.status === 'found') assert.deepEqual(catalog.catalog.evidence, []);
});
