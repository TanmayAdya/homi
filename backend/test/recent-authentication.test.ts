import assert from 'node:assert/strict';
import test from 'node:test';
import { createRecentSupabaseAuthenticator } from '../src/auth/recent-authentication.ts';
import { RecentAuthenticationRequiredError } from '../src/lifecycle/types.ts';

const userId = 'a0000000-0000-4000-8000-000000000001';
const config = { projectUrl: 'https://fictional.supabase.co', publishableKey: 'sb_publishable_fictional' };
const seconds = 1800000000;
const claims = () => ({ sub: userId, iss: `${config.projectUrl}/auth/v1`, aud: 'authenticated', role: 'authenticated',
  exp: seconds + 3600, iat: seconds, amr: [{ method: 'password', timestamp: seconds }] });
const jwt = (payload: unknown) => `e30.${Buffer.from(JSON.stringify(payload)).toString('base64url')}.c2lnbmF0dXJl`;
const provider: typeof fetch = async () => Response.json({ id: userId, role: 'authenticated' });
const authenticate = createRecentSupabaseAuthenticator(config, provider, () => seconds * 1000);

test('recent password/TOTP requires successful provider validation of the exact token first', async () => {
  for (const method of ['password', 'totp']) {
    assert.deepEqual(await authenticate(jwt({ ...claims(), amr: [{ method, timestamp: seconds - 600 }] })), { userId });
  }
  let calls = 0;
  const rejected = createRecentSupabaseAuthenticator(config, async (url, options) => {
    calls++; assert.equal(url, `${config.projectUrl}/auth/v1/user`);
    assert.equal(new Headers(options?.headers).get('authorization'), `Bearer ${jwt(claims())}`);
    return Response.json({}, { status: 401 });
  }, () => seconds * 1000);
  assert.equal(await rejected(jwt(claims())), null); assert.equal(calls, 1);
});

test('token refresh, old challenges and absent or malformed method claims cannot authorize deletion', async () => {
  for (const amr of [undefined, [], [{ method: 'token_refresh', timestamp: seconds }],
    [{ method: 'password', timestamp: seconds - 601 }, { method: 'token_refresh', timestamp: seconds }],
    [{ method: 'password', timestamp: seconds + 31 }], [{ method: 'password', timestamp: String(seconds) }],
    [{ method: 'anonymous', timestamp: seconds }], [{ method: ['password'], timestamp: seconds }],
    [{ method: ['totp'], timestamp: seconds }], [{ method: {}, timestamp: seconds }]]) {
    await assert.rejects(authenticate(jwt({ ...claims(), amr })), RecentAuthenticationRequiredError);
  }
});

test('verified identity/issuer/audience and current token lifetime must agree with decoded claims', async () => {
  for (const change of [{ sub: 'b0000000-0000-4000-8000-000000000002' }, { iss: 'https://other.example/auth/v1' },
    { aud: 'service_role' }, { role: 'service_role' }, { exp: seconds }, { exp: 'future' }]) {
    await assert.rejects(authenticate(jwt({ ...claims(), ...change })), RecentAuthenticationRequiredError);
  }
  for (const value of ['opaque-provider-token', 'e30.bm90LWpzb24.c2ln', `${jwt(claims())}.extra`]) {
    await assert.rejects(authenticate(value), RecentAuthenticationRequiredError);
  }
});

test('authentication age is evaluated after provider I/O and errors contain no token claims', async () => {
  let now = seconds * 1000;
  const delayed = createRecentSupabaseAuthenticator(config, async () => {
    now += 601000; return Response.json({ id: userId, role: 'authenticated' });
  }, () => now);
  await assert.rejects(delayed(jwt(claims())), error => {
    assert.ok(error instanceof RecentAuthenticationRequiredError);
    assert.equal('cause' in error, false); assert.equal(error.message.includes(userId), false); return true;
  });
});
