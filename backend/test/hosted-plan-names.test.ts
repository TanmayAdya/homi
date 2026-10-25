import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { AddressInfo } from 'node:net';
import test, { type TestContext } from 'node:test';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { createSupabaseAuthenticator } from '../src/auth/supabase-auth.ts';
import type { LifecycleRepository } from '../src/lifecycle/types.ts';
import type { CaseListQuery } from '../src/cases/discovery.ts';
import { draft } from './postgres/fixtures.ts';
import { createPlanNameCheckJournal, verifyHostedPlanNames, PlanNameCheckError,
  type PlanNameCheckConfiguration, type PlanNameCheckEvent } from '../tool/verify-hosted-plan-names.ts';

const apiOrigin = 'https://beta.example.invalid', projectOrigin = 'https://fictional.supabase.co';
const users = ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'];
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status,
  headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
interface Call { path: string; token: string | null; body: Record<string, any> }
async function setup(t: TestContext, transform?: (call: Call, response: Response) => Promise<Response>) {
  const configuration: PlanNameCheckConfiguration = { apiOrigin, auth: { projectUrl: projectOrigin,
    publishableKey: 'sb_publishable_fictional', timeoutMs: 1000 }, accounts: [
      { email: 'fictional-a@example.invalid', password: 'fictional-password-a' },
      { email: 'fictional-b@example.invalid', password: 'fictional-password-b' }],
    caseIds: [randomUUID(), randomUUID()], newCaseId: randomUUID(), runId: randomUUID() };
  const existing = configuration.caseIds.map((id, index) => ({ userId: users[index], snapshot: { ...draft(id), revision: 1 } }));
  const raw = new MemoryCaseRepository(existing), removed = new Set<string>(), deletions: string[] = [];
  const cases = new Proxy(raw, { get(target, property) {
    if (property === 'loadForUser') return async (owner: string, id: string) => removed.has(id) ? null : target.loadForUser(owner, id);
    if (property === 'readPlanNameForUser') return async (owner: string, id: string) => removed.has(id) ? null : target.readPlanNameForUser(owner, id);
    if (property === 'listNamedForUser') return async (owner: string, query: CaseListQuery) => {
      const page = await target.listNamedForUser(owner, query); return { ...page, cases: page.cases.filter(item => !removed.has(item.caseId)) };
    };
    const value = Reflect.get(target, property, target); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const lifecycle: LifecycleRepository = {
    isAccountClosed: async () => false,
    async deleteCaseIfCurrent(input) {
      assert.equal(input.userId, users[0]); assert.equal(input.caseId, configuration.newCaseId);
      assert.equal(input.revision, 1); assert.equal(input.expectedCatalogRevision, 0);
      assert.ok(!configuration.caseIds.includes(input.caseId)); assert.ok(await cases.loadForUser(input.userId, input.caseId));
      deletions.push(input.caseId); removed.add(input.caseId); return { status: 'deleted' };
    },
    prepareAccountDeletion: async () => { throw new Error('Account deletion forbidden.'); },
    confirmAccountDeletion: async () => { throw new Error('Account deletion forbidden.'); },
    readAccountDeletionReceipt: async () => { throw new Error('Account deletion forbidden.'); },
  };
  const calls: Call[] = [], events: PlanNameCheckEvent[] = [], owners = new Map<string, string>();
  let localOrigin = '', signIns = 0;
  const fetchImpl: typeof fetch = async (input, init) => {
    const url = new URL(String(input)), headers = new Headers(init?.headers);
    const call = { path: `${url.pathname}${url.search}`, token: headers.get('Authorization'),
      body: init?.body ? JSON.parse(String(init.body)) as Record<string, any> : {} }; calls.push(call);
    assert.equal(init?.redirect, 'error'); assert.equal(init?.cache, 'no-store');
    let response: Response;
    if (url.origin === projectOrigin) {
      assert.equal(headers.get('apikey'), 'sb_publishable_fictional');
      if (call.path.endsWith('/token?grant_type=password')) {
        const token = `access-${signIns++}`;
        owners.set(token, users[call.body.email === configuration.accounts[0].email ? 0 : 1]);
        response = json({ access_token: token, token_type: 'bearer' });
      } else if (call.path.endsWith('/user')) {
        const owner = owners.get(call.token?.slice(7) ?? ''); response = owner ? json({ id: owner, role: 'authenticated' }) : json({}, 401);
      } else {
        assert.equal(call.path, '/auth/v1/logout?scope=local'); response = new Response(null, { status: 204 });
      }
    } else {
      assert.equal(url.origin, apiOrigin); assert.equal(headers.get('apikey'), null);
      const actual = await fetch(`${localOrigin}${url.pathname}`, init);
      response = new Response(actual.body, { status: actual.status, headers: actual.headers });
    }
    return transform ? transform(call, response) : response;
  };
  const authenticate = createSupabaseAuthenticator(configuration.auth, fetchImpl);
  const deps = { cases, authenticate, now: () => new Date(), loadRegistry: async () => [], loadFormTemplate: async () => null };
  const server = createMatchingServer(deps, deps, deps, deps, deps, deps,
    { planNameDependencies: deps, lifecycleDependencies: { lifecycle, authenticate, authenticateForDeletion: authenticate } });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve)); localOrigin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  t.after(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  return { configuration, calls, events, raw, cases, existing, deletions,
    options: { fetchImpl, testNoPacing: true, journal: async (event: Readonly<PlanNameCheckEvent>) => { events.push(structuredClone(event)); } } };
}
async function failure(work: Promise<unknown>, stage: string, uncertain = false, cleanup = false, sessions = false) {
  await assert.rejects(work, error => {
    assert.ok(error instanceof PlanNameCheckError); assert.equal(error.stage, stage);
    assert.equal(error.mutationUncertain, uncertain); assert.equal(error.cleanupPending, cleanup); assert.equal(error.sessionCleanupFailed, sessions);
    for (const value of ['PRIVATE_RESPONSE', 'access-', 'fictional-password', '@']) assert.equal(error.message.includes(value), false);
    assert.equal('cause' in error, false); return true;
  });
}

test('two owner sessions and one outsider traverse real HTTP CAS, list, reset and only temporary-case deletion', async t => {
  const state = await setup(t), report = await verifyHostedPlanNames(state.configuration, state.options);
  assert.equal(report.status, 'passed'); assert.equal(report.ownerSessions, 2); assert.equal(report.outsiderSessions, 1);
  assert.equal(report.localSignOuts, 3); assert.equal(report.caseDeleted, true); assert.ok(report.requests <= 60);
  assert.deepEqual(state.deletions, [state.configuration.newCaseId]);
  assert.equal(state.calls.filter(c => c.path === '/v1/create-case').length, 1);
  assert.equal(state.calls.filter(c => c.path.endsWith('/logout?scope=local')).length, 3);
  for (const fixture of state.existing) assert.deepEqual(await state.cases.loadForUser(fixture.userId, fixture.snapshot.caseId), fixture.snapshot);
  assert.equal(await state.cases.readPlanNameForUser(users[0], state.configuration.newCaseId), null);
  const names = state.calls.filter(c => c.path === '/v2/save-plan-name');
  assert.deepEqual(names[0].body, names[1].body); assert.notEqual(names[0].token, names[1].token);
  assert.equal(state.events.at(-1)?.stage, 'complete');
  for (const secret of [...users, 'access-', 'fictional-password', 'Fictional Cedar', 'Fictional Maple', '@']) {
    assert.equal(JSON.stringify(state.events).includes(secret), false); assert.equal(JSON.stringify(report).includes(secret), false);
  }
  assert.equal(JSON.stringify(report).includes(state.configuration.newCaseId), false);
});

test('invalid configuration fails before any transport or journal activity', async t => {
  const state = await setup(t);
  await failure(verifyHostedPlanNames({ ...state.configuration, newCaseId: state.configuration.caseIds[0] }, state.options), 'configuration');
  assert.equal(state.calls.length, 0); assert.equal(state.events.length, 0);
});

test('an existing temporary ID is never replaced or deleted', async t => {
  let seenReads = 0;
  const state = await setup(t, async (call, response) => {
    if (call.path === '/v1/read-case' && ++seenReads === 5) return json({ ...draft(call.body.caseId), revision: 1 });
    return response;
  });
  await failure(verifyHostedPlanNames(state.configuration, state.options), 'existing_fixture_guards');
  assert.equal(state.calls.some(c => c.path === '/v1/create-case'), false); assert.deepEqual(state.deletions, []);
});

test('lost create acknowledgement retains only the journaled temporary case without retry or deletion', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.path === '/v1/create-case') { await response.body?.cancel(); throw new Error('PRIVATE_RESPONSE'); } return response;
  });
  await failure(verifyHostedPlanNames(state.configuration, state.options), 'create_case', true, true);
  assert.ok(await state.raw.loadForUser(users[0], state.configuration.newCaseId)); assert.deepEqual(state.deletions, []);
  assert.equal(state.calls.filter(c => c.path === '/v1/create-case').length, 1);
  assert.equal(state.calls.filter(c => c.path.endsWith('/logout?scope=local')).length, 3);
});

test('lost name acknowledgement stops before any automatic retry or cleanup', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.path === '/v2/save-plan-name') { await response.body?.cancel(); throw new Error('PRIVATE_RESPONSE access-0'); } return response;
  });
  await failure(verifyHostedPlanNames(state.configuration, state.options), 'first_name', true, true);
  assert.equal(state.calls.filter(c => c.path === '/v2/save-plan-name').length, 1); assert.deepEqual(state.deletions, []);
  assert.equal((await state.raw.readPlanNameForUser(users[0], state.configuration.newCaseId))?.nameRevision, 1);
});

test('intent journal failure stops before the first mutating request', async t => {
  const state = await setup(t);
  await failure(verifyHostedPlanNames(state.configuration, { ...state.options, journal: async event => {
    if (event.stage === 'create_case' && event.state === 'intent') throw new Error('PRIVATE_RESPONSE'); await state.options.journal(event);
  } }), 'create_case');
  assert.equal(state.calls.some(c => c.path === '/v1/create-case'), false); assert.deepEqual(state.deletions, []);
});

test('another device changing the name before cleanup prevents deletion', async t => {
  let resetReads = 0;
  const state = await setup(t, async (call, response) => {
    if (call.path === '/v2/read-plan-name' && response.status === 200) {
      const value = await response.json();
      if (value.nameRevision === 3 && ++resetReads === 2) return json({ ...value, name: 'Concurrent fictional edit', nameRevision: 4, lastMutationId: 'other-device' });
      return json(value);
    } return response;
  });
  await failure(verifyHostedPlanNames(state.configuration, state.options), 'cleanup_guards', false, true);
  assert.deepEqual(state.deletions, []);
});

test('changed case content before cleanup prevents deletion even at the same reported revision', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.path === '/v1/read-case' && response.status === 200) {
      const value = await response.json();
      if (value.profile.city === null) value.profile.city = 'Concurrent fictional city'; return json(value);
    } return response;
  });
  await failure(verifyHostedPlanNames(state.configuration, state.options), 'cleanup_guards', false, true);
  assert.deepEqual(state.deletions, []);
});

test('a leaked outsider name response fails isolation and retains the temporary case', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.path === '/v2/read-plan-name' && call.token === 'Bearer access-2') return json({ schemaVersion: '2', caseId: call.body.caseId,
      name: 'PRIVATE_RESPONSE', nameRevision: 2, lastMutationId: 'leaked' }); return response;
  });
  await failure(verifyHostedPlanNames(state.configuration, state.options), 'owner_isolation', false, true);
  assert.deepEqual(state.deletions, []);
});

test('a parsed login token is locally revoked even when the login envelope fails', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.path.endsWith('/token?grant_type=password')) return json({ access_token: 'access-0', token_type: 'unexpected' }); return response;
  });
  await failure(verifyHostedPlanNames(state.configuration, state.options), 'sign_in');
  const logouts = state.calls.filter(c => c.path.endsWith('/logout?scope=local'));
  assert.equal(logouts.length, 1); assert.equal(logouts[0].token, 'Bearer access-0');
});

test('unknown login outcome reports scoped cleanup uncertainty without global logout', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.path.endsWith('/token?grant_type=password')) { await response.body?.cancel(); throw new Error('PRIVATE_RESPONSE'); } return response;
  });
  await failure(verifyHostedPlanNames(state.configuration, state.options), 'sign_in', false, false, true);
  assert.equal(state.calls.some(c => c.path.includes('logout') || c.path === '/v1/create-case'), false);
});

test('oversized or redirected JSON never reaches case creation', async t => {
  for (const mode of ['oversized', 'redirected']) {
    const state = await setup(t, async (call, response) => {
      if (call.path === '/v1/read-case') {
        if (mode === 'oversized') return json({ padding: 'x'.repeat(64 * 1024) });
        Object.defineProperty(response, 'redirected', { value: true });
      } return response;
    });
    await failure(verifyHostedPlanNames(state.configuration, state.options), 'existing_fixture_guards');
    assert.equal(state.calls.some(c => c.path === '/v1/create-case'), false);
  }
});

test('private journal preserves identifiers with exclusive creation and restricted permissions', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'sah-name-check-')); t.after(() => rm(directory, { recursive: true, force: true }));
  const initial = { apiOrigin, projectOrigin, caseId: randomUUID(), runId: randomUUID() };
  const journal = await createPlanNameCheckJournal(directory, initial);
  await journal.journal({ stage: 'first_name', state: 'intent', caseId: initial.caseId, mutationId: `${initial.runId}-first` }); await journal.close();
  const file = join(directory, 'hosted-plan-names-check.jsonl'), bytes = await readFile(file, 'utf8');
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.ok(bytes.includes(initial.caseId)); assert.ok(bytes.includes(initial.runId));
  await assert.rejects(createPlanNameCheckJournal(directory, { ...initial, caseId: randomUUID() }));
  assert.equal(await readFile(file, 'utf8'), bytes);
});
