import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:http';
import { brotliCompressSync, deflateSync, gzipSync } from 'node:zlib';
import type { AddressInfo } from 'node:net';
import test, { type TestContext } from 'node:test';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { createSupabaseAuthenticator } from '../src/auth/supabase-auth.ts';
import { loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';
import type { LifecycleRepository } from '../src/lifecycle/types.ts';
import { createTeamBetaJournal, fictionalTeamDraft, verifyHostedTeamBeta, TeamBetaVerificationError,
  type TeamBetaConfiguration, type TeamBetaEvent } from '../tool/verify-hosted-team-beta.ts';

const apiOrigin = 'https://beta.example.invalid', projectOrigin = 'https://fictional.supabase.co';
const users = ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'];
const config = (): TeamBetaConfiguration => ({ apiOrigin, auth: { projectUrl: projectOrigin, publishableKey: 'sb_publishable_fictional', timeoutMs: 1000 },
  accounts: [{ email: 'fictional-a@example.invalid', password: 'fictional-password-a' }, { email: 'fictional-b@example.invalid', password: 'fictional-password-b' }],
  caseIds: [randomUUID(), randomUUID()], newCaseId: randomUUID(), runId: randomUUID() });
interface Call { path: string; token: string | null; body: Record<string, any> }
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

async function setup(t: TestContext, transform?: (call: Call, response: Response) => Promise<Response>) {
  const configuration = config(), bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
  const existing = configuration.caseIds.map((id, index) => ({ userId: users[index], snapshot: { ...fictionalTeamDraft(id), revision: 1 } }));
  const raw = new MemoryCaseRepository(existing), deleted = new Set<string>(), deletions: string[] = [];
  const cases = new Proxy(raw, { get(target, property) {
    if (property === 'loadForUser') return async (owner: string, id: string) => deleted.has(id) ? null : target.loadForUser(owner, id);
    const value = Reflect.get(target, property, target); return typeof value === 'function' ? value.bind(target) : value;
  } });
  const lifecycle: LifecycleRepository = {
    isAccountClosed: async () => false,
    async deleteCaseIfCurrent(input) {
      assert.equal(input.caseId, configuration.newCaseId); assert.equal(input.userId, users[0]);
      const snapshot = await cases.loadForUser(input.userId, input.caseId); if (!snapshot) return { status: 'not_found' };
      if (snapshot.revision !== input.revision) return { status: 'conflict' };
      const catalog = await cases.readEvidenceCatalogForUser(input.userId, input.caseId);
      if (catalog.status !== 'found' || catalog.catalog.catalogRevision !== input.expectedCatalogRevision) return { status: 'evidence_conflict' };
      deletions.push(input.caseId); deleted.add(input.caseId); return { status: 'deleted' };
    },
    prepareAccountDeletion: async () => { throw new Error('Account deletion forbidden.'); },
    confirmAccountDeletion: async () => { throw new Error('Account deletion forbidden.'); },
    readAccountDeletionReceipt: async () => { throw new Error('Account deletion forbidden.'); },
  };
  const calls: Call[] = [], events: TeamBetaEvent[] = []; let localOrigin = '';
  const fetchImpl: typeof fetch = async (input, init) => {
    const url = new URL(String(input)), headers = new Headers(init?.headers), token = headers.get('Authorization');
    const call = { path: `${url.pathname}${url.search}`, token, body: init?.body ? JSON.parse(String(init.body)) as Record<string, any> : {} }; calls.push(call);
    assert.equal(init?.redirect, 'error'); assert.equal(init?.cache, 'no-store');
    if (url.origin === projectOrigin) {
      assert.equal(headers.get('apikey'), 'sb_publishable_fictional');
      let response: Response;
      if (call.path.endsWith('/token?grant_type=password')) response = json({ access_token: call.body.email === configuration.accounts[0].email ? 'access-0' : 'access-1', token_type: 'bearer' });
      else if (call.path.endsWith('/user')) response = json({ id: users[token === 'Bearer access-0' ? 0 : 1], role: 'authenticated' });
      else { assert.ok(call.path.endsWith('/logout?scope=local')); response = new Response(null, { status: 204 }); }
      return transform ? transform(call, response) : response;
    }
    assert.equal(url.origin, apiOrigin); assert.equal(headers.get('apikey'), null);
    const actual = await fetch(`${localOrigin}${url.pathname}`, init);
    const response = new Response(actual.body, { status: actual.status, headers: actual.headers });
    return transform ? transform(call, response) : response;
  };
  const authenticate = createSupabaseAuthenticator(configuration.auth, fetchImpl);
  const deps = { cases, authenticate, now: () => new Date(), loadRegistry: bundle.loadRegistry, loadFormTemplate: bundle.loadFormTemplate };
  const server = createMatchingServer(deps, deps, deps, deps, deps, deps, { assessmentDependencies: deps, programIntakeDependencies: deps,
    lifecycleDependencies: { lifecycle, authenticate, authenticateForDeletion: authenticate } });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve)); localOrigin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  t.after(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  return { configuration, calls, events, cases, raw, deletions, existing,
    options: { fetchImpl, testNoPacing: true, journal: async (event: Readonly<TeamBetaEvent>) => { events.push(structuredClone(event)); } } };
}

async function compressedFixture(t: TestContext) {
  const compressors = { gzip: gzipSync, br: brotliCompressSync, deflate: deflateSync };
  const server = createServer(async (request, response) => {
    const parts: Buffer[] = []; let size = 0;
    for await (const part of request) { const bytes = Buffer.from(part); size += bytes.length; assert.ok(size <= 512 * 1024); parts.push(bytes); }
    const encoding = request.url!.slice(1) as keyof typeof compressors;
    const encoded = compressors[encoding](Buffer.concat(parts));
    response.writeHead(200, { 'Content-Type': 'application/json', 'Content-Encoding': encoding,
      'Content-Length': encoded.length, 'Cache-Control': 'no-store' }); response.end(encoded);
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  t.after(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  return async (value: unknown, encoding: keyof typeof compressors) => {
    const text = JSON.stringify(value);
    const actual = await fetch(`${origin}/${encoding}`, { method: 'POST', body: text });
    assert.equal(actual.headers.get('content-encoding'), encoding);
    assert.notEqual(Number(actual.headers.get('content-length')), Buffer.byteLength(text));
    return new Response(actual.body, { status: actual.status, headers: actual.headers });
  };
}
async function expectFailure(task: Promise<unknown>, stage: string, uncertain: boolean, retained: boolean) {
  await assert.rejects(task, error => {
    assert.ok(error instanceof TeamBetaVerificationError); assert.equal(error.stage, stage); assert.equal(error.mutationUncertain, uncertain);
    assert.equal(error.cleanupPending, retained); assert.equal('cause' in error, false);
    for (const secret of ['PRIVATE_RESPONSE', 'access-0', 'fictional-password', '@']) assert.equal(error.message.includes(secret), false);
    return true;
  });
}

test('all three hosted v2 workflows traverse real HTTP, inspect pinned PDF bytes, retry exactly and clean only the new case', async t => {
  const state = await setup(t);
  const report = await verifyHostedTeamBeta(state.configuration, state.options);
  assert.equal(report.status, 'passed'); assert.equal(report.pdfCount, 3); assert.equal(report.caseDeleted, true);
  assert.ok(report.requests <= 100); assert.deepEqual(report.programs, ['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair']);
  assert.deepEqual(state.deletions, [state.configuration.newCaseId]); assert.equal(await state.cases.loadForUser(users[0], state.configuration.newCaseId), null);
  for (const owned of state.existing) assert.deepEqual(await state.cases.loadForUser(owned.userId, owned.snapshot.caseId), owned.snapshot);
  assert.equal(state.calls.filter(c => c.path === '/v1/create-case').length, 1);
  assert.equal(state.calls.filter(c => c.path === '/v1/upload-evidence').length, 1);
  assert.equal(state.calls.filter(c => c.path === '/v2/create-draft-export').length, 7);
  assert.equal(state.calls.filter(c => c.path.endsWith('/logout?scope=local')).length, 2);
  assert.equal(state.events.at(-1)?.stage, 'complete');
  const aggregate = JSON.stringify(report), journal = JSON.stringify(state.events);
  for (const forbidden of [...users, ...state.configuration.caseIds, state.configuration.newCaseId, 'access-0', 'fictional-password', '@']) assert.equal(aggregate.includes(forbidden), false);
  for (const forbidden of [...users, 'access-0', 'fictional-password', 'Fictional review', '@']) assert.equal(journal.includes(forbidden), false);
});

test('real gzip, Brotli and deflate HTTP decoding preserves bounded reads and completes every route', async t => {
  const compressed = await compressedFixture(t); let encodedResponses = 0;
  const state = await setup(t, async (call, response) => {
    if (response.status !== 200 || response.headers.get('content-type') !== 'application/json') return response;
    const value = await response.json();
    if (call.path.endsWith('/token?grant_type=password')) value.fictionalPadding = 'Generated synthetic provider padding. '.repeat(30);
    const encoding = (['gzip', 'br', 'deflate'] as const)[encodedResponses++ % 3];
    return compressed(value, encoding);
  });
  const report = await verifyHostedTeamBeta(state.configuration, state.options);
  assert.equal(report.status, 'passed'); assert.ok(encodedResponses > 20);
  assert.equal(report.localSignOuts, 2); assert.equal(report.caseDeleted, true);
});

test('compressed decoded JSON still cannot exceed the byte ceiling', async t => {
  const compressed = await compressedFixture(t);
  const state = await setup(t, async (call, response) => {
    if (call.path === '/v1/read-case' && response.status === 200) return compressed({ padding: 'x'.repeat(320 * 1024) }, 'gzip');
    return response;
  });
  await expectFailure(verifyHostedTeamBeta(state.configuration, state.options), 'existing_fixture_guards', false, false);
  assert.equal(state.calls.some(c => c.path === '/v1/create-case'), false);
  assert.equal(state.calls.filter(c => c.path.endsWith('/logout?scope=local')).length, 2);
});

test('a parsed sign-in token is scoped out even when the later response envelope is rejected', async t => {
  const compressed = await compressedFixture(t);
  const state = await setup(t, async (call, response) => {
    if (call.path.endsWith('/token?grant_type=password')) {
      const value = await response.json(); value.token_type = 'unexpected'; return compressed(value, 'gzip');
    } return response;
  });
  await expectFailure(verifyHostedTeamBeta(state.configuration, state.options), 'sign_in', false, false);
  const logouts = state.calls.filter(c => c.path.endsWith('/logout?scope=local'));
  assert.equal(logouts.length, 1); assert.equal(logouts[0].token, 'Bearer access-0');
  assert.equal(state.events.at(-1)?.sessionCleanupFailed, false);
  assert.equal(state.calls.some(c => c.path === '/v1/create-case'), false);
});

test('a parsed token survives an unencoded length-mismatch rejection for scoped cleanup', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.path.endsWith('/token?grant_type=password')) response.headers.set('Content-Length', '1');
    return response;
  });
  await expectFailure(verifyHostedTeamBeta(state.configuration, state.options), 'sign_in', false, false);
  assert.equal(state.calls.filter(c => c.path.endsWith('/logout?scope=local')).length, 1);
  assert.equal(state.events.at(-1)?.sessionCleanupFailed, false);
});

test('a lost unparseable sign-in response reports unknown session cleanup without global revocation', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.path.endsWith('/token?grant_type=password')) { await response.body?.cancel(); throw new Error('PRIVATE_RESPONSE access-0'); }
    return response;
  });
  await expectFailure(verifyHostedTeamBeta(state.configuration, state.options), 'sign_in', false, false);
  assert.equal(state.events.at(-1)?.sessionCleanupFailed, true);
  assert.equal(state.calls.some(c => c.path.includes('/logout') || c.path === '/v1/create-case'), false);
});

test('lost create acknowledgement never retries or deletes the uncertain case and signs out known sessions', async t => {
  const state = await setup(t, async (call, response) => { if (call.path === '/v1/create-case') { await response.body?.cancel(); throw new Error('PRIVATE_RESPONSE access-0'); } return response; });
  await expectFailure(verifyHostedTeamBeta(state.configuration, state.options), 'create_case', true, true);
  assert.equal((await state.raw.loadForUser(users[0], state.configuration.newCaseId))?.revision, 1);
  assert.equal(state.calls.filter(c => c.path === '/v1/create-case').length, 1); assert.deepEqual(state.deletions, []);
  assert.equal(state.calls.filter(c => c.path.endsWith('/logout?scope=local')).length, 2);
});

test('uncertain annotation write retains the case and stops before any export', async t => {
  const state = await setup(t, async (call, response) => { if (call.path === '/v2/save-evidence-annotations') { await response.body?.cancel(); throw new Error('PRIVATE_RESPONSE'); } return response; });
  await expectFailure(verifyHostedTeamBeta(state.configuration, state.options), 'annotations', true, true);
  assert.deepEqual(state.deletions, []); assert.equal(state.calls.filter(c => c.path === '/v2/save-evidence-annotations').length, 1);
  assert.equal(state.calls.some(c => c.path === '/v2/create-draft-export'), false);
});

test('journal fsync failure before create intent prevents creation', async t => {
  const state = await setup(t);
  await expectFailure(verifyHostedTeamBeta(state.configuration, { ...state.options, journal: async event => {
    if (event.stage === 'create_case') throw new Error('PRIVATE_RESPONSE'); await state.options.journal(event);
  } }), 'create_case', false, false);
  assert.equal(state.calls.some(c => c.path === '/v1/create-case'), false); assert.deepEqual(state.deletions, []);
});

test('a changed pinned form context stops before reviewed-answer writes', async t => {
  const state = await setup(t, async (call, response) => { if (call.path === '/v2/read-form-answers' && call.token === 'Bearer access-0') {
    const value = await response.json(); value.context.mappingVersion = 'unverified-context'; return json(value); } return response; });
  await expectFailure(verifyHostedTeamBeta(state.configuration, state.options), 'scfhp-eaa_form', false, true);
  assert.equal(state.calls.some(c => c.path === '/v2/save-form-answers'), false); assert.deepEqual(state.deletions, []);
});

test('a corrupt downloaded digest cannot pass or trigger later program writes', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.path === '/v2/download-draft-export' && call.token === 'Bearer access-0' && response.status === 200) response.headers.set('X-Content-SHA256', '0'.repeat(64));
    return response;
  });
  await expectFailure(verifyHostedTeamBeta(state.configuration, state.options), 'scfhp-eaa_download', false, true);
  assert.deepEqual(state.deletions, []);
  assert.equal(state.calls.some(c => c.path === '/v2/save-program-intake' && c.body.programId === 'hpsm-eaa'), false);
});

test('oversized response declarations stop before a new case is created', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.path === '/v1/read-case' && response.status === 200) response.headers.set('Content-Length', String(320 * 1024 + 1));
    return response;
  });
  await expectFailure(verifyHostedTeamBeta(state.configuration, state.options), 'existing_fixture_guards', false, false);
  assert.equal(state.calls.some(c => c.path === '/v1/create-case'), false); assert.deepEqual(state.deletions, []);
});

test('a cleanup revision mismatch fails closed without deletion', async t => {
  let finalRead = false;
  const state = await setup(t, async (call, response) => {
    if (call.path === '/v2/save-assessment' && String(call.body.mutationId).endsWith('-correction')) finalRead = true;
    if (finalRead && call.path === '/v1/read-case' && call.body.caseId === state.configuration.newCaseId && response.status === 200) {
      const value = await response.json(); value.revision++; return json(value);
    } return response;
  });
  await expectFailure(verifyHostedTeamBeta(state.configuration, state.options), 'cleanup_guards', false, true);
  assert.deepEqual(state.deletions, []);
});

test('journal is exclusive and private; configuration rejects reuse of an existing fixture before requests', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'sah-beta-')); const configuration = config();
  try {
    const initial = { apiOrigin, projectOrigin, caseId: configuration.newCaseId, runId: configuration.runId };
    const local = await createTeamBetaJournal(directory, initial); await local.close();
    assert.equal((await stat(join(directory, 'hosted-team-beta-check.jsonl'))).mode & 0o777, 0o600);
    assert.ok((await readFile(join(directory, 'hosted-team-beta-check.jsonl'), 'utf8')).includes(configuration.newCaseId));
    await assert.rejects(createTeamBetaJournal(directory, initial));
  } finally { await rm(directory, { recursive: true, force: true }); }
  let requests = 0;
  await expectFailure(verifyHostedTeamBeta({ ...configuration, newCaseId: configuration.caseIds[0] }, {
    fetchImpl: async () => { requests++; throw new Error(); }, journal: async () => {}, testNoPacing: true }), 'configuration', false, false);
  assert.equal(requests, 0);
});
