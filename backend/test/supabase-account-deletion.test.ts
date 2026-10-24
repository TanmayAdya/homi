import assert from 'node:assert/strict';
import { setImmediate } from 'node:timers/promises';
import test from 'node:test';
import {
  AccountDeletionProviderError, completePendingAccountDeletions, createSupabaseAccountDeleter,
  type SupabaseAccountDeletionConfig,
} from '../src/auth/supabase-account-deletion.ts';
import { MAX_AUTH_RESPONSE_BYTES } from '../src/auth/supabase-auth.ts';
import type { AuthDeletionJob, LifecycleMaintenance } from '../src/lifecycle/types.ts';
import { parseAccountDeletionArguments } from '../tool/complete-account-deletions.ts';

const userId = 'f285ae49-df96-48ed-a904-a7024b9708c3';
const otherId = 'a58f9dbb-0095-45d8-9424-a76579d3dbdc';
const jobId = '3fba1d26-0cdb-4b93-9a29-95917b59b15b';
const leaseToken = 'bf05c565-41b9-44a8-84af-01c4305aba87';
const config: SupabaseAccountDeletionConfig = {
  projectUrl: 'https://fictional-project.supabase.co', secretKey: 'sb_secret_fictional_operator_test_key',
};
const present = () => json({ id: userId, role: 'authenticated', email: 'fictional@example.invalid' });
const absent = () => json({ code: 'user_not_found', message: 'User not found' }, 404);
const legacyAbsent = () => json({ code: 404, error_code: 'user_not_found', msg: 'User not found' }, 404);
const json = (value: unknown, status = 200, headers: Record<string, string> = {}) => new Response(
  JSON.stringify(value), { status, headers: { 'content-type': 'application/json', ...headers } },
);
const safeError = (error: unknown) => {
  assert.ok(error instanceof AccountDeletionProviderError);
  assert.equal(error.message, 'Provider account deletion could not be confirmed. The request remains pending.');
  assert.equal(error.cause, undefined);
  assert.equal(JSON.stringify(error).includes(config.secretKey), false);
  assert.equal(JSON.stringify(error).includes('fictional@example.invalid'), false);
  return true;
};

test('hard-deletes only the verified requested identity and confirms absence with a second GET', async () => {
  const methods: string[] = [];
  const responses = [present(), json({}), absent()];
  const remove = createSupabaseAccountDeleter(config, async (input, init) => {
    assert.equal(input, `${config.projectUrl}/auth/v1/admin/users/${userId}`);
    assert.equal(init?.redirect, 'error'); assert.equal(init?.cache, 'no-store');
    assert.ok(init?.signal instanceof AbortSignal);
    const headers = new Headers(init?.headers);
    assert.equal(headers.get('apikey'), config.secretKey);
    assert.equal(headers.has('authorization'), false);
    assert.equal(headers.get('accept'), 'application/json');
    assert.equal(headers.get('x-supabase-api-version'), '2024-01-01');
    if (init?.method === 'DELETE') assert.deepEqual(JSON.parse(String(init.body)), { should_soft_delete: false });
    else assert.equal(init?.body, undefined);
    methods.push(init!.method!); return responses.shift()!;
  });
  assert.deepEqual(await remove(userId), { status: 'deleted' });
  assert.deepEqual(methods, ['GET', 'DELETE', 'GET']);
});

test('already absent identities are acknowledged without a DELETE request', async () => {
  let calls = 0;
  const result = await createSupabaseAccountDeleter(config, async (_input, init) => {
    calls++; assert.equal(init?.method, 'GET'); return absent();
  })(userId);
  assert.deepEqual(result, { status: 'already_absent' }); assert.equal(calls, 1);
});

test('documented legacy absence is recognized before deletion and after a hard-delete or concurrent deletion', async () => {
  for (const responses of [
    [legacyAbsent()],
    [present(), json({}), legacyAbsent()],
    [present(), legacyAbsent(), legacyAbsent()],
  ]) {
    const expected = responses.length === 1 ? 'already_absent' : 'deleted';
    const methods: string[] = [];
    assert.deepEqual(await createSupabaseAccountDeleter(config, async (_input, init) => {
      assert.equal(new Headers(init?.headers).get('x-supabase-api-version'), '2024-01-01');
      methods.push(init!.method!);
      assert.ok(responses.length > 0);
      return responses.shift()!;
    })(userId), { status: expected });
    assert.deepEqual(methods, expected === 'already_absent' ? ['GET'] : ['GET', 'DELETE', 'GET']);
    assert.equal(responses.length, 0);
  }
});

test('contradictory or incomplete modern/legacy absence codes keep every stage pending', async () => {
  const invalid = [
    { code: 'user_not_found', error_code: 'not_found' },
    { code: 'user_not_found', error_code: null },
    { code: 'user_not_found', error_code: 404 },
    { code: 'not_found', error_code: 'user_not_found' },
    { code: 401, error_code: 'user_not_found' },
    { code: '404', error_code: 'user_not_found' },
    { code: 404, error_code: 'not_found' },
    { code: 404 },
    { error_code: 'user_not_found' },
  ];
  for (const value of invalid) {
    for (const stage of [0, 1, 2]) {
      let calls = 0;
      const before = [present, () => json({})];
      await assert.rejects(createSupabaseAccountDeleter(config, async () => {
        const index = calls++;
        return index === stage ? json(value, 404) : before[index]();
      })(userId), safeError);
      assert.equal(calls, stage + 1);
    }
  }
});

test('a lost DELETE response stays pending; the next run reconciles absence without deleting again', async () => {
  let exists = true;
  let deletes = 0;
  const remove = createSupabaseAccountDeleter(config, async (_input, init) => {
    if (init?.method === 'GET') return exists ? present() : absent();
    deletes++; exists = false;
    throw new Error(`lost response private=${config.secretKey}`);
  });
  await assert.rejects(remove(userId), safeError);
  assert.deepEqual(await remove(userId), { status: 'already_absent' });
  assert.equal(deletes, 1);
});

test('absence after concurrent deletion is reconciled, but DELETE success alone is insufficient', async () => {
  let responses = [present(), absent(), absent()];
  assert.deepEqual(await createSupabaseAccountDeleter(config, async () => responses.shift()!)(userId), { status: 'deleted' });
  responses = [present(), json({}), present()];
  await assert.rejects(createSupabaseAccountDeleter(config, async () => responses.shift()!)(userId), safeError);
});

test('wrong identity, privileged role, and malformed preflight never reach DELETE', async () => {
  for (const value of [null, [], {}, { id: otherId, role: 'authenticated' }, { id: userId },
    { id: userId, role: 'service_role' }, { id: userId, role: 'anon' }]) {
    let calls = 0;
    await assert.rejects(createSupabaseAccountDeleter(config, async (_input, init) => {
      calls++; assert.equal(init?.method, 'GET'); return json(value);
    })(userId), safeError);
    assert.equal(calls, 1);
  }
});

test('401/403/500 and arbitrary 404 are never successful deletion', async () => {
  const bad = [() => json({ code: 'user_not_found' }, 401), () => json({ code: 'user_not_found' }, 403),
    () => json({ code: 'user_not_found' }, 500), () => json({ message: 'Not Found' }, 404),
    () => json({ code: 'not_found' }, 404), () => new Response('<html>Not Found</html>', { status: 404 }),
    () => new Response(null, { status: 204 })];
  for (const make of bad) {
    for (const stage of [0, 1, 2]) {
      let calls = 0;
      const before = [present, () => json({})];
      await assert.rejects(createSupabaseAccountDeleter(config, async () => {
        const index = calls++; return index === stage ? make() : before[index]();
      })(userId), safeError);
      assert.equal(calls, stage + 1);
    }
  }
});

test('malformed DELETE body is not accepted as a successful acknowledgement', async () => {
  for (const value of [null, [], { user: {} }, { error: 'private' }]) {
    const responses = [present(), json(value)];
    await assert.rejects(createSupabaseAccountDeleter(config, async () => responses.shift()!)(userId), safeError);
  }
});

test('configuration and UUID boundaries fail without network access or leaked secrets', async () => {
  let calls = 0;
  const fetchImpl: typeof fetch = async () => { calls++; return absent(); };
  const badConfig: SupabaseAccountDeletionConfig[] = [
    ...['http://example.test', 'https://example.test/path', 'https://example.test/?', 'https://example.test/#',
      'https://user:password@example.test', 'https://@example.test', 'https://example.test\\path',
      'https://example.test/../', 'https://example.test\n', ' https://example.test', 'not-a-url']
      .map(projectUrl => ({ ...config, projectUrl })),
    ...['sb_publishable_key', 'legacy.jwt.secret', 'sb_secret_', 'sb_secret_key\n', 'sb_secret_key\r\n',
      `sb_secret_${'x'.repeat(512)}`, 'REPLACE_WITH_OPERATOR_ONLY_SB_SECRET_KEY']
      .map(secretKey => ({ ...config, secretKey })),
    ...[0, -1, 10_001, 1.5, NaN, Infinity].map(timeoutMs => ({ ...config, timeoutMs })),
  ];
  for (const value of badConfig) assert.throws(() => createSupabaseAccountDeleter(value, fetchImpl), {
    name: 'TypeError', message: 'Invalid operator account-deletion configuration.',
  });
  const remove = createSupabaseAccountDeleter(config, fetchImpl);
  for (const id of ['', `${userId}\n`, userId.toUpperCase(), '00000000-0000-0000-0000-000000000000',
    '../users', 'fictional@example.invalid', null, 12]) await assert.rejects(remove(id as string), safeError);
  assert.equal(calls, 0);
});

test('config strings are detached before provider I/O', async () => {
  const mutable = { ...config, projectUrl: `${config.projectUrl}/`, timeoutMs: 5000 };
  const remove = createSupabaseAccountDeleter(mutable, async (input, init) => {
    assert.equal(input, `${config.projectUrl}/auth/v1/admin/users/${userId}`);
    assert.equal(new Headers(init?.headers).get('apikey'), config.secretKey);
    return absent();
  });
  mutable.projectUrl = 'https://unrelated.example'; mutable.secretKey = 'sb_secret_changed'; mutable.timeoutMs = 0;
  assert.deepEqual(await remove(userId), { status: 'already_absent' });
});

test('redirects and changed final origins fail without credential forwarding', async () => {
  for (const status of [301, 302, 303, 307, 308]) {
    let calls = 0;
    await assert.rejects(createSupabaseAccountDeleter(config, async (_input, init) => {
      calls++; assert.equal(init?.redirect, 'error');
      return new Response(null, { status, headers: { location: 'https://unrelated.example' } });
    })(userId), safeError);
    assert.equal(calls, 1);
  }
  for (const property of [{ redirected: true }, { url: 'https://unrelated.example/auth/v1/admin/users/' + userId }]) {
    const response = absent();
    for (const [key, value] of Object.entries(property)) Object.defineProperty(response, key, { value });
    await assert.rejects(createSupabaseAccountDeleter(config, async () => response)(userId), safeError);
  }
});

test('bounded body handling rejects invalid length, malformed JSON, and invalid UTF-8', async () => {
  const responses = [
    () => json({}, 200, { 'content-length': String(MAX_AUTH_RESPONSE_BYTES + 1) }),
    () => json({}, 200, { 'content-length': '-1' }),
    () => new Response('{', { headers: { 'content-type': 'application/json' } }),
    () => new Response(new Uint8Array([0x7b, 0xc3, 0x28, 0x7d]), { headers: { 'content-type': 'application/json' } }),
    () => new Response(null, { headers: { 'content-type': 'application/json' } }),
  ];
  for (const make of responses) await assert.rejects(createSupabaseAccountDeleter(config, async () => make())(userId), safeError);
  let cancelled = false;
  await assert.rejects(createSupabaseAccountDeleter(config, async () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(MAX_AUTH_RESPONSE_BYTES + 1)); },
    cancel() { cancelled = true; },
  }), { headers: { 'content-type': 'application/json', 'content-length': '1' } }))(userId), safeError);
  assert.equal(cancelled, true);
});

test('a header deadline aborts work, cancels late bodies and never resumes the DELETE pipeline', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let resolve!: (response: Response) => void;
  let signal: AbortSignal | undefined;
  let calls = 0;
  const remove = createSupabaseAccountDeleter(config, async (_input, init) => {
    calls++; signal = init?.signal as AbortSignal;
    return new Promise<Response>(accept => { resolve = accept; });
  });
  const rejected = assert.rejects(remove(userId), safeError);
  t.mock.timers.tick(5000); await rejected;
  assert.equal(signal?.aborted, true);
  let cancelled = false;
  resolve(new Response(new ReadableStream({ cancel() { cancelled = true; } }), { headers: { 'content-type': 'application/json' } }));
  await setImmediate(); assert.equal(cancelled, true); assert.equal(calls, 1);
});

test('the same deadline covers streaming bodies even if cancellation stalls', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let cancelled = false;
  const remove = createSupabaseAccountDeleter({ ...config, timeoutMs: 25 }, async () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new TextEncoder().encode('{')); },
    cancel() { cancelled = true; return new Promise<void>(() => {}); },
  }), { headers: { 'content-type': 'application/json' } }));
  const rejected = assert.rejects(remove(userId), safeError);
  await setImmediate(); t.mock.timers.tick(25); await rejected;
  assert.equal(cancelled, true);
});

function maintenance(jobs: AuthDeletionJob[] = []): LifecycleMaintenance & { finishes: unknown[]; claims: number[] } {
  const finishes: unknown[] = []; const claims: number[] = [];
  return {
    finishes, claims,
    pendingAuthDeletionCount: async () => jobs.length,
    claimAuthDeletionJobs: async limit => { claims.push(limit); return jobs.length ? [jobs.shift()!] : []; },
    finishAuthDeletionJob: async input => { finishes.push(structuredClone(input)); return true; },
    sweepRetention: async () => { throw new Error('This worker must not sweep unrelated records.'); },
  };
}
const job = (): AuthDeletionJob => ({ jobId, userId, leaseToken });

test('dry run only counts, requires no Auth deleter and neither claims nor completes jobs', async () => {
  const repo = maintenance([job()]);
  assert.deepEqual(await completePendingAccountDeletions(repo, undefined, { apply: false, limit: 5 }), {
    mode: 'dry_run', pendingBefore: 1, claimed: 0, completed: 0, retryPending: 0, failed: 0, databaseFailure: false,
  });
  assert.deepEqual(repo.claims, []); assert.deepEqual(repo.finishes, []);
});

test('worker continues to another queued owner after provider failure and acknowledges only confirmed absence', async () => {
  const repo = maintenance([job(), { ...job(), jobId: otherId, userId: otherId }]);
  const ids: string[] = [];
  const report = await completePendingAccountDeletions(repo, async id => {
    ids.push(id); if (id === userId) throw new Error(config.secretKey);
    return { status: 'already_absent' };
  }, { apply: true, limit: 2 });
  assert.deepEqual(report, { mode: 'apply', pendingBefore: 2, claimed: 2, completed: 1,
    retryPending: 1, failed: 1, databaseFailure: false });
  assert.deepEqual(ids, [userId, otherId]); assert.deepEqual(repo.claims, [1, 1]);
  assert.deepEqual(repo.finishes, [{ jobId, leaseToken, outcome: 'retry' }, { jobId: otherId, leaseToken, outcome: 'deleted' }]);
  assert.equal(JSON.stringify(report).includes(userId), false);
  assert.equal(JSON.stringify(report).includes(config.secretKey), false);
});

test('claimed IDs and options are detached while the provider request is in flight', async () => {
  const mutable = job(); const repo = maintenance([mutable]);
  const options = { apply: true, limit: 1 };
  await completePendingAccountDeletions(repo, async id => {
    assert.equal(id, userId); mutable.userId = otherId; mutable.jobId = otherId; mutable.leaseToken = otherId;
    options.limit = 5; return { status: 'deleted' };
  }, options);
  assert.deepEqual(repo.finishes, [{ jobId, leaseToken, outcome: 'deleted' }]);
  assert.deepEqual(repo.claims, [1]);
});

test('invalid or duplicate claimed jobs stop before unrequested provider operations', async () => {
  for (const invalid of [[{ ...job(), userId: 'not-a-uuid' }], [job(), job()], [{ ...job(), rawSecret: 'private' }], null]) {
    const repo = maintenance([job()]); repo.claimAuthDeletionJobs = async () => invalid as AuthDeletionJob[];
    let calls = 0;
    const report = await completePendingAccountDeletions(repo, async () => { calls++; return { status: 'deleted' }; }, { apply: true, limit: 5 });
    assert.equal(report.databaseFailure, true); assert.equal(calls, 0);
  }
  const repo = maintenance([job(), job()]); let calls = 0;
  const report = await completePendingAccountDeletions(repo, async () => { calls++; throw new Error(); }, { apply: true, limit: 2 });
  assert.equal(calls, 1); assert.equal(report.databaseFailure, true); assert.equal(report.retryPending, 1);
});

test('unsafe DB acknowledgement stops later jobs and never reports completion', async () => {
  for (const finish of [async () => false, async () => { throw new Error('private database message'); }]) {
    const repo = maintenance([job(), { ...job(), jobId: otherId, userId: otherId }]);
    repo.finishAuthDeletionJob = finish;
    let calls = 0;
    const report = await completePendingAccountDeletions(repo, async () => { calls++; return { status: 'deleted' }; }, { apply: true, limit: 2 });
    assert.equal(calls, 1); assert.equal(report.completed, 0); assert.equal(report.failed, 1);
    assert.equal(report.databaseFailure, true);
  }
});

test('count/claim failures are sanitized and invalid options cause no work', async () => {
  const repo = maintenance([job()]);
  for (const count of [async () => -1, async () => Number.MAX_SAFE_INTEGER + 1, async () => { throw new Error(config.secretKey); }]) {
    repo.pendingAuthDeletionCount = count;
    const report = await completePendingAccountDeletions(repo, undefined, { apply: false, limit: 1 });
    assert.equal(report.databaseFailure, true); assert.equal(report.pendingBefore, null);
  }
  repo.pendingAuthDeletionCount = async () => 1;
  repo.claimAuthDeletionJobs = async () => { throw new Error(config.secretKey); };
  assert.equal((await completePendingAccountDeletions(repo, async () => ({ status: 'deleted' }), { apply: true, limit: 1 })).databaseFailure, true);
  for (const limit of [0, 6, 1.5, NaN]) await assert.rejects(
    completePendingAccountDeletions(repo, undefined, { apply: false, limit }), TypeError,
  );
  await assert.rejects(completePendingAccountDeletions(repo, undefined, { apply: true, limit: 1 }), TypeError);
});

test('CLI defaults to count-only and requires explicit apply with a bounded batch and no user arguments', () => {
  assert.deepEqual(parseAccountDeletionArguments([]), { apply: false, limit: 1 });
  assert.deepEqual(parseAccountDeletionArguments(['--dry-run']), { apply: false, limit: 1 });
  assert.deepEqual(parseAccountDeletionArguments(['--apply', '--limit', '5']), { apply: true, limit: 5 });
  assert.deepEqual(parseAccountDeletionArguments(['--limit', '2', '--apply']), { apply: true, limit: 2 });
  assert.equal(parseAccountDeletionArguments(['--help']), 'help');
  for (const args of [['--apply', '--dry-run'], ['--apply', '--apply'], ['--limit'], ['--limit', '6'],
    ['--limit', '0'], ['--limit', '1.0'], ['--limit', '1', '--limit', '2'], [userId],
    ['--user-id', userId], ['--secret', config.secretKey], ['--help', '--apply']]) {
    assert.throws(() => parseAccountDeletionArguments(args), {
      name: 'TypeError', message: 'Invalid account-deletion arguments. Use --help.',
    });
  }
});
