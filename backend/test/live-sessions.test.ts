import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, chmod, writeFile, stat, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { LiveSessionVerificationError, verifyLiveSessions, type LiveSessionConfiguration } from '../src/auth/live-session-verifier.ts';
import { liveSessionEnvironment, sessionFixtureIds } from '../tool/verify-live-sessions.ts';

const origin = 'https://fictional.supabase.co';
const apiOrigin = 'http://127.0.0.1:8788';
const userIds = ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'];
const caseIds = ['11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222'] as const;
const config = (): LiveSessionConfiguration => ({
  auth: { projectUrl: origin, publishableKey: 'sb_publishable_fictional', timeoutMs: 1000 },
  apiOrigin, accounts: [{ email: 'fictional-a@example.invalid', password: 'fictional-password-a' },
    { email: 'fictional-b@example.invalid', password: 'fictional-password-b' }], caseIds, createFixtures: false,
});
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const apiError = (code: string, status: number) => json({ schemaVersion: '1', error: { code, message: 'Local test error.' } }, status);
function snapshot(caseId: string) {
  return { schemaVersion: '1', caseId, revision: 1, profile: { city: null, county: null, healthPlan: null, tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
}
interface Call { url: string; method: string; body: Record<string, unknown>; token: string | null }
function fake(options: {
  absentCases?: boolean; sameUser?: boolean; refreshedWrongUser?: boolean;
  intercept?: (call: Call) => Response | Promise<Response> | undefined;
} = {}) {
  const calls: Call[] = [];
  const activeCases = new Set(options.absentCases ? [] : caseIds);
  const loggedOut = new Set<number>();
  const fetchImpl: typeof fetch = async (input, init) => {
    const url = String(input);
    const token = new Headers(init?.headers).get('Authorization');
    const call: Call = { url, method: init?.method ?? 'GET', token,
      body: init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {} };
    calls.push(call);
    assert.equal(init?.redirect, 'error'); assert.equal(init?.cache, 'no-store');
    assert.ok(init?.signal instanceof AbortSignal);
    const override = options.intercept?.(call);
    if (override) return await override;
    if (url.startsWith(origin)) {
      assert.equal(new Headers(init?.headers).get('apikey'), 'sb_publishable_fictional');
      if (url.endsWith('/token?grant_type=password')) {
        const index = call.body.email === config().accounts[0].email ? 0 : 1;
        assert.equal(call.body.password, config().accounts[index].password);
        return json({ access_token: index === 0 ? 'access-a' : 'access-b', refresh_token: index === 0 ? 'refresh-a' : 'refresh-b',
          token_type: 'bearer', user: { id: 'deliberately-untrusted-token-body-identity' } });
      }
      if (url.endsWith('/token?grant_type=refresh_token')) {
        if (call.body.refresh_token === 'refresh-a') return json({ access_token: 'access-a-new', refresh_token: 'refresh-a-new', token_type: 'bearer' });
        assert.equal(call.body.refresh_token, 'refresh-a-new');
        assert.ok(loggedOut.has(0));
        return json({ error_code: 'refresh_token_not_found', msg: 'Private provider text must never leave this helper.' }, 400);
      }
      if (url.endsWith('/user')) {
        const index = token === 'Bearer access-b' ? 1 : 0;
        return json({ id: options.sameUser ? userIds[0]
          : options.refreshedWrongUser && token === 'Bearer access-a-new' ? userIds[1] : userIds[index], role: 'authenticated' });
      }
      if (url.endsWith('/logout?scope=local')) {
        loggedOut.add(token === 'Bearer access-b' ? 1 : 0);
        return new Response(null, { status: 204 });
      }
      throw new Error('Unexpected provider endpoint; no signup/admin/email/global logout is allowed.');
    }
    assert.ok(url.startsWith(apiOrigin));
    assert.equal(new Headers(init?.headers).get('apikey'), null);
    if (token?.startsWith('Bearer invalid-session-check-')) return apiError('UNAUTHENTICATED', 401);
    const owner = token === 'Bearer access-b' ? 1 : 0;
    if (url.endsWith('/create-case')) {
      assert.equal(call.body.caseId, caseIds[owner]);
      assert.deepEqual(call.body, (({ revision: _revision, ...draft }) => draft)(snapshot(caseIds[owner])));
      activeCases.add(caseIds[owner]);
      return json(snapshot(caseIds[owner]));
    }
    assert.ok(url.endsWith('/read-case'));
    return call.body.caseId === caseIds[owner] && activeCases.has(caseIds[owner])
      ? json(snapshot(caseIds[owner])) : apiError('CASE_NOT_FOUND', 404);
  };
  return { calls, fetchImpl, loggedOut, activeCases };
}
async function rejectsSafe(work: Promise<unknown>, stage: string, cleanupFailed?: boolean) {
  await assert.rejects(work, error => {
    assert.ok(error instanceof LiveSessionVerificationError);
    assert.equal(error.stage, stage);
    if (cleanupFailed !== undefined) assert.equal(error.cleanupFailed, cleanupFailed);
    assert.equal('cause' in error, false);
    const serialized = `${error.message} ${JSON.stringify(error)}`;
    for (const privateValue of ['fictional-password', 'access-a', 'refresh-a', '@', 'PRIVATE_PROVIDER']) {
      assert.equal(serialized.includes(privateValue), false);
    }
    return true;
  });
}

test('full read-only verification binds provider identities, refreshes, isolates owners and cleans only new local sessions', async () => {
  const transport = fake();
  const report = await verifyLiveSessions(config(), transport);
  assert.deepEqual(report, { status: 'passed', signedInUsers: 2, distinctVerifiedUsers: true, refreshVerified: true,
    ownerReads: 2, crossOwnerDenials: 2, invalidTokenDenied: true, localSignOuts: 2,
    latestRefreshDeniedAfterSignOut: true, fixturesCreated: 0 });
  assert.equal(transport.calls.filter(call => call.url.endsWith('/create-case')).length, 0);
  assert.equal(transport.calls.filter(call => call.url.endsWith('/user')).length, 3);
  const logouts = transport.calls.filter(call => call.url.includes('/logout'));
  assert.deepEqual(logouts.map(call => call.token), ['Bearer access-a-new', 'Bearer access-b']);
  const refreshes = transport.calls.filter(call => call.url.includes('grant_type=refresh_token'));
  assert.deepEqual(refreshes.map(call => call.body.refresh_token), ['refresh-a', 'refresh-a-new']);
  assert.equal(JSON.stringify(report).includes(caseIds[0]), false);
});

test('explicit fixture creation only creates missing retained IDs; later runs reuse existing cases', async () => {
  const transport = fake({ absentCases: true });
  assert.equal((await verifyLiveSessions({ ...config(), createFixtures: true }, transport)).fixturesCreated, 2);
  const existing = fake();
  assert.equal((await verifyLiveSessions({ ...config(), createFixtures: true }, existing)).fixturesCreated, 0);
});

test('missing read-only fixture fails without writes and still signs out both sessions', async () => {
  const transport = fake({ absentCases: true });
  await rejectsSafe(verifyLiveSessions(config(), transport), 'fixture_a', false);
  assert.deepEqual([...transport.loggedOut], [0, 1]);
  assert.equal(transport.calls.some(call => call.url.endsWith('/create-case')), false);
});

test('uncertain create and collision never auto-retry, overwrite or consume another ID', async () => {
  for (const uncertain of [true, false]) {
    const transport = fake({ absentCases: true, intercept: call => {
      if (call.url.endsWith('/create-case')) {
        if (uncertain) throw new Error('PRIVATE_PROVIDER access-a fictional-password-a');
        return apiError('CASE_ID_UNAVAILABLE', 409);
      }
    } });
    await rejectsSafe(verifyLiveSessions({ ...config(), createFixtures: true }, transport), 'fixture_a', false);
    assert.equal(transport.calls.filter(call => call.url.endsWith('/create-case')).length, 1);
    assert.deepEqual([...transport.loggedOut], [0, 1]);
  }
});

test('same verified user and changed refresh identity fail before case calls', async () => {
  for (const options of [{ sameUser: true }, { refreshedWrongUser: true }]) {
    const transport = fake(options);
    await rejectsSafe(verifyLiveSessions(config(), transport), options.sameUser ? 'identity' : 'refresh', false);
    assert.equal(transport.calls.some(call => call.url.startsWith(apiOrigin)), false);
    assert.equal(transport.loggedOut.size, 2);
    if (options.refreshedWrongUser) {
      assert.deepEqual(transport.calls.filter(call => call.url.includes('/logout')).map(call => call.token),
        ['Bearer access-a', 'Bearer access-b', 'Bearer access-a-new']);
    }
  }
});

test('failed refresh identity lookup cleans both the original and candidate credentials', async () => {
  const transport = fake({ intercept: call => call.url.endsWith('/user') && call.token === 'Bearer access-a-new'
    ? json({ message: 'PRIVATE_PROVIDER' }, 503) : undefined });
  await rejectsSafe(verifyLiveSessions(config(), transport), 'refresh', false);
  assert.deepEqual(transport.calls.filter(call => call.url.includes('/logout')).map(call => call.token),
    ['Bearer access-a', 'Bearer access-b', 'Bearer access-a-new']);
});

test('cross-owner disclosure, malformed snapshots and invalid bearer acceptance never pass', async () => {
  for (const target of ['cross', 'shape', 'invalid']) {
    const transport = fake({ intercept: call => {
      if (!call.url.startsWith(apiOrigin)) return;
      if (target === 'cross' && call.token === 'Bearer access-b' && call.body.caseId === caseIds[0]) return json(snapshot(caseIds[0]));
      if (target === 'shape') return json({ ...snapshot(String(call.body.caseId)), ownerId: userIds[0] });
      if (target === 'invalid' && call.token?.includes('invalid-session-check')) return json(snapshot(caseIds[0]));
    } });
    await rejectsSafe(verifyLiveSessions(config(), transport), target === 'cross' ? 'ownership' : target === 'shape' ? 'fixture_a' : 'invalid_token', false);
  }
});

test('provider network/error text is redacted; obtained sessions are cleaned after second login fails', async () => {
  const transport = fake({ intercept: call => {
    if (call.body.email === config().accounts[1].email) return json({ error_code: 'invalid_credentials', message: 'PRIVATE_PROVIDER' }, 400);
  } });
  await rejectsSafe(verifyLiveSessions(config(), transport), 'sign_in_b', false);
  assert.deepEqual([...transport.loggedOut], [0]);
});

test('unknown sign-in result and cleanup failures are explicit; all obtainable sessions get cleanup attempts', async () => {
  const transport = fake({ intercept: call => {
    if (call.body.email === config().accounts[1].email) throw new Error('PRIVATE_PROVIDER');
    if (call.url.includes('/logout')) return json({ message: 'PRIVATE_PROVIDER' }, 503);
  } });
  await rejectsSafe(verifyLiveSessions(config(), transport), 'sign_in_b', true);
  assert.equal(transport.calls.filter(call => call.url.includes('/logout')).length, 1);
  const logoutFailure = fake({ intercept: call => call.url.includes('/logout') ? json({ message: 'PRIVATE_PROVIDER' }, 503) : undefined });
  await rejectsSafe(verifyLiveSessions(config(), logoutFailure), 'local_sign_out', true);
  assert.equal(logoutFailure.calls.filter(call => call.url.includes('/logout')).length, 2);
});

test('revocation is checked with latest refresh and does not mistake service errors or old-token reuse for logout', async () => {
  for (const response of [json({ error_code: 'refresh_token_already_used' }, 400), json({ error_code: 'refresh_token_not_found' }, 503)]) {
    const transport = fake({ intercept: call => call.body.refresh_token === 'refresh-a-new' ? response : undefined });
    await rejectsSafe(verifyLiveSessions(config(), transport), 'refresh_denial', false);
  }
});

test('unexpected successful post-logout refresh is cleaned up and still fails', async () => {
  const transport = fake({ intercept: call => call.body.refresh_token === 'refresh-a-new'
    ? json({ access_token: 'unexpected-access', refresh_token: 'unexpected-refresh', token_type: 'bearer' }) : undefined });
  await rejectsSafe(verifyLiveSessions(config(), transport), 'refresh_denial', false);
  assert.equal(transport.calls.filter(call => call.url.includes('/logout')).length, 3);
});

test('lost post-logout refresh response reports unconfirmed cleanup without exposing transport error', async () => {
  const transport = fake({ intercept: call => {
    if (call.body.refresh_token === 'refresh-a-new') throw new Error('PRIVATE_PROVIDER refresh-a-new');
    return undefined;
  } });
  await rejectsSafe(verifyLiveSessions(config(), transport), 'refresh_denial', true);
});

test('bounds, UTF-8, redirects and stalled response bodies fail closed within deadline', async () => {
  const responses = [
    () => json({ oversized: 'x'.repeat(65536) }),
    () => new Response('x', { headers: { 'Content-Type': 'application/json', 'Content-Length': '65537' } }),
    () => new Response(Uint8Array.from([0xff]), { headers: { 'Content-Type': 'application/json' } }),
    () => { const response = json({}); Object.defineProperty(response, 'redirected', { value: true }); return response; },
    () => new Response(new ReadableStream({ start() {} }), { headers: { 'Content-Type': 'application/json' } }),
  ];
  for (const response of responses) {
    const transport = fake({ intercept: call => call.url.includes('grant_type=password') ? response() : undefined });
    await rejectsSafe(verifyLiveSessions({ ...config(), auth: { ...config().auth, timeoutMs: 10 } }, transport), 'sign_in_a', true);
  }
});

test('late sign-in headers cancel their body after the whole-request timeout has already finished', async () => {
  let release: ((response: Response) => void) | undefined;
  let cancelled = false;
  const transport = fake({ intercept: call => call.url.includes('grant_type=password')
    ? new Promise<Response>(resolve => { release = resolve; }) : undefined });
  await rejectsSafe(verifyLiveSessions({ ...config(), auth: { ...config().auth, timeoutMs: 10 } }, transport), 'sign_in_a', true);
  assert.ok(release);
  release(new Response(new ReadableStream({ cancel() { cancelled = true; } }),
    { headers: { 'Content-Type': 'application/json' } }));
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(cancelled, true);
  assert.equal(transport.calls.length, 1);
});

test('invalid origin/key/account/IDs fail before any network call', async () => {
  const variants = [
    { ...config(), apiOrigin: 'https://untrusted.invalid' },
    { ...config(), auth: { ...config().auth, projectUrl: `${origin}/path` } },
    { ...config(), auth: { ...config().auth, publishableKey: 'sb_secret_forbidden' } },
    { ...config(), caseIds: [caseIds[0], caseIds[0]] },
    { ...config(), caseIds: [`${caseIds[0]}\n`, caseIds[1]] },
    { ...config(), accounts: [config().accounts[0], config().accounts[0]] },
  ];
  for (const value of variants) {
    const transport = fake();
    await rejectsSafe(verifyLiveSessions(value as LiveSessionConfiguration, transport), 'configuration');
    assert.equal(transport.calls.length, 0);
  }
});

test('environment requires both existing password accounts and only low privilege provider key', () => {
  assert.throws(() => liveSessionEnvironment({}), LiveSessionVerificationError);
  const env = { SAFEATHOME_SUPABASE_URL: origin, SAFEATHOME_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fictional',
    SAFEATHOME_TEST_USER_A_EMAIL: config().accounts[0].email, SAFEATHOME_TEST_USER_A_PASSWORD: config().accounts[0].password,
    SAFEATHOME_TEST_USER_B_EMAIL: config().accounts[1].email, SAFEATHOME_TEST_USER_B_PASSWORD: config().accounts[1].password };
  assert.equal(liveSessionEnvironment(env).accounts.length, 2);
  assert.throws(() => liveSessionEnvironment({ ...env, SAFEATHOME_TEST_USER_B_PASSWORD: '' }), LiveSessionVerificationError);
});

test('manifest is exclusive, private, secret-free and retained across runs; origin changes fail', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'sah-session-test-'));
  try {
    const ids = await sessionFixtureIds(origin, {}, true, directory);
    const path = join(directory, 'local-artifacts/session-check.json');
    assert.equal((await stat(path)).mode & 0o777, 0o600);
    const body = JSON.parse(await readFile(path, 'utf8'));
    assert.deepEqual(Object.keys(body).sort(), ['caseAId', 'caseBId', 'projectOrigin', 'schemaVersion']);
    assert.deepEqual(await sessionFixtureIds(origin, {}, false, directory), ids);
    assert.deepEqual(await sessionFixtureIds(origin, {}, true, directory), ids);
    await rejectsSafe(sessionFixtureIds('https://other.supabase.co', {}, true, directory), 'configuration');
    assert.equal(body.projectOrigin, origin);
    await chmod(path, 0o644);
    await rejectsSafe(sessionFixtureIds(origin, {}, false, directory), 'configuration');
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('manifest missing/extra fields/symlink and partial env IDs fail; complete supplied IDs need no file', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'sah-session-test-'));
  try {
    await rejectsSafe(sessionFixtureIds(origin, {}, false, directory), 'configuration');
    await rejectsSafe(sessionFixtureIds(origin, { SAFEATHOME_TEST_CASE_A_ID: caseIds[0] }, true, directory), 'configuration');
    const env = { SAFEATHOME_TEST_CASE_A_ID: caseIds[0], SAFEATHOME_TEST_CASE_B_ID: caseIds[1] };
    await rejectsSafe(sessionFixtureIds(origin, { ...env, SAFEATHOME_TEST_CASE_A_ID: `${caseIds[0]}\n` }, false, directory), 'configuration');
    assert.deepEqual(await sessionFixtureIds(origin, env, false, directory), caseIds);
    assert.deepEqual(await sessionFixtureIds(origin, env, true, directory), caseIds);
    const path = join(directory, 'local-artifacts/session-check.json');
    await writeFile(path, JSON.stringify({ schemaVersion: '1', projectOrigin: origin, caseAId: caseIds[0], caseBId: caseIds[1], token: 'forbidden' }));
    await rejectsSafe(sessionFixtureIds(origin, {}, false, directory), 'configuration');
    await rm(path); await symlink(join(directory, 'other.json'), path);
    await rejectsSafe(sessionFixtureIds(origin, {}, true, directory), 'configuration');
  } finally { await rm(directory, { recursive: true, force: true }); }
});
