import assert from 'node:assert/strict';
import type { Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { after, before, test } from 'node:test';
import type { Pool } from 'pg';
import { createDurableServer } from '../../src/api/durable-server.ts';
import { PostgresLifecycleMaintenance } from '../../src/storage/lifecycle-maintenance.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import type { CaseSnapshot } from '../../src/types.ts';
import { draft } from './fixtures.ts';
import { TestPostgres } from './harness.ts';

const ALICE = 'a0000000-0000-4000-8000-000000000001';
const BOB = 'b0000000-0000-4000-8000-000000000002';
const projectUrl = 'https://fictional-lifecycle-auth.example';
const publishableKey = 'sb_publishable_fictional_lifecycle_test';
let cluster: TestPostgres;
let admin: Pool;
let server: Server | undefined;
let base = '';
let providerCalls = 0;
const acceptedTokens = new Map<string, string>();
const removedUsers = new Set<string>();

function credential(userId: string, authenticationAge: number): string {
  const now = Math.floor(Date.now() / 1000);
  const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const token = `${encode({ alg: 'HS256', typ: 'JWT' })}.${encode({
    sub: userId, iss: `${projectUrl}/auth/v1`, aud: 'authenticated', role: 'authenticated',
    iat: now, exp: now + 3600, amr: [{ method: 'password', timestamp: now - authenticationAge }],
  })}.fictionalSignature`;
  acceptedTokens.set(token, userId);
  return token;
}

const providerFetch: typeof fetch = async (input, options) => {
  providerCalls++;
  assert.equal(input, `${projectUrl}/auth/v1/user`);
  assert.equal(options?.method, 'GET');
  assert.equal(options?.redirect, 'error');
  const headers = new Headers(options?.headers);
  assert.equal(headers.get('apikey'), publishableKey);
  const token = headers.get('authorization')?.replace(/^Bearer /, '') ?? '';
  const userId = acceptedTokens.get(token);
  if (!userId || removedUsers.has(userId)) {
    return Response.json({ code: 'user_not_found', message: 'Fictional provider denial.' }, { status: 403 });
  }
  return Response.json({ id: userId, role: 'authenticated' });
};

async function openServer() {
  const pool = cluster.pool('sah_lifecycle_runtime', 'safeathome-durable-lifecycle');
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
  const current = server;
  server = undefined;
  if (!current?.listening) return;
  await new Promise<void>((resolve, reject) => {
    current.close(error => error ? reject(error) : resolve());
    current.closeAllConnections();
  });
}

before(async () => {
  cluster = await TestPostgres.start();
  admin = cluster.pool();
  await applyMigrations(admin);
  await admin.query('CREATE ROLE sah_lifecycle_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  await openServer();
});
after(async () => { await closeServer(); await cluster?.close(); });

async function json<T>(path: string, body: unknown, token: string, expectedStatus = 200): Promise<T> {
  const response = await fetch(`${base}/v1/${path}`, { method: 'POST', redirect: 'error',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify(body), signal: AbortSignal.timeout(10000) });
  assert.equal(response.status, expectedStatus);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  return await response.json() as T;
}
async function failure(path: string, body: unknown, token: string, status: number, code: string) {
  const result = await json<{ schemaVersion: string; error: { code: string; message: string } }>(path, body, token, status);
  assert.equal(result.schemaVersion, '1');
  assert.equal(result.error.code, code);
  assert.deepEqual(Object.keys(result).sort(), ['error', 'schemaVersion']);
  assert.equal(JSON.stringify(result).includes(token), false);
}

test('durable HTTP closes the application before provider removal and retains receipt-only recovery after restart', async () => {
  const alice = credential(ALICE, 5);
  const oldAlice = credential(ALICE, 3600);
  const bob = credential(BOB, 5);
  const aliceDraft = draft();
  const aliceCase = await json<CaseSnapshot>('create-case', aliceDraft, alice);
  const bobCase = await json<CaseSnapshot>('create-case', draft(), bob);
  const readAlice = { schemaVersion: '1', caseId: aliceCase.caseId };
  const readBob = { schemaVersion: '1', caseId: bobCase.caseId };

  assert.deepEqual(await json('read-case', readAlice, oldAlice), aliceCase);
  await failure('prepare-account-deletion', { schemaVersion: '1' }, oldAlice, 403, 'RECENT_AUTHENTICATION_REQUIRED');
  assert.equal((await admin.query('SELECT count(*) AS count FROM safeathome_private.account_deletion_previews')).rows[0].count, '0');
  const preview = await json<{ schemaVersion: string; deletionToken: string; counts: { cases: number } }>(
    'prepare-account-deletion', { schemaVersion: '1' }, alice);
  assert.match(preview.deletionToken, /^[0-9a-f]{64}$/);
  assert.equal(preview.counts.cases, 1);
  const confirmation = { schemaVersion: '1', deletionToken: preview.deletionToken, confirmation: 'DELETE_ACCOUNT' };
  await failure('confirm-account-deletion', confirmation, oldAlice, 403, 'RECENT_AUTHENTICATION_REQUIRED');
  await failure('confirm-account-deletion', confirmation, bob, 404, 'DELETION_NOT_FOUND');
  assert.deepEqual(await json('read-case', readAlice, alice), aliceCase);

  const pending = { schemaVersion: '1', status: 'auth_pending', applicationDataDeleted: true, providerIdentityDeleted: false };
  assert.deepEqual(await json('confirm-account-deletion', confirmation, alice, 202), pending);
  assert.equal(removedUsers.has(ALICE), false);
  const callsBeforeDeniedRequests = providerCalls;
  await failure('read-case', readAlice, alice, 401, 'UNAUTHENTICATED');
  await failure('save-case', { ...aliceDraft, expectedCaseRevision: 1 }, alice, 401, 'UNAUTHENTICATED');
  await failure('create-case', draft(), alice, 401, 'UNAUTHENTICATED');
  assert.equal(providerCalls, callsBeforeDeniedRequests + 3);
  assert.deepEqual(await json('read-case', readBob, bob), bobCase);
  assert.deepEqual(await json('confirm-account-deletion', confirmation, alice, 202), pending);

  removedUsers.add(ALICE);
  await failure('confirm-account-deletion', confirmation, alice, 401, 'UNAUTHENTICATED');
  const callsBeforeReceipt = providerCalls;
  assert.deepEqual(await json('account-deletion-status', { schemaVersion: '1' }, preview.deletionToken), pending);
  assert.equal(providerCalls, callsBeforeReceipt);
  await failure('read-case', readAlice, preview.deletionToken, 401, 'UNAUTHENTICATED');

  const maintenance = new PostgresLifecycleMaintenance(admin);
  const jobs = await maintenance.claimAuthDeletionJobs(1);
  assert.equal(jobs.length, 1);
  assert.equal(jobs[0].userId, ALICE);
  assert.equal(await maintenance.finishAuthDeletionJob({ jobId: jobs[0].jobId,
    leaseToken: jobs[0].leaseToken, outcome: 'deleted' }), true);
  await closeServer();
  await cluster.restart();
  admin = cluster.pool();
  await openServer();
  const callsBeforeRecoveredReceipt = providerCalls;
  assert.deepEqual(await json('account-deletion-status', { schemaVersion: '1' }, preview.deletionToken), {
    schemaVersion: '1', status: 'complete', applicationDataDeleted: true, providerIdentityDeleted: true,
  });
  assert.equal(providerCalls, callsBeforeRecoveredReceipt);
  assert.deepEqual(await json('read-case', readBob, bob), bobCase);
  assert.equal((await admin.query('SELECT count(*) AS count FROM safeathome_private.cases WHERE owner_id=$1', [ALICE])).rows[0].count, '0');
});
