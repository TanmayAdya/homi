import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import type { Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { after, before, test } from 'node:test';
import type { Pool } from 'pg';
import { createDurableServer } from '../../src/api/durable-server.ts';
import type { UploadEvidenceResponse, DeleteEvidenceResponse } from '../../src/api/write-evidence.ts';
import type { EvidenceCatalog } from '../../src/evidence/types.ts';
import type { CaseSnapshot } from '../../src/types.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { TestPostgres } from './harness.ts';
import { draft, image } from './fixtures.ts';

const ALICE = 'a0000000-0000-4000-8000-000000000001';
const BOB = 'b0000000-0000-4000-8000-000000000002';
const projectUrl = 'https://fictional-auth.example';
const publishableKey = 'sb_publishable_fictional_database_test';
let cluster: TestPostgres;
let admin: Pool;
let server: Server | undefined;
let base = '';
let unavailable = false;
let providerCalls = 0;

const providerFetch: typeof fetch = async (input, options) => {
  providerCalls++;
  assert.equal(input, `${projectUrl}/auth/v1/user`);
  assert.equal(options?.method, 'GET'); assert.equal(options?.redirect, 'error');
  const headers = new Headers(options?.headers);
  assert.equal(headers.get('apikey'), publishableKey);
  if (unavailable) throw new Error('Fictional provider details must not escape');
  const bearer = headers.get('authorization');
  if (bearer !== 'Bearer alice-token' && bearer !== 'Bearer bob-token') {
    return Response.json({ message: 'Fictional rejected provider credential' }, { status: 401 });
  }
  return Response.json({ id: bearer === 'Bearer alice-token' ? ALICE : BOB,
    role: 'authenticated', user_metadata: { ownerId: 'ignored-forged-owner' } });
};

async function openServer() {
  const pool = cluster.pool('sah_http_runtime', 'safeathome-http-integration');
  const created = await createDurableServer({ pool, auth: { projectUrl, publishableKey }, fetchImpl: providerFetch });
  server = created.server;
  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error) => reject(error);
    server!.once('error', onError);
    server!.listen(0, '127.0.0.1', () => { server!.off('error', onError); resolve(); });
  });
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}
async function closeServer() {
  const current = server; server = undefined;
  if (!current?.listening) return;
  await new Promise<void>((resolve, reject) => {
    current.close(error => error ? reject(error) : resolve());
    current.closeAllConnections();
  });
}
before(async () => {
  cluster = await TestPostgres.start(); admin = cluster.pool();
  await applyMigrations(admin);
  await admin.query('CREATE ROLE sah_http_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  await openServer();
});
after(async () => { await closeServer(); await cluster?.close(); });

async function send(path: string, body: unknown, token = 'alice-token') {
  return fetch(`${base}/v1/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify(body), redirect: 'error', signal: AbortSignal.timeout(10000) });
}
async function json<T>(path: string, body: unknown, token = 'alice-token', status = 200): Promise<T> {
  const response = await send(path, body, token);
  assert.equal(response.status, status);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  return await response.json() as T;
}
async function failure(path: string, body: unknown, status: number, code: string, token = 'alice-token') {
  const result = await json<{ schemaVersion: string; error: { code: string; message: string } }>(path, body, token, status);
  assert.equal(result.schemaVersion, '1'); assert.equal(result.error.code, code);
  assert.ok(!JSON.stringify(result).includes('Fictional provider details'));
  assert.deepEqual(Object.keys(result).sort(), ['error', 'schemaVersion']);
}

test('durable HTTP factory authenticates with provider and never seeds or trusts caller owners', async () => {
  assert.equal((await admin.query('SELECT count(*)::integer AS count FROM safeathome_private.cases')).rows[0].count, 0);
  const input = draft();
  await failure('create-case', input, 401, 'UNAUTHENTICATED', 'invalid-token');
  unavailable = true;
  try { await failure('create-case', input, 503, 'SERVICE_UNAVAILABLE'); }
  finally { unavailable = false; }
  await failure('create-case', { ...input, ownerId: BOB }, 400, 'INVALID_REQUEST');
  assert.equal((await admin.query('SELECT count(*)::integer AS count FROM safeathome_private.cases')).rows[0].count, 0);
  assert.ok(providerCalls >= 3);
  await assert.rejects(createDurableServer({ pool: admin, auth: { projectUrl, publishableKey }, fetchImpl: providerFetch }));
});

test('HTTP case/photo writes and ownership survive a complete API and PostgreSQL restart', async () => {
  const input = draft();
  const created = await json<CaseSnapshot>('create-case', input);
  assert.deepEqual(created, { ...input, revision: 1 });
  assert.equal((await admin.query('SELECT owner_id FROM safeathome_private.cases WHERE case_id=$1', [input.caseId])).rows[0].owner_id, ALICE);
  await failure('read-case', { schemaVersion: '1', caseId: input.caseId }, 404, 'CASE_NOT_FOUND', 'bob-token');
  await failure('create-case', input, 409, 'CASE_ID_UNAVAILABLE', 'bob-token');
  const baseRequest = { schemaVersion: '1', caseId: input.caseId, expectedCaseRevision: 1 };
  const uploadRequest = { ...baseRequest, expectedCatalogRevision: 0, evidenceId: 'fictional-photo-a',
    expectedEvidenceRevision: 0, findingId: 'fictional-finding', capturedAt: null,
    imageBase64: Buffer.from((await image).bytes).toString('base64') };
  const uploaded = await json<UploadEvidenceResponse>('upload-evidence', uploadRequest);
  assert.equal(uploaded.caseRevision, 1); assert.equal(uploaded.catalogRevision, 1);
  assert.equal(uploaded.evidence.evidenceRevision, 1);
  const listed = await json<EvidenceCatalog>('list-evidence', baseRequest);
  assert.deepEqual(listed.evidence, [uploaded.evidence]);
  assert.equal('bytes' in listed.evidence[0], false);
  const downloadRequest = { ...baseRequest, expectedCatalogRevision: 1, evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 };
  const preview = await send('download-evidence', downloadRequest);
  assert.equal(preview.status, 200); assert.equal(preview.headers.get('content-type'), 'image/png');
  assert.equal(preview.headers.get('cache-control'), 'no-store');
  const beforeBytes = new Uint8Array(await preview.arrayBuffer());
  assert.equal(beforeBytes.length, uploaded.evidence.byteLength);
  assert.equal(createHash('sha256').update(beforeBytes).digest('hex'), uploaded.evidence.sha256);
  await failure('download-evidence', downloadRequest, 404, 'ARTIFACT_NOT_FOUND', 'bob-token');
  const replacement = structuredClone(input); replacement.profile.city = 'Fictional durable edit';
  const changed = await json<CaseSnapshot>('save-case', { ...replacement, expectedCaseRevision: 1 });
  assert.deepEqual(changed, { ...replacement, revision: 2 });
  await failure('save-case', { ...replacement, expectedCaseRevision: 1 }, 409, 'CASE_REVISION_MISMATCH');
  await closeServer();
  await cluster.restart(); admin = cluster.pool();
  await openServer();
  assert.deepEqual(await json<CaseSnapshot>('read-case', { schemaVersion: '1', caseId: input.caseId }), changed);
  const currentRequest = { ...baseRequest, expectedCaseRevision: 2 };
  const currentCatalog = await json<EvidenceCatalog>('list-evidence', currentRequest);
  assert.equal(currentCatalog.catalogRevision, 1); assert.equal(currentCatalog.caseRevision, 2);
  assert.deepEqual(currentCatalog.evidence, [uploaded.evidence]);
  const recovered = await send('download-evidence', { ...downloadRequest, expectedCaseRevision: 2 });
  assert.equal(recovered.status, 200);
  assert.deepEqual(new Uint8Array(await recovered.arrayBuffer()), beforeBytes);
  await failure('read-case', { schemaVersion: '1', caseId: input.caseId }, 404, 'CASE_NOT_FOUND', 'bob-token');
  const removed = await json<DeleteEvidenceResponse>('delete-evidence', { ...downloadRequest, expectedCaseRevision: 2 });
  assert.deepEqual(removed, { schemaVersion: '1', caseId: input.caseId, caseRevision: 2,
    catalogRevision: 2, evidenceId: 'fictional-photo-a', evidenceRevision: 2, deleted: true });
  assert.deepEqual((await json<EvidenceCatalog>('list-evidence', currentRequest)).evidence, []);
  await failure('upload-evidence', { ...uploadRequest, expectedCaseRevision: 2, expectedCatalogRevision: 2 }, 409, 'EVIDENCE_CONFLICT');
  assert.equal((await json<CaseSnapshot>('read-case', { schemaVersion: '1', caseId: input.caseId })).revision, 2);
  const matched = await json<{ matches: unknown[] }>('match-case', currentRequest);
  assert.deepEqual(matched.matches, []);
  assert.ok(providerCalls >= 15);
});
