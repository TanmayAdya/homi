import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import test, { type TestContext } from 'node:test';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import type { AuthenticatedUser } from '../src/api/match-case.ts';
import type { SharingRepository } from '../src/sharing/contracts.ts';

const owner = '33333333-3333-4333-8333-333333333333';
const caseId = '44444444-4444-4444-8444-444444444444';
const invitationId = '55555555-5555-4555-8555-555555555555';
const email = 'helper@fictional.example';

async function start(t: TestContext, user: unknown, simpleInvitationsEnabled = true) {
  let authentications = 0;
  const calls: { route: string; email: string | undefined }[] = [];
  const authenticate = async () => { authentications++; return user as AuthenticatedUser | null; };
  const sharing: SharingRepository = {
    execute: async (userId, route, _request, _hash, verifiedEmail) => {
      assert.equal(userId, owner); calls.push({ route, email: verifiedEmail });
      return { status: 'ok', data: { created: true } };
    },
    sensitive: async (userId, route) => {
      assert.equal(userId, owner); calls.push({ route, email: undefined });
      return { status: 'ok', data: { schemaVersion: '3' } };
    },
  };
  const deps = { authenticate, cases: new MemoryCaseRepository([]), loadRegistry: async () => [], now: () => new Date() };
  const server = createMatchingServer(deps, undefined, undefined, undefined, undefined, undefined, {
    hosted: true, sharingDependencies: { authenticate, sharing, simpleInvitationsEnabled, sensitiveEnabled: true },
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve()); server.closeAllConnections();
  }));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const send = (route: string, body: unknown) => fetch(base + route, {
    method: 'POST', headers: { Authorization: 'Bearer fictional', 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  return { send, calls, authentications: () => authentications };
}

test('hosted admission preserves the provider-verified mailbox through invitation and sharing routes', async t => {
  const { send, calls, authentications } = await start(t, { userId: owner, verifiedEmail: email });
  const requests: [string, Record<string, unknown>][] = [
    ['create-email-invitation', { caseId, expectedCaseRevision: 1, invitationId, recipientEmail: 'other@fictional.example',
      role: 'helper', scope: { findingIds: [], programIds: [], allowHelperNotes: false }, expiresAt: '2099-01-01T00:00:00.000Z' }],
    ['list-email-sharing', { caseId }],
    ['review-invitation', { code: 'a'.repeat(43) }],
    ['accept-invitation', { code: 'a'.repeat(43), expectedPermissionRevision: 1 }],
    ['read-shared-case', { membershipId: invitationId, expectedPermissionRevision: 2 }],
    ['list-sharing', { caseId }],
    ['read-sensitive-sharing', { membershipId: invitationId, expectedPermissionRevision: 2 }],
  ];
  for (const [route, body] of requests) {
    const response = await send('/v3/' + route, { schemaVersion: '3', ...body });
    assert.equal(response.status, 200, route + ': ' + await response.text());
    assert.equal(response.headers.get('cache-control'), 'no-store');
  }
  assert.equal(authentications(), requests.length, 'one fresh provider lookup per request, including the nested sensitive handler');
  assert.deepEqual(calls, requests.map(([route]) => ({ route, email: route === 'read-sensitive-sharing' ? undefined : email })));
});

test('hosted admission does not accept a request-supplied mailbox or drop the self-invitation check', async t => {
  const { send, calls } = await start(t, { userId: owner, verifiedEmail: email });
  const invite = { schemaVersion: '3', caseId, expectedCaseRevision: 1, invitationId, recipientEmail: email,
    role: 'helper', scope: { findingIds: [], programIds: [], allowHelperNotes: false }, expiresAt: null };
  assert.equal((await send('/v3/create-email-invitation', invite)).status, 400);
  assert.equal((await send('/v3/review-invitation', { schemaVersion: '3', code: 'a'.repeat(43), verifiedEmail: email })).status, 400);
  assert.equal(calls.length, 0);
});

test('hosted admission retains strict shapes and keeps email-specific authority confined to sharing', async t => {
  for (const user of [
    { userId: owner, verifiedEmail: ' Helper@Fictional.Example ' },
    { userId: owner, verifiedEmail: 'bad\nmail@example.test' },
    { userId: owner, verifiedEmail: undefined },
    { userId: owner, verifiedEmail: null },
    { userId: owner, verifiedEmail: email, arbitrary: true },
  ]) {
    const { send, calls } = await start(t, user);
    assert.equal((await send('/v3/list-email-sharing', { schemaVersion: '3', caseId })).status, 500);
    assert.equal(calls.length, 0);
  }
  const withEmail = await start(t, { userId: owner, verifiedEmail: email });
  assert.equal((await withEmail.send('/v1/read-case', { schemaVersion: '1', caseId })).status, 500);
  const legacy = await start(t, { userId: owner });
  assert.equal((await legacy.send('/v3/list-sharing', { schemaVersion: '3', caseId })).status, 200);
  assert.deepEqual(legacy.calls, [{ route: 'list-sharing', email: undefined }]);
  const disabled = await start(t, { userId: owner, verifiedEmail: email }, false);
  assert.equal((await disabled.send('/v3/list-email-sharing', { schemaVersion: '3', caseId })).status, 404);
  assert.equal((await disabled.send('/v3/review-invitation', { schemaVersion: '3', code: 'a'.repeat(43) })).status, 200);
  assert.deepEqual(disabled.calls, [{ route: 'review-invitation', email: undefined }], 'disabled email redemption retains only legacy account-ID authority');
});
