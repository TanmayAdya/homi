import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import test from 'node:test';
import { createMatchingServer } from '../src/api/http-server.ts';
import { handleListCases } from '../src/api/list-cases.ts';
import { handleReadCase } from '../src/api/read-case.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { HostedApiVerificationError, verifyHostedApi,
  type HostedApiConfiguration, type HostedVerificationOptions } from '../src/auth/hosted-api-verifier.ts';
import { LiveSessionVerificationError, verifyLiveSessions } from '../src/auth/live-session-verifier.ts';
import type { CaseSnapshot } from '../src/types.ts';

const apiOrigin = 'https://safeathome.example.invalid';
const providerOrigin = 'https://fictional.supabase.co';
const caseIds = ['11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222'] as const;
const userIds = ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'] as const;
const options = { verifyCaseDiscovery: true, warmupTimeoutMs: 2000,
  healthRequestTimeoutMs: 1000, pollIntervalMs: 1 };

function configuration(): HostedApiConfiguration {
  return { apiOrigin, auth: { projectUrl: providerOrigin, publishableKey: 'sb_publishable_fictional', timeoutMs: 1000 },
    accounts: [{ email: 'fictional-a@example.invalid', password: 'fictional-password-a' },
      { email: 'fictional-b@example.invalid', password: 'fictional-password-b' }], caseIds };
}

function snapshot(caseId: string, revision = 1): CaseSnapshot {
  return { schemaVersion: '1', caseId, revision, profile: { city: 'PRIVATE Fictional City', county: null,
    healthPlan: null, tenure: null, ageYears: null, householdSize: null, annualIncomeUsd: null,
    ownerConsentReported: null }, unresolvedFields: [], findings: [] };
}

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } });
const apiError = (code: string, status: number) => json({ schemaVersion: '1', error: { code, message: 'PRIVATE API details' } }, status);

interface Call { url: string; method: string; token: string | null; body: Record<string, unknown> }
type Intercept = (call: Call) => Response | Promise<Response> | undefined;

function setup(intercept?: Intercept) {
  const calls: Call[] = [];
  const loggedOut = new Set<string>();
  const cases = new MemoryCaseRepository([
    { userId: userIds[0], snapshot: snapshot(caseIds[0], 3) },
    { userId: userIds[0], snapshot: snapshot('legacy-\ue000', 4) },
    { userId: userIds[0], snapshot: snapshot('legacy-\u{10000}', 5) },
    { userId: userIds[1], snapshot: snapshot(caseIds[1], 2) },
  ]);
  const authenticate = async (token: string) => token === 'access-a' || token === 'access-a-new'
    ? { userId: userIds[0] } : token === 'access-b' ? { userId: userIds[1] } : null;
  const dependencies = { authenticate, cases, now: () => new Date('2026-10-17T22:00:00Z'), loadRegistry: async () => [] };
  const fetchImpl: typeof fetch = async (input, init) => {
    const headers = new Headers(init?.headers);
    const call: Call = { url: String(input), method: init?.method ?? 'GET', token: headers.get('Authorization'),
      body: init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {} };
    calls.push(call);
    assert.equal(init?.redirect, 'error'); assert.equal(init?.cache, 'no-store');
    assert.ok(init?.signal instanceof AbortSignal);
    const override = intercept?.(call);
    if (override) return await override;
    if (call.url.startsWith(`${providerOrigin}/auth/v1/`)) {
      assert.equal(headers.get('apikey'), 'sb_publishable_fictional');
      if (call.url.endsWith('/token?grant_type=password')) {
        const suffix = call.body.email === configuration().accounts[0].email ? 'a' : 'b';
        return json({ access_token: `access-${suffix}`, refresh_token: `refresh-${suffix}`, token_type: 'bearer' });
      }
      if (call.url.endsWith('/user')) return json({ id: userIds[call.token === 'Bearer access-b' ? 1 : 0], role: 'authenticated' });
      if (call.url.endsWith('/token?grant_type=refresh_token')) {
        if (call.body.refresh_token === 'refresh-a') {
          return json({ access_token: 'access-a-new', refresh_token: 'refresh-a-new', token_type: 'bearer' });
        }
        assert.equal(call.body.refresh_token, 'refresh-a-new');
        assert.ok(loggedOut.has('Bearer access-a-new'));
        return json({ error_code: 'refresh_token_not_found' }, 400);
      }
      assert.ok(call.url.endsWith('/logout?scope=local'));
      loggedOut.add(call.token!);
      return new Response(null, { status: 204 });
    }
    assert.equal(new URL(call.url).origin, apiOrigin);
    assert.equal(headers.get('apikey'), null);
    if (call.url.endsWith('/healthz')) {
      assert.equal(call.token, null);
      return call.method === 'HEAD'
        ? new Response(null, { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } })
        : json({ status: 'ok' }, 200, { 'Cache-Control': 'no-store' });
    }
    const request = { body: call.body, bearerToken: call.token?.slice('Bearer '.length) ?? null };
    const result = call.url.endsWith('/v1/list-cases') ? await handleListCases(request, dependencies)
      : call.url.endsWith('/v1/read-case') ? await handleReadCase(request, dependencies) : null;
    assert.ok(result, 'Verification must only use case listing and reloading.');
    return json(result.body, result.status, result.headers);
  };
  return { fetchImpl, calls, loggedOut, dependencies };
}

async function rejectsDiscovery(promise: Promise<unknown>, cleanupFailed = false) {
  await assert.rejects(promise, error => {
    assert.ok(error instanceof LiveSessionVerificationError);
    assert.equal(error.stage, 'case_discovery'); assert.equal(error.cleanupFailed, cleanupFailed);
    const safe = `${error.message} ${JSON.stringify(error)}`;
    for (const value of ['PRIVATE', 'access-a', 'refresh-a', caseIds[0], 'fictional-password']) assert.ok(!safe.includes(value));
    assert.equal('cause' in error, false); return true;
  });
}

test('opt-in hosted discovery uses actual handlers, pages both owners, resumes fixtures and reports aggregates only', async () => {
  const state = setup();
  const report = await verifyHostedApi(configuration(), { ...options, fetchImpl: state.fetchImpl });
  assert.deepEqual(report.caseDiscovery, { pageSize: 1, pagesRead: 4, userACaseCount: 3, userBCaseCount: 1,
    ownerFixturesFound: 2, crossOwnerFixturesExcluded: true, disjointOwnerLists: true,
    resumedCases: 2, resumedRevisionsCurrent: true, invalidTokenDenied: true });
  assert.equal(report.fixturesCreated, 0); assert.equal(report.localSignOuts, 2);
  const lists = state.calls.filter(call => call.url.endsWith('/list-cases'));
  assert.deepEqual(lists.map(call => call.body), [
    { schemaVersion: '1', limit: 1, afterCaseId: null },
    { schemaVersion: '1', limit: 1, afterCaseId: caseIds[0] },
    { schemaVersion: '1', limit: 1, afterCaseId: 'legacy-\ue000' },
    { schemaVersion: '1', limit: 1, afterCaseId: null },
    { schemaVersion: '1', limit: 1, afterCaseId: null },
  ]);
  assert.deepEqual([...state.loggedOut], ['Bearer access-a-new', 'Bearer access-b']);
  assert.ok(state.calls.every(call => !/create-case|save-case|delete-case|signup|admin|scope=global/.test(call.url)));
  for (const value of [...caseIds, ...userIds, 'PRIVATE', 'access-', 'refresh-', '@']) assert.ok(!JSON.stringify(report).includes(value));
});

test('hosted discovery also completes through the real HTTP adapter with credentials confined to the test origin', async t => {
  const auth = setup();
  const server = createMatchingServer(auth.dependencies, undefined, undefined, undefined, undefined, undefined,
    { hosted: true, caseListDependencies: auth.dependencies });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve()); server.closeAllConnections();
  }));
  const localOrigin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const fetchImpl: typeof fetch = async (input, init) => {
    const url = new URL(String(input));
    if (url.origin === providerOrigin) return auth.fetchImpl(input, init);
    assert.equal(url.origin, apiOrigin);
    assert.equal(init?.redirect, 'error');
    const response = await fetch(`${localOrigin}${url.pathname}`, init);
    return new Response(response.body, { status: response.status, headers: response.headers });
  };
  const report = await verifyHostedApi(configuration(), { ...options, fetchImpl });
  assert.equal(report.caseDiscovery?.resumedCases, 2);
  assert.equal(report.caseDiscovery?.pagesRead, 4);
  assert.equal(auth.loggedOut.size, 2);
});

test('default verification reports and requests stay unchanged when discovery is not selected', async () => {
  const state = setup();
  const report = await verifyHostedApi(configuration(), { fetchImpl: state.fetchImpl });
  assert.equal(Object.hasOwn(report, 'caseDiscovery'), false);
  assert.equal(state.calls.some(call => call.url.endsWith('/list-cases')), false);
});

test('discovery option is validated before I/O and is detached across health warmup', async () => {
  for (const value of [null, 'true', 1, {}]) {
    const state = setup();
    await assert.rejects(verifyHostedApi(configuration(), { fetchImpl: state.fetchImpl,
      verifyCaseDiscovery: value as never }), HostedApiVerificationError);
    await assert.rejects(verifyLiveSessions({ ...configuration(), createFixtures: false },
      { fetchImpl: state.fetchImpl, allowRemoteHttps: true, verifyCaseDiscovery: value as never }), LiveSessionVerificationError);
    assert.equal(state.calls.length, 0);
  }
  const mutable: HostedVerificationOptions = { verifyCaseDiscovery: true };
  const state = setup(call => {
    if (call.url.endsWith('/healthz')) mutable.verifyCaseDiscovery = false;
    return undefined;
  });
  mutable.fetchImpl = state.fetchImpl;
  assert.equal((await verifyHostedApi(configuration(), mutable)).caseDiscovery?.ownerFixturesFound, 2);
});

test('missing own fixture or another owner’s fixture in a page fails and cleans both sessions', async () => {
  for (const cases of [[], [{ caseId: caseIds[1], caseRevision: 1 }]]) {
    const state = setup(call => call.url.endsWith('/list-cases')
      ? json({ schemaVersion: '1', cases, nextAfterCaseId: null }) : undefined);
    await rejectsDiscovery(verifyHostedApi(configuration(), { ...options, fetchImpl: state.fetchImpl }));
    assert.equal(state.loggedOut.size, 2);
  }
});

test('overlapping non-fixture IDs between owners fail even when both known fixtures remain correctly isolated', async () => {
  const state = setup(call => {
    if (!call.url.endsWith('/list-cases')) return undefined;
    const own = caseIds[call.token === 'Bearer access-b' ? 1 : 0];
    const caseId = call.body.afterCaseId === null ? own : 'shared-private-case';
    return json({ schemaVersion: '1', cases: [{ caseId, caseRevision: 1 }],
      nextAfterCaseId: call.body.afterCaseId === null ? caseId : null });
  });
  await rejectsDiscovery(verifyHostedApi(configuration(), { ...options, fetchImpl: state.fetchImpl }));
  assert.equal(state.loggedOut.size, 2);
});

test('malformed, overbroad, repeated or backward pages never count as verified discovery', async () => {
  const invalid = [
    { schemaVersion: '2', cases: [], nextAfterCaseId: null },
    { schemaVersion: '1', cases: [], nextAfterCaseId: null, ownerId: 'PRIVATE' },
    { schemaVersion: '1', cases: [{ caseId: caseIds[0], caseRevision: 1, profile: 'PRIVATE' }], nextAfterCaseId: null },
    { schemaVersion: '1', cases: [{ caseId: caseIds[0], caseRevision: 0 }], nextAfterCaseId: null },
    { schemaVersion: '1', cases: [{ caseId: caseIds[0], caseRevision: 1 }], nextAfterCaseId: 'PRIVATE' },
    { schemaVersion: '1', cases: [{ caseId: caseIds[0], caseRevision: 1 }, { caseId: 'z', caseRevision: 1 }], nextAfterCaseId: null },
  ];
  for (const body of invalid) {
    const state = setup(call => call.url.endsWith('/list-cases') ? json(body) : undefined);
    await rejectsDiscovery(verifyHostedApi(configuration(), { ...options, fetchImpl: state.fetchImpl }));
    assert.equal(state.loggedOut.size, 2);
  }
  for (const secondId of [caseIds[0], '000-before-fixture']) {
    const state = setup(call => {
      if (!call.url.endsWith('/list-cases')) return undefined;
      const caseId = call.body.afterCaseId === null ? caseIds[0] : secondId;
      return json({ schemaVersion: '1', cases: [{ caseId, caseRevision: 1 }], nextAfterCaseId: caseId });
    });
    await rejectsDiscovery(verifyHostedApi(configuration(), { ...options, fetchImpl: state.fetchImpl }));
    assert.equal(state.calls.filter(call => call.url.endsWith('/list-cases')).length, 2);
    assert.equal(state.loggedOut.size, 2);
  }
});

test('a perpetually continuing list stops after 64 pages without silently accepting an incomplete traversal', async () => {
  let page = 0;
  const state = setup(call => {
    if (!call.url.endsWith('/list-cases')) return undefined;
    const caseId = page++ === 0 ? caseIds[0] : `z-${String(page).padStart(3, '0')}`;
    return json({ schemaVersion: '1', cases: [{ caseId, caseRevision: 1 }], nextAfterCaseId: caseId });
  });
  await rejectsDiscovery(verifyHostedApi(configuration(), { ...options, fetchImpl: state.fetchImpl }));
  assert.equal(page, 64); assert.equal(state.loggedOut.size, 2);
});

test('resuming a listed fixture accepts newer revisions and rejects older revisions or unavailable cases', async () => {
  for (const result of ['newer', 'older', 'unavailable'] as const) {
    let sawList = false;
    const state = setup(call => {
      if (call.url.endsWith('/list-cases')) sawList = true;
      if (sawList && call.url.endsWith('/read-case') && call.body.caseId === caseIds[0]) {
        return result === 'unavailable' ? apiError('CASE_NOT_FOUND', 404)
          : json(snapshot(caseIds[0], result === 'newer' ? 4 : 2));
      }
      return undefined;
    });
    const work = verifyHostedApi(configuration(), { ...options, fetchImpl: state.fetchImpl });
    if (result === 'newer') assert.equal((await work).caseDiscovery?.resumedRevisionsCurrent, true);
    else await rejectsDiscovery(work);
    assert.equal(state.loggedOut.size, 2);
  }
});

test('listing with an invalid token must be denied; returned data or an operational error cannot prove authorization', async () => {
  for (const response of [() => json({ schemaVersion: '1', cases: [], nextAfterCaseId: null }),
    () => apiError('UNAUTHENTICATED', 503)]) {
    const state = setup(call => call.url.endsWith('/list-cases') && call.token?.includes('invalid-session-check') ? response() : undefined);
    await rejectsDiscovery(verifyHostedApi(configuration(), { ...options, fetchImpl: state.fetchImpl }));
    assert.equal(state.loggedOut.size, 2);
  }
});

test('case-list redirects, transport failures and oversized responses fail safely without retries or credential forwarding', async () => {
  for (const response of [
    () => { throw new Error('PRIVATE transport exception access-a-new'); },
    () => json({ private: 'x'.repeat(65536) }),
    () => { const value = json({}); Object.defineProperty(value, 'url', { value: 'https://untrusted.invalid/v1/list-cases' }); return value; },
    () => new Response(null, { status: 302, headers: { Location: 'https://untrusted.invalid' } }),
  ]) {
    const state = setup(call => call.url.endsWith('/list-cases') ? response() : undefined);
    await rejectsDiscovery(verifyHostedApi(configuration(), { ...options, fetchImpl: state.fetchImpl }));
    assert.equal(state.calls.filter(call => call.url.endsWith('/list-cases')).length, 1);
    assert.ok(state.calls.every(call => [apiOrigin, providerOrigin].includes(new URL(call.url).origin)));
    assert.equal(state.loggedOut.size, 2);
  }
});

test('a discovery failure retains its stage and reports incomplete cleanup when a local signout also fails', async () => {
  const state = setup(call => {
    if (call.url.endsWith('/list-cases')) return apiError('SERVICE_UNAVAILABLE', 503);
    if (call.url.endsWith('/logout?scope=local') && call.token === 'Bearer access-a-new') return apiError('PRIVATE', 503);
    return undefined;
  });
  await rejectsDiscovery(verifyHostedApi(configuration(), { ...options, fetchImpl: state.fetchImpl }), true);
  assert.equal(state.calls.filter(call => call.url.endsWith('/logout?scope=local')).length, 2);
});
