import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { handleDeleteCase, handlePrepareAccountDeletion, handleConfirmAccountDeletion, handleAccountDeletionStatus,
  type LifecycleDependencies, type LifecycleResponse } from '../src/api/lifecycle.ts';
import { AccountClosedError, RecentAuthenticationRequiredError, type LifecycleRepository,
  type AccountDeletionState, type DeleteCaseResult } from '../src/lifecycle/types.ts';

const token = 'a'.repeat(64);
const tokenHash = createHash('sha256').update(token).digest('hex');
const pending: AccountDeletionState = { status: 'auth_pending', applicationDataDeleted: true, providerIdentityDeleted: false };
const complete: AccountDeletionState = { status: 'complete', applicationDataDeleted: true, providerIdentityDeleted: true };
const awaiting: AccountDeletionState = { status: 'awaiting_confirmation', applicationDataDeleted: false, providerIdentityDeleted: false };
const caseRequest = () => ({ schemaVersion: '1', caseId: 'fictional-case', expectedCaseRevision: 2,
  expectedCatalogRevision: 3, confirmation: 'DELETE_CASE' });
const confirmRequest = () => ({ schemaVersion: '1', deletionToken: token, confirmation: 'DELETE_ACCOUNT' });
const input = (body: unknown, bearerToken: string | null = 'alice-session') => ({ body, bearerToken });

function repository(overrides: Partial<LifecycleRepository> = {}): LifecycleRepository {
  return {
    isAccountClosed: async () => false,
    deleteCaseIfCurrent: async () => ({ status: 'deleted' }),
    prepareAccountDeletion: async () => ({ status: 'ready', expiresAt: '2026-10-17T20:05:00.000Z',
      counts: { cases: 2, evidence: 3, exports: 1, storedBytes: 1234 } }),
    confirmAccountDeletion: async () => ({ status: 'confirmed', deletion: pending }),
    readAccountDeletionReceipt: async () => complete,
    ...overrides,
  };
}
function dependencies(overrides: Partial<LifecycleDependencies> = {}): LifecycleDependencies {
  return { authenticate: async credential => credential === 'alice-session' ? { userId: 'alice' } : null,
    authenticateForDeletion: async credential => credential === 'alice-session' ? { userId: 'alice' } : null,
    lifecycle: repository(), ...overrides };
}
function code(response: LifecycleResponse): string {
  assert.ok('error' in response.body);
  assert.equal(response.headers['Cache-Control'], 'no-store');
  return response.body.error.code;
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(yes => { resolve = yes; });
  return { promise, resolve };
}

test('missing or malformed credentials cannot reach authentication or private storage', async () => {
  const deps = dependencies({ authenticate: async () => { throw new Error('Should not authenticate'); },
    authenticateForDeletion: async () => { throw new Error('Should not authenticate'); } });
  for (const credential of [null, '', 'token\n', 'bad token', 'x'.repeat(4097), 'token:bad']) {
    for (const handler of [handleDeleteCase, handlePrepareAccountDeletion, handleConfirmAccountDeletion]) {
      assert.equal(code(await handler(input({}, credential), deps)), 'UNAUTHENTICATED');
    }
  }
});

test('provider authentication determines the response before invalid private input is disclosed', async () => {
  let privateCalls = 0;
  const deps = dependencies({ lifecycle: repository({ deleteCaseIfCurrent: async () => { privateCalls++; return { status: 'deleted' }; } }) });
  assert.equal(code(await handleDeleteCase(input({ ownerId: 'alice' }, 'unknown-session'), deps)), 'UNAUTHENTICATED');
  assert.equal(privateCalls, 0);
});

test('case deletion sends only authenticated owner and both current revisions', async () => {
  let received: unknown;
  const deps = dependencies({ authenticateForDeletion: async () => { throw new Error('Not account deletion'); },
    lifecycle: repository({ deleteCaseIfCurrent: async value => { received = value; return { status: 'deleted' }; } }) });
  const response = await handleDeleteCase(input(caseRequest()), deps);
  assert.equal(response.status, 200);
  assert.deepEqual(response.body, { schemaVersion: '1', caseId: 'fictional-case', deleted: true });
  assert.deepEqual(received, { userId: 'alice', caseId: 'fictional-case', revision: 2, expectedCatalogRevision: 3 });
});

test('delete requests reject missing confirmation, owner overrides, unsafe revisions and invalid identifiers', async () => {
  let writes = 0;
  const deps = dependencies({ lifecycle: repository({ deleteCaseIfCurrent: async () => { writes++; return { status: 'deleted' }; } }) });
  const invalid: unknown[] = [null, [], {}, { ...caseRequest(), ownerId: 'bob' }, { ...caseRequest(), confirmation: 'delete' },
    { ...caseRequest(), expectedCaseRevision: 0 }, { ...caseRequest(), expectedCaseRevision: Number.MAX_SAFE_INTEGER + 1 },
    { ...caseRequest(), expectedCatalogRevision: -1 }, { ...caseRequest(), expectedCatalogRevision: true },
    { ...caseRequest(), caseId: ' leading' }, { ...caseRequest(), caseId: 'line\nbreak' },
    { ...caseRequest(), caseId: '\ud800' }, { ...caseRequest(), caseId: '😀'.repeat(201) }];
  for (const body of invalid) assert.equal(code(await handleDeleteCase(input(body), deps)), 'INVALID_REQUEST');
  assert.equal(writes, 0);
  assert.equal((await handleDeleteCase(input({ ...caseRequest(), caseId: '😀'.repeat(200), expectedCatalogRevision: 0 }), deps)).status, 200);
});

test('request values are detached before authentication yields', async () => {
  const user = deferred<{ userId: string }>();
  const body = caseRequest();
  let received: unknown;
  const deps = dependencies({ authenticate: () => user.promise,
    lifecycle: repository({ deleteCaseIfCurrent: async value => { received = value; return { status: 'deleted' }; } }) });
  const response = handleDeleteCase(input(body), deps);
  body.caseId = 'changed-case'; body.expectedCaseRevision = 900; body.expectedCatalogRevision = 901;
  user.resolve({ userId: 'alice' });
  assert.equal((await response).status, 200);
  assert.deepEqual(received, { userId: 'alice', caseId: 'fictional-case', revision: 2, expectedCatalogRevision: 3 });
});

test('case result mappings preserve revision conflicts and missing/cross-owner indistinguishability', async () => {
  const expected = { not_found: [404, 'CASE_NOT_FOUND'], conflict: [409, 'CASE_REVISION_MISMATCH'],
    evidence_conflict: [409, 'EVIDENCE_CONFLICT'], invalid_input: [400, 'INVALID_REQUEST'] } as const;
  for (const [status, [http, error]] of Object.entries(expected)) {
    const response = await handleDeleteCase(input(caseRequest()), dependencies({
      lifecycle: repository({ deleteCaseIfCurrent: async () => ({ status } as DeleteCaseResult) }),
    }));
    assert.equal(response.status, http); assert.equal(code(response), error);
  }
  const deps = dependencies({ authenticate: async credential => ({ userId: credential }),
    lifecycle: repository({ deleteCaseIfCurrent: async value => ({ status: value.userId === 'alice' ? 'deleted' : 'not_found' }) }) });
  const first = await handleDeleteCase(input(caseRequest(), 'alice'), deps);
  const retry = await handleDeleteCase(input(caseRequest(), 'alice'), deps);
  assert.deepEqual(first, retry);
  const otherOwner = await handleDeleteCase(input(caseRequest(), 'bob'), deps);
  const absent = await handleDeleteCase(input({ ...caseRequest(), caseId: 'absent' }, 'bob'), deps);
  assert.deepEqual(otherOwner, absent);
});

test('account preview uses recent authentication and stores only a digest of a fresh receipt', async () => {
  const received: { userId: string; tokenHash: string }[] = [];
  const deps = dependencies({ authenticate: async () => { throw new Error('Normal auth must not be used'); },
    lifecycle: repository({ prepareAccountDeletion: async value => {
      received.push(value); return { status: 'ready', expiresAt: '2026-10-17T20:05:00Z', counts: { cases: 0, evidence: 0, exports: 0, storedBytes: 0 } };
    } }) });
  const tokens: string[] = [];
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await handlePrepareAccountDeletion(input({ schemaVersion: '1' }), deps);
    assert.equal(response.status, 200);
    assert.ok('deletionToken' in response.body);
    const receipt = response.body.deletionToken;
    assert.match(receipt, /^[0-9a-f]{64}$/);
    assert.deepEqual(received[attempt], { userId: 'alice', tokenHash: createHash('sha256').update(receipt).digest('hex') });
    assert.notEqual(received[attempt].tokenHash, receipt);
    tokens.push(receipt);
  }
  assert.notEqual(tokens[0], tokens[1]);
});

test('account preparation rejects caller-supplied hashes, targets and confirmation metadata', async () => {
  let preparations = 0;
  const deps = dependencies({ lifecycle: repository({ prepareAccountDeletion: async () => { preparations++; return { status: 'closed' }; } }) });
  for (const extra of [{ userId: 'bob' }, { tokenHash }, { deletionToken: token }, { counts: {} }, { expiresAt: 'tomorrow' }]) {
    assert.equal(code(await handlePrepareAccountDeletion(input({ schemaVersion: '1', ...extra }), deps)), 'INVALID_REQUEST');
  }
  assert.equal(preparations, 0);
});

test('recent-authentication failures are explicit and closed-account/provider errors are sanitized', async () => {
  for (const handler of [handlePrepareAccountDeletion, handleConfirmAccountDeletion]) {
    const response = await handler(input(handler === handlePrepareAccountDeletion ? { schemaVersion: '1' } : confirmRequest()),
      dependencies({ authenticateForDeletion: async () => { throw new RecentAuthenticationRequiredError(); } }));
    assert.equal(response.status, 403); assert.equal(code(response), 'RECENT_AUTHENTICATION_REQUIRED');
  }
  const closed = await handleDeleteCase(input(caseRequest()), dependencies({ lifecycle: repository({
    deleteCaseIfCurrent: async () => { throw new AccountClosedError(); },
  }) }));
  assert.equal(code(closed), 'ACCOUNT_CLOSED');
  const provider = await handlePrepareAccountDeletion(input({ schemaVersion: '1' }), dependencies({
    authenticateForDeletion: async () => { throw new Error('private-password provider-body'); },
  }));
  assert.equal(code(provider), 'SERVICE_UNAVAILABLE');
  assert.doesNotMatch(JSON.stringify(provider), /private-password|provider-body/);
});

test('confirmation detaches its token, binds the verified owner and preserves pending versus complete', async () => {
  const user = deferred<{ userId: string }>();
  const body = confirmRequest();
  let received: unknown;
  const deps = dependencies({ authenticate: async () => null, authenticateForDeletion: () => user.promise,
    lifecycle: repository({ confirmAccountDeletion: async value => { received = value; return { status: 'confirmed', deletion: pending }; } }) });
  const responsePromise = handleConfirmAccountDeletion(input(body), deps);
  body.deletionToken = 'b'.repeat(64); body.confirmation = 'changed';
  user.resolve({ userId: 'alice' });
  const response = await responsePromise;
  assert.equal(response.status, 202);
  assert.deepEqual(response.body, { schemaVersion: '1', ...pending });
  assert.deepEqual(received, { userId: 'alice', tokenHash });
  const finished = await handleConfirmAccountDeletion(input(confirmRequest()), dependencies({
    lifecycle: repository({ confirmAccountDeletion: async () => ({ status: 'confirmed', deletion: complete }) }),
  }));
  assert.equal(finished.status, 200); assert.deepEqual(finished.body, { schemaVersion: '1', ...complete });
});

test('confirmation input is exact and tokens require exactly 64 lowercase hexadecimal characters', async () => {
  let calls = 0;
  const deps = dependencies({ lifecycle: repository({ confirmAccountDeletion: async () => { calls++; return { status: 'confirmed', deletion: pending }; } }) });
  for (const deletionToken of ['', 'a'.repeat(63), 'a'.repeat(65), 'A'.repeat(64), `${token}\n`, `${token}\r\n`, 'x'.repeat(64), null]) {
    assert.equal(code(await handleConfirmAccountDeletion(input({ ...confirmRequest(), deletionToken }), deps)), 'INVALID_REQUEST');
  }
  for (const body of [{ ...confirmRequest(), userId: 'bob' }, { ...confirmRequest(), confirmation: true },
    { ...confirmRequest(), confirmation: 'DELETE_CASE' }]) {
    assert.equal(code(await handleConfirmAccountDeletion(input(body), deps)), 'INVALID_REQUEST');
  }
  assert.equal(calls, 0);
});

test('confirmation distinguishes expired or changed previews from unknown owner-bound receipts', async () => {
  const expected = { not_found: [404, 'DELETION_NOT_FOUND'], expired: [410, 'DELETION_EXPIRED'],
    changed: [409, 'DELETION_CHANGED'], invalid_input: [400, 'INVALID_REQUEST'] } as const;
  for (const status of Object.keys(expected) as (keyof typeof expected)[]) {
    const response = await handleConfirmAccountDeletion(input(confirmRequest()), dependencies({
      lifecycle: repository({ confirmAccountDeletion: async () => ({ status }) }),
    }));
    assert.equal(response.status, expected[status][0]); assert.equal(code(response), expected[status][1]);
  }
});

test('receipt status remains available after provider removal and reveals only consistent lifecycle state', async () => {
  let received: unknown;
  const deps = dependencies({ authenticate: async () => { throw new Error('Auth identity removed'); },
    authenticateForDeletion: async () => { throw new Error('Auth identity removed'); },
    lifecycle: repository({ readAccountDeletionReceipt: async value => { received = value; return complete; } }) });
  const response = await handleAccountDeletionStatus(input({ schemaVersion: '1' }, token), deps);
  assert.equal(response.status, 200);
  assert.deepEqual(response.body, { schemaVersion: '1', ...complete });
  assert.equal(received, tokenHash);
  assert.doesNotMatch(JSON.stringify(response.body), /alice|userId|counts|deletionToken|tokenHash/);
  for (const deletion of [awaiting, pending]) {
    assert.deepEqual((await handleAccountDeletionStatus(input({ schemaVersion: '1' }, token), dependencies({
      lifecycle: repository({ readAccountDeletionReceipt: async () => deletion }),
    }))).body, { schemaVersion: '1', ...deletion });
  }
});

test('status rejects wrong credential form/body and returns the same safe unavailable receipt error', async () => {
  let reads = 0;
  const deps = dependencies({ lifecycle: repository({ readAccountDeletionReceipt: async () => { reads++; return null; } }) });
  for (const credential of [null, 'alice-session', 'A'.repeat(64), `${token}\n`, token.slice(1)]) {
    assert.equal(code(await handleAccountDeletionStatus(input({ schemaVersion: '1' }, credential), deps)), 'UNAUTHENTICATED');
  }
  assert.equal(code(await handleAccountDeletionStatus(input({ schemaVersion: '1', deletionToken: token }, token), deps)), 'INVALID_REQUEST');
  assert.equal(reads, 0);
  assert.equal(code(await handleAccountDeletionStatus(input({ schemaVersion: '1' }, token), deps)), 'DELETION_NOT_FOUND');
  assert.equal(reads, 1);
});

test('malformed repository results cannot fabricate deletion or leak internal fields', async () => {
  const invalidStates: unknown[] = [null, {}, { ...complete, userId: 'private-owner' },
    { ...complete, providerIdentityDeleted: false }, { ...pending, applicationDataDeleted: false },
    { ...awaiting, providerIdentityDeleted: true }, { ...complete, status: ['complete'] }];
  for (const value of invalidStates) {
    const response = await handleConfirmAccountDeletion(input(confirmRequest()), dependencies({ lifecycle: repository({
      confirmAccountDeletion: async () => ({ status: 'confirmed', deletion: value as AccountDeletionState }),
    }) }));
    assert.equal(code(response), 'INTERNAL_ERROR');
    assert.doesNotMatch(JSON.stringify(response), /private-owner/);
  }
  const premature = await handleConfirmAccountDeletion(input(confirmRequest()), dependencies({ lifecycle: repository({
    confirmAccountDeletion: async () => ({ status: 'confirmed', deletion: awaiting }),
  }) }));
  assert.equal(code(premature), 'INTERNAL_ERROR');
  const badCase = await handleDeleteCase(input(caseRequest()), dependencies({ lifecycle: repository({
    deleteCaseIfCurrent: async () => ({ status: 'deleted', ownerId: 'private-owner' } as DeleteCaseResult),
  }) }));
  assert.equal(code(badCase), 'INTERNAL_ERROR');
});

test('preview adapter output validates exact counts and actual UTC calendar time', async () => {
  for (const change of [{ counts: { cases: -1, evidence: 0, exports: 0, storedBytes: 0 } },
    { counts: { cases: 1, evidence: 0, exports: 0, storedBytes: 0, owner: 'private-owner' } },
    { expiresAt: '2026-02-30T20:05:00Z' }, { expiresAt: '2026-10-17T20:05:00Z\n' }]) {
    const response = await handlePrepareAccountDeletion(input({ schemaVersion: '1' }), dependencies({ lifecycle: repository({
      prepareAccountDeletion: async () => ({ status: 'ready', expiresAt: '2026-10-17T20:05:00Z',
        counts: { cases: 1, evidence: 0, exports: 0, storedBytes: 0 }, ...change }),
    }) }));
    assert.equal(code(response), 'INTERNAL_ERROR');
    assert.doesNotMatch(JSON.stringify(response), /private-owner/);
  }
});

test('uncertain mutation errors are sanitized and never cause an automatic retry', async () => {
  let calls = 0;
  const response = await handleConfirmAccountDeletion(input(confirmRequest()), dependencies({ lifecycle: repository({
    confirmAccountDeletion: async () => { calls++; throw new Error(`private database password ${token}`); },
  }) }));
  assert.equal(code(response), 'SERVICE_UNAVAILABLE');
  assert.equal(calls, 1);
  assert.doesNotMatch(JSON.stringify(response), /private database|password|a{64}/);
});

test('malformed authentication adapter output fails closed without repository work', async () => {
  let calls = 0;
  for (const user of [{ userId: '' }, { userId: ['alice'] }, { userId: 'alice', providerBody: 'private' }, undefined]) {
    const deps = dependencies({ authenticate: async () => user as unknown as { userId: string },
      lifecycle: repository({ deleteCaseIfCurrent: async () => { calls++; return { status: 'deleted' }; } }) });
    assert.equal(code(await handleDeleteCase(input(caseRequest()), deps)), 'INTERNAL_ERROR');
  }
  assert.equal(calls, 0);
});
