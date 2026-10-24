import assert from 'node:assert/strict';
import test from 'node:test';
import { HostedApiVerificationError, verifyHostedApi, type HostedApiConfiguration } from '../src/auth/hosted-api-verifier.ts';
import { LiveSessionVerificationError, verifyLiveSessions } from '../src/auth/live-session-verifier.ts';
import { hostedApiEnvironment } from '../tool/verify-hosted-api.ts';

const apiOrigin = 'https://safeathome.example.invalid';
const authOrigin = 'https://fictional.supabase.co';
const caseIds = ['11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222'] as const;
const userIds = ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'];
const config = (): HostedApiConfiguration => ({ apiOrigin, auth: { projectUrl: authOrigin, publishableKey: 'sb_publishable_fictional', timeoutMs: 100 },
  accounts: [{ email: 'fixture-a@example.invalid', password: 'fictional-password-a' },
    { email: 'fixture-b@example.invalid', password: 'fictional-password-b' }], caseIds });
const options = { warmupTimeoutMs: 100, healthRequestTimeoutMs: 20, pollIntervalMs: 1 };
const json = (value: unknown, status = 200, headers: Record<string, string> = {}) => new Response(JSON.stringify(value),
  { status, headers: { 'Content-Type': 'application/json', ...headers } });
const ready = () => json({ status: 'ok' }, 200, { 'Cache-Control': 'no-store' });
const head = () => new Response(null, { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Content-Length': '15' } });
const apiError = (code: string, status: number) => json({ schemaVersion: '1', error: { code, message: 'Local fixture error.' } }, status);
function snapshot(caseId: string) {
  return { schemaVersion: '1', caseId, revision: 1, profile: { city: null, county: null, healthPlan: null, tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
}
interface Call { url: string; method: string; headers: Headers; body: Record<string, unknown> }
function transport(intercept?: (call: Call) => Response | Promise<Response> | undefined) {
  const calls: Call[] = [];
  const fetchImpl: typeof fetch = async (input, init) => {
    const call: Call = { url: String(input), method: init?.method ?? 'GET', headers: new Headers(init?.headers),
      body: init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {} };
    calls.push(call);
    assert.equal(init?.redirect, 'error'); assert.equal(init?.cache, 'no-store'); assert.ok(init?.signal instanceof AbortSignal);
    const override = intercept?.(call);
    if (override) return await override;
    if (call.url === `${apiOrigin}/healthz`) {
      assert.equal(call.headers.get('Authorization'), null); assert.equal(call.headers.get('apikey'), null);
      return call.method === 'HEAD' ? head() : ready();
    }
    const token = call.headers.get('Authorization');
    if (call.url.startsWith(authOrigin)) {
      assert.equal(call.headers.get('apikey'), 'sb_publishable_fictional');
      if (call.url.endsWith('/token?grant_type=password')) {
        const suffix = call.body.email === config().accounts[0].email ? 'a' : 'b';
        return json({ access_token: `access-${suffix}`, refresh_token: `refresh-${suffix}`, token_type: 'bearer' });
      }
      if (call.url.endsWith('/token?grant_type=refresh_token')) {
        return call.body.refresh_token === 'refresh-a'
          ? json({ access_token: 'access-a-new', refresh_token: 'refresh-a-new', token_type: 'bearer' })
          : json({ error_code: 'refresh_token_not_found' }, 400);
      }
      if (call.url.endsWith('/user')) return json({ id: userIds[token === 'Bearer access-b' ? 1 : 0], role: 'authenticated' });
      assert.ok(call.url.endsWith('/logout?scope=local'));
      return new Response(null, { status: 204 });
    }
    assert.equal(call.url, `${apiOrigin}/v1/read-case`);
    assert.equal(call.headers.get('apikey'), null);
    if (token?.includes('invalid-session-check')) return apiError('UNAUTHENTICATED', 401);
    const index = token === 'Bearer access-b' ? 1 : 0;
    return call.body.caseId === caseIds[index] ? json(snapshot(caseIds[index])) : apiError('CASE_NOT_FOUND', 404);
  };
  return { calls, fetchImpl };
}
async function rejectsHealth(promise: Promise<unknown>, stage = 'health') {
  await assert.rejects(promise, error => {
    assert.ok(error instanceof HostedApiVerificationError); assert.equal(error.stage, stage);
    assert.equal('cause' in error, false);
    assert.equal(`${error.message} ${JSON.stringify(error)}`.includes('PRIVATE_RESPONSE'), false);
    return true;
  });
}

test('hosted verification checks GET and HEAD then reuses real-session workflow without writes or database configuration', async () => {
  const mock = transport();
  const report = await verifyHostedApi(config(), { ...options, ...mock });
  assert.deepEqual(report, { status: 'passed', signedInUsers: 2, distinctVerifiedUsers: true, refreshVerified: true,
    ownerReads: 2, crossOwnerDenials: 2, invalidTokenDenied: true, localSignOuts: 2,
    latestRefreshDeniedAfterSignOut: true, fixturesCreated: 0, healthReady: true, healthHeadVerified: true, healthAttempts: 1 });
  assert.deepEqual(mock.calls.slice(0, 2).map(call => call.method), ['GET', 'HEAD']);
  assert.equal(mock.calls.filter(call => call.url.includes('/logout?scope=local')).length, 2);
  assert.ok(mock.calls.every(call => [apiOrigin, authOrigin].includes(new URL(call.url).origin)));
  assert.equal(mock.calls.some(call => /create-case|save-case|signup|admin/.test(call.url)), false);
  assert.equal(JSON.stringify(report).includes(caseIds[0]), false);
});

test('remote session origin requires explicit opt-in; loopback-only default remains unchanged', async () => {
  const mock = transport();
  await assert.rejects(verifyLiveSessions({ ...config(), createFixtures: false }, mock), LiveSessionVerificationError);
  assert.equal(mock.calls.length, 0);
  assert.equal((await verifyLiveSessions({ ...config(), createFixtures: false }, { ...mock, allowRemoteHttps: true })).status, 'passed');
});

test('cold-start warmup retries only unauthenticated GETs, then performs one HEAD and no mutation retries', async () => {
  let attempts = 0;
  const mock = transport(call => {
    if (call.url.endsWith('/healthz') && call.method === 'GET' && ++attempts <= 2) {
      return new Response('Cold start proxy response.', { status: attempts === 1 ? 503 : 502 });
    }
    return undefined;
  });
  const report = await verifyHostedApi(config(), { ...options, ...mock });
  assert.equal(report.healthAttempts, 3);
  assert.deepEqual(mock.calls.slice(0, 4).map(call => call.method), ['GET', 'GET', 'GET', 'HEAD']);
  assert.ok(mock.calls.slice(0, 4).every(call => !call.headers.has('Authorization') && !call.headers.has('apikey')));
});

test('canonical HTTPS origin rejects credentials, paths, ports, IPs, local names and URL normalization tricks before I/O', async () => {
  const invalid = ['', 'http://example.invalid', `${apiOrigin}/`, `${apiOrigin}/path`, `${apiOrigin}?q=1`, `${apiOrigin}#hash`,
    'https://user:PRIVATE_RESPONSE@example.invalid', 'https://127.0.0.1', 'https://10.0.0.1', 'https://192.168.1.1',
    'https://[::1]', 'https://[2001:db8::1]', 'https://2130706433', 'https://0x7f000001', 'https://localhost',
    'https://api.localhost', 'https://api.local', 'https://example.invalid:8443', 'https://example.invalid:443',
    'https://example.invalid.', 'https://EXAMPLE.invalid', 'https://example.invalid\n', 'https://api_example.invalid'];
  for (const apiOrigin of invalid) {
    const mock = transport();
    await rejectsHealth(verifyHostedApi({ ...config(), apiOrigin }, { ...options, ...mock }), 'configuration');
    assert.equal(mock.calls.length, 0);
  }
});

test('malformed health, omitted no-store, extra fields, body bounds and unexpected HTTP statuses prevent login', async () => {
  const responses = [
    () => json({ status: 'ok' }),
    () => json({ status: 'ok', private: 'PRIVATE_RESPONSE' }, 200, { 'Cache-Control': 'no-store' }),
    () => json({ status: 'not-ready' }, 200, { 'Cache-Control': 'no-store' }),
    () => json({ status: 'ok' }, 404, { 'Cache-Control': 'no-store' }),
    () => new Response('PRIVATE_RESPONSE', { headers: { 'Cache-Control': 'no-store', 'Content-Type': 'text/html' } }),
    () => json({ status: 'ok' }, 200, { 'Cache-Control': 'no-store', 'Content-Length': '1025' }),
    () => json({ status: 'ok', excess: 'x'.repeat(1024) }, 200, { 'Cache-Control': 'no-store' }),
    () => new Response(Uint8Array.from([0xff]), { headers: { 'Cache-Control': 'no-store', 'Content-Type': 'application/json' } }),
  ];
  for (const response of responses) {
    const mock = transport(() => response());
    await rejectsHealth(verifyHostedApi(config(), { ...options, ...mock }));
    assert.equal(mock.calls.length, 1);
    assert.equal(mock.calls[0].headers.has('Authorization'), false);
  }
});

test('redirect responses and changed response URL never reach login or forward credentials', async () => {
  for (const response of [
    () => new Response(null, { status: 302, headers: { Location: 'https://untrusted.invalid' } }),
    () => { const value = ready(); Object.defineProperty(value, 'redirected', { value: true }); return value; },
    () => { const value = ready(); Object.defineProperty(value, 'url', { value: 'https://untrusted.invalid/healthz' }); return value; },
  ]) {
    const mock = transport(() => response());
    await rejectsHealth(verifyHostedApi(config(), { ...options, ...mock }));
    assert.equal(mock.calls.length, 1);
  }
});

test('HEAD must independently be200/no-store/json with no body; failed HEAD is not retried', async () => {
  for (const response of [() => new Response(null, { status: 503 }), () => new Response(null), () => ready()]) {
    const mock = transport(call => call.method === 'HEAD' ? response() : undefined);
    await rejectsHealth(verifyHostedApi(config(), { ...options, ...mock }));
    assert.deepEqual(mock.calls.map(call => call.method), ['GET', 'HEAD']);
  }
});

test('health warmup has a total deadline and never signs in while unavailable', async () => {
  const mock = transport(() => { throw new Error('PRIVATE_RESPONSE'); });
  await rejectsHealth(verifyHostedApi(config(), { ...mock, warmupTimeoutMs: 12, healthRequestTimeoutMs: 3, pollIntervalMs: 1 }));
  assert.ok(mock.calls.length >= 1);
  assert.ok(mock.calls.every(call => call.url.endsWith('/healthz') && call.method === 'GET'));
});

test('stalled health body is cancelled, and a late response after timeout is also cancelled', async () => {
  let bodyCancelled = false;
  const stalled = transport(() => new Response(new ReadableStream({ cancel() { bodyCancelled = true; } }),
    { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } }));
  await rejectsHealth(verifyHostedApi(config(), { ...stalled, warmupTimeoutMs: 10, healthRequestTimeoutMs: 10, pollIntervalMs: 1 }));
  assert.equal(bodyCancelled, true);
  let release: ((response: Response) => void) | undefined;
  let lateCancelled = false;
  const late = transport(() => new Promise<Response>(resolve => { release = resolve; }));
  await rejectsHealth(verifyHostedApi(config(), { ...late, warmupTimeoutMs: 10, healthRequestTimeoutMs: 10, pollIntervalMs: 1 }));
  assert.ok(release);
  release(new Response(new ReadableStream({ cancel() { lateCancelled = true; } }), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } }));
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(lateCancelled, true);
});

test('configuration is detached across warmup; caller mutation cannot redirect authenticated requests', async () => {
  const value = config();
  const mock = transport(call => {
    if (call.url.endsWith('/healthz')) {
      value.apiOrigin = 'https://untrusted.invalid';
      value.auth.projectUrl = 'https://untrusted.invalid';
      value.auth.publishableKey = 'sb_publishable_untrusted';
      value.accounts[0].email = 'changed@example.invalid';
    }
    return undefined;
  });
  assert.equal((await verifyHostedApi(value, { ...options, ...mock })).status, 'passed');
  assert.equal(mock.calls.some(call => call.url.includes('untrusted')), false);
  assert.equal(mock.calls.find(call => call.body.email)?.body.email, 'fixture-a@example.invalid');
});

test('remote API redirect/missing fixture fails the shared session checks, still cleans sessions and never creates records', async () => {
  for (const redirect of [true, false]) {
    const mock = transport(call => {
      if (!call.url.endsWith('/v1/read-case')) return undefined;
      if (!redirect) return apiError('CASE_NOT_FOUND', 404);
      const value = json(snapshot(caseIds[0])); Object.defineProperty(value, 'url', { value: 'https://untrusted.invalid/v1/read-case' }); return value;
    });
    await assert.rejects(verifyHostedApi(config(), { ...options, ...mock }), error => {
      assert.ok(error instanceof LiveSessionVerificationError); assert.equal(error.stage, 'fixture_a'); return true;
    });
    assert.equal(mock.calls.filter(call => call.url.includes('/logout?scope=local')).length, 2);
    assert.equal(mock.calls.some(call => call.url.includes('create-case') || call.url.includes('untrusted')), false);
  }
});

test('hosted environment needs only origin, auth/test credentials and existing UUIDs; no DB or admin configuration', async () => {
  const env = { SAFEATHOME_API_ORIGIN: apiOrigin, SAFEATHOME_SUPABASE_URL: authOrigin,
    SAFEATHOME_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fictional',
    SAFEATHOME_TEST_USER_A_EMAIL: config().accounts[0].email, SAFEATHOME_TEST_USER_A_PASSWORD: config().accounts[0].password,
    SAFEATHOME_TEST_USER_B_EMAIL: config().accounts[1].email, SAFEATHOME_TEST_USER_B_PASSWORD: config().accounts[1].password,
    SAFEATHOME_TEST_CASE_A_ID: caseIds[0], SAFEATHOME_TEST_CASE_B_ID: caseIds[1] };
  const expected = config();
  delete expected.auth.timeoutMs;
  assert.deepEqual(await hostedApiEnvironment(env), expected);
  await rejectsHealth(hostedApiEnvironment({ ...env, NODE_TLS_REJECT_UNAUTHORIZED: '0' }), 'configuration');
  await rejectsHealth(hostedApiEnvironment({ ...env, SAFEATHOME_API_ORIGIN: '' }), 'configuration');
  await rejectsHealth(hostedApiEnvironment({ ...env, SAFEATHOME_TEST_CASE_B_ID: undefined }), 'configuration');
});

test('invalid timeout limits, IDs and write intent fail before health requests', async () => {
  for (const altered of [{ warmupTimeoutMs: 90_001 }, { healthRequestTimeoutMs: 10_001 }, { pollIntervalMs: 0 }]) {
    const mock = transport();
    await rejectsHealth(verifyHostedApi(config(), { ...options, ...mock, ...altered }), 'configuration');
    assert.equal(mock.calls.length, 0);
  }
  for (const value of [{ ...config(), caseIds: [caseIds[0], caseIds[0]] }, { ...config(), createFixtures: true }]) {
    const mock = transport();
    await rejectsHealth(verifyHostedApi(value as HostedApiConfiguration, { ...options, ...mock }), 'configuration');
    assert.equal(mock.calls.length, 0);
  }
});
