import assert from 'node:assert/strict';
import { setImmediate } from 'node:timers/promises';
import test from 'node:test';
import {
  AuthServiceUnavailableError,
  createSupabaseAuthenticator,
  MAX_AUTH_RESPONSE_BYTES,
  type SupabaseAuthConfig,
} from '../src/auth/supabase-auth.ts';

const config: SupabaseAuthConfig = {
  projectUrl: 'https://fictional-project.supabase.co',
  publishableKey: 'sb_publishable_fictional_test_key',
};
const userId = '8ef3868f-42f4-428e-8196-921b2bbfa800';
const otherUserId = 'c6cad965-b6a2-4303-81fc-cd984e920814';
const token = 'fictional.opaque.token';
const user = { id: userId, role: 'authenticated' };
const json = (value: unknown, status = 200, headers: Record<string, string> = {}) => new Response(
  JSON.stringify(value), { status, headers: { 'content-type': 'application/json', ...headers } },
);
const safeError = (error: unknown): boolean => {
  assert.ok(error instanceof AuthServiceUnavailableError);
  assert.equal(error.message, 'Authentication is temporarily unavailable.');
  assert.equal(error.cause, undefined);
  assert.equal(JSON.stringify(error).includes(token), false);
  return true;
};

test('fixed GET endpoint verifies with the provider and returns only its user ID', async () => {
  let calls = 0;
  const authenticate = createSupabaseAuthenticator(config, async (input, init) => {
    calls++;
    assert.equal(input, `${config.projectUrl}/auth/v1/user`);
    assert.equal(init?.method, 'GET');
    assert.equal(init?.redirect, 'error');
    assert.equal(init?.cache, 'no-store');
    assert.equal(init?.body, undefined);
    const headers = new Headers(init?.headers);
    assert.equal(headers.get('authorization'), `Bearer ${token}`);
    assert.equal(headers.get('apikey'), config.publishableKey);
    assert.equal(headers.get('accept'), 'application/json');
    assert.ok(init?.signal instanceof AbortSignal);
    return json({ ...user, phone: '+15550100001', user_metadata: { ownerId: otherUserId }, email: null });
  });
  const result = await authenticate(token);
  assert.deepEqual(result, { userId });
  assert.ok(Object.isFrozen(result));
  assert.equal(calls, 1);
});

test('each call uses its own supplied token and fresh server state, without a JWT/cache shortcut', async () => {
  const tokens: string[] = [];
  const authenticate = createSupabaseAuthenticator(config, async (_input, init) => {
    tokens.push(new Headers(init?.headers).get('authorization')!);
    return tokens.length === 1 ? json(user) : json({ message: 'provider-private-detail' }, 401);
  });
  assert.deepEqual(await authenticate('not-a-JWT'), { userId });
  assert.equal(await authenticate('fresh-token'), null);
  assert.deepEqual(tokens, ['Bearer not-a-JWT', 'Bearer fresh-token']);
});

test('config is copied at creation, supports a root slash, and fixes the credential destination', async () => {
  const mutable = { ...config, projectUrl: `${config.projectUrl}/`, timeoutMs: 100 };
  const authenticate = createSupabaseAuthenticator(mutable, async (input, init) => {
    assert.equal(input, `${config.projectUrl}/auth/v1/user`);
    assert.equal(new Headers(init?.headers).get('apikey'), config.publishableKey);
    return json(user);
  });
  mutable.projectUrl = 'https://unrelated.example';
  mutable.publishableKey = 'sb_secret_do_not_use';
  mutable.timeoutMs = 0;
  assert.deepEqual(await authenticate(token), { userId });
});

test('invalid endpoints, elevated/legacy keys, and unbounded deadlines fail before I/O', () => {
  let calls = 0;
  const fetchImpl: typeof fetch = async () => { calls++; return json(user); };
  const invalid: SupabaseAuthConfig[] = [
    ...['http://example.test', 'https://example.test/auth/v1/user', 'https://example.test/?x=1',
      'https://example.test/?', 'https://example.test/#', 'https://example.test/#fragment',
      'https://user:password@example.test', 'https://@example.test', 'https://example.test\\path',
      'https://example.test/../', 'https://example.test\n', ' https://example.test', 'not-a-url',
    ].map(projectUrl => ({ ...config, projectUrl })),
    ...['sb_secret_private', 'legacy.jwt.key', 'sb_publishable_', 'sb_publishable_secret\n',
      `sb_publishable_${'x'.repeat(512)}`,
    ].map(publishableKey => ({ ...config, publishableKey })),
    ...[0, -1, 10_001, 1.5, NaN, Infinity].map(timeoutMs => ({ ...config, timeoutMs })),
  ];
  for (const invalidConfig of invalid) {
    assert.throws(() => createSupabaseAuthenticator(invalidConfig, fetchImpl), {
      name: 'TypeError', message: 'Invalid Supabase authentication configuration.',
    });
  }
  assert.equal(calls, 0);
});

test('invalid bearer syntax or size is declined before network access', async () => {
  let calls = 0;
  const authenticate = createSupabaseAuthenticator(config, async () => { calls++; return json(user); });
  for (const invalid of ['', 'has space', 'Bearer token', 'token\n', 'token\r\n',
    'token:header', 'token=middle', 'x'.repeat(4097), null, 42]) {
    assert.equal(await authenticate(invalid as string), null);
  }
  assert.equal(calls, 0);
  assert.deepEqual(await authenticate('x'.repeat(4096)), { userId });
});

test('401 and 403 decline the user without reading or exposing provider error bodies', async () => {
  for (const status of [401, 403]) {
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({ cancel() { cancelled = true; } });
    const authenticate = createSupabaseAuthenticator(config, async () => new Response(body, { status }));
    assert.equal(await authenticate(token), null);
    assert.equal(cancelled, true);
  }
});

test('service failures, unexpected statuses, and malformed bodies expose only a local error', async () => {
  const failures: Array<() => Promise<Response>> = [
    async () => { throw new Error(`private provider token=${token}`); },
    ...[400, 404, 429, 500, 503].map(status => async () => json({ token, private: 'diagnostic' }, status)),
    async () => new Response('<html>gateway diagnostic</html>', { status: 200 }),
    async () => new Response('{bad json', { headers: { 'content-type': 'application/json' } }),
    async () => new Response(null, { headers: { 'content-type': 'application/json' } }),
    async () => json(null),
    async () => json([user]),
  ];
  for (const fetchImpl of failures) {
    await assert.rejects(createSupabaseAuthenticator(config, fetchImpl)(token), safeError);
  }
});

test('UUID and role response boundaries reject malformed identities and decline other roles', async () => {
  for (const value of [{ role: 'authenticated' }, { ...user, id: 'user-1' },
    { ...user, id: `${userId}\n` }, { ...user, id: '00000000-0000-0000-0000-000000000000' },
    { ...user, id: userId.toUpperCase() }, { id: userId }, { ...user, role: 42 }]) {
    await assert.rejects(createSupabaseAuthenticator(config, async () => json(value))(token), safeError);
  }
  for (const role of ['anon', 'service_role', 'custom_role', '']) {
    assert.equal(await createSupabaseAuthenticator(config, async () => json({ ...user, role }))(token), null);
  }
});

test('redirects and a changed final response URL cannot authenticate or trigger another request', async () => {
  for (const status of [301, 302, 303, 307, 308]) {
    let calls = 0;
    const authenticate = createSupabaseAuthenticator(config, async (_input, init) => {
      calls++;
      assert.equal(init?.redirect, 'error');
      return new Response(null, { status, headers: { location: 'https://unrelated.example/auth/v1/user' } });
    });
    await assert.rejects(authenticate(token), safeError);
    assert.equal(calls, 1);
  }
  for (const property of [{ redirected: true }, { url: 'https://unrelated.example/auth/v1/user' }]) {
    const response = json(user);
    for (const [key, value] of Object.entries(property)) Object.defineProperty(response, key, { value });
    await assert.rejects(createSupabaseAuthenticator(config, async () => response)(token), safeError);
  }
});

test('response content length and streamed bytes are independently bounded and cancelled', async () => {
  for (const length of [String(MAX_AUTH_RESPONSE_BYTES + 1), '-1', 'not-a-number']) {
    let cancelled = false;
    const response = new Response(new ReadableStream<Uint8Array>({ cancel() { cancelled = true; } }), {
      headers: { 'content-type': 'application/json', 'content-length': length },
    });
    await assert.rejects(createSupabaseAuthenticator(config, async () => response)(token), safeError);
    assert.equal(cancelled, true);
  }
  let cancelled = false;
  const response = new Response(new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(new Uint8Array(MAX_AUTH_RESPONSE_BYTES + 1)); },
    cancel() { cancelled = true; },
  }), { headers: { 'content-type': 'application/json', 'content-length': '1' } });
  await assert.rejects(createSupabaseAuthenticator(config, async () => response)(token), safeError);
  assert.equal(cancelled, true);
});

test('strict UTF-8 accepts split multibyte text and rejects replacement decoding', async () => {
  const bytes = new TextEncoder().encode(JSON.stringify({ ...user, user_metadata: { name: 'Fictional José' } }));
  const split = bytes.indexOf(0xc3) + 1;
  const response = new Response(new ReadableStream<Uint8Array>({ start(controller) {
    controller.enqueue(bytes.subarray(0, split));
    controller.enqueue(bytes.subarray(split));
    controller.close();
  } }), { headers: { 'content-type': 'application/json; charset=utf-8' } });
  assert.deepEqual(await createSupabaseAuthenticator(config, async () => response)(token), { userId });
  const bad = new Uint8Array(bytes);
  bad[split] = 0x28;
  await assert.rejects(createSupabaseAuthenticator(config, async () => new Response(bad, {
    headers: { 'content-type': 'application/json' },
  }))(token), safeError);
});

test('total deadline aborts a stalled fetch and discards/cancels its late success', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let resolve!: (response: Response) => void;
  let signal: AbortSignal | undefined;
  const pending = new Promise<Response>(accept => { resolve = accept; });
  const authenticate = createSupabaseAuthenticator(config, async (_input, init) => {
    signal = init?.signal as AbortSignal;
    return pending;
  });
  const rejected = assert.rejects(authenticate(token), safeError);
  t.mock.timers.tick(5000);
  await rejected;
  assert.equal(signal?.aborted, true);
  let cancelled = false;
  resolve(new Response(new ReadableStream<Uint8Array>({ cancel() { cancelled = true; } }), {
    headers: { 'content-type': 'application/json' },
  }));
  await setImmediate();
  assert.equal(cancelled, true);
});

test('one total deadline also bounds response bodies, even when cancellation never resolves', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let cancelled = false;
  let signal: AbortSignal | undefined;
  const response = new Response(new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(new TextEncoder().encode('{')); },
    cancel() { cancelled = true; return new Promise<void>(() => {}); },
  }), { headers: { 'content-type': 'application/json' } });
  const authenticate = createSupabaseAuthenticator({ ...config, timeoutMs: 50 }, async (_input, init) => {
    signal = init?.signal as AbortSignal;
    return response;
  });
  const rejected = assert.rejects(authenticate(token), safeError);
  await setImmediate();
  t.mock.timers.tick(50);
  await rejected;
  assert.equal(signal?.aborted, true);
  assert.equal(cancelled, true);
});

test('concurrent calls keep user identities and cancellation independent', async () => {
  const authenticate = createSupabaseAuthenticator(config, async (_input, init) => {
    const first = new Headers(init?.headers).get('authorization') === 'Bearer first';
    await setImmediate();
    assert.equal(init?.signal?.aborted, false);
    return json({ ...user, id: first ? userId : otherUserId });
  });
  assert.deepEqual(await Promise.all([authenticate('first'), authenticate('second')]), [{ userId }, { userId: otherUserId }]);
});
