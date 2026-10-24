import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { AddressInfo } from 'node:net';
import test, { type TestContext } from 'node:test';
import { PDFDocument } from 'pdf-lib';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { createSupabaseAuthenticator } from '../src/auth/supabase-auth.ts';
import { loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';
import { HostedDraftVerificationError, verifyHostedDraft, type DraftJournalEvent, type HostedDraftConfiguration } from '../src/auth/hosted-draft-verifier.ts';
import { createHostedDraftJournal } from '../tool/verify-hosted-draft.ts';

const apiOrigin = 'https://draft.example.invalid', projectOrigin = 'https://fictional.supabase.co';
const users = ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'];
const configuration = (): HostedDraftConfiguration => ({ apiOrigin, auth: { projectUrl: projectOrigin,
  publishableKey: 'sb_publishable_fictional', timeoutMs: 100 }, accounts: [
  { email: 'fictional-a@example.invalid', password: 'fictional-password-a' },
  { email: 'fictional-b@example.invalid', password: 'fictional-password-b' },
], caseId: randomUUID(), generationKey: randomUUID() });
interface Call { url: string; token: string | null; body: Record<string, unknown> }
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status,
  headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

async function setup(t: TestContext, transform?: (call: Call, response: Response) => Promise<Response>) {
  const bundle = await loadRuntimeBenefitsBundle('scfhp-eaa-draft-v1');
  const cases = new MemoryCaseRepository([]);
  const calls: Call[] = [], journal: DraftJournalEvent[] = [];
  let localOrigin = '';
  const fetchImpl: typeof fetch = async (input, init) => {
    const call: Call = { url: String(input), token: new Headers(init?.headers).get('Authorization'),
      body: init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {} };
    calls.push(call);
    assert.equal(init?.redirect, 'error'); assert.equal(init?.cache, 'no-store');
    if (call.url.startsWith(projectOrigin)) {
      assert.equal(new Headers(init?.headers).get('apikey'), 'sb_publishable_fictional');
      if (call.url.endsWith('/token?grant_type=password')) {
        const index = call.body.email === 'fictional-a@example.invalid' ? 0 : 1;
        return json({ access_token: `access-${index}`, refresh_token: `refresh-${index}`, token_type: 'bearer' });
      }
      if (call.url.endsWith('/user')) return json({ id: users[call.token === 'Bearer access-0' ? 0 : 1], role: 'authenticated' });
      assert.ok(call.url.endsWith('/logout?scope=local'));
      return new Response(null, { status: 204 });
    }
    assert.equal(new URL(call.url).origin, apiOrigin);
    assert.equal(new Headers(init?.headers).get('apikey'), null);
    const endpoint = `${localOrigin}${new URL(call.url).pathname}`;
    const actual = await fetch(endpoint, init);
    assert.equal(actual.url, endpoint); assert.equal(actual.redirected, false);
    const response = new Response(actual.body, { status: actual.status, headers: actual.headers });
    return transform ? await transform(call, response) : response;
  };
  const deps = { authenticate: createSupabaseAuthenticator(configuration().auth, fetchImpl), cases,
    now: () => new Date(), loadRegistry: bundle.loadRegistry, loadFormTemplate: bundle.loadFormTemplate };
  const server = createMatchingServer(deps, deps, deps, deps, deps, deps);
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  localOrigin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  t.after(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  const options = { fetchImpl, journal: async (event: Readonly<DraftJournalEvent>) => { journal.push(structuredClone(event)); } };
  return { calls, journal, cases, options };
}
async function failure(promise: Promise<unknown>, stage: string, uncertain = false) {
  await assert.rejects(promise, error => {
    assert.ok(error instanceof HostedDraftVerificationError); assert.equal(error.stage, stage);
    assert.equal(error.mutationUncertain, uncertain); assert.equal(error.cleanupFailed, false);
    assert.equal('cause' in error, false);
    for (const secret of ['PRIVATE_RESPONSE', 'access-0', 'fictional-password', '@']) assert.equal(error.message.includes(secret), false);
    return true;
  });
}

test('real HTTP routes render pinned five-page SCFHP draft, deny Bob and invalidate after an administrative revision', async t => {
  const state = await setup(t), config = configuration();
  let preview: Uint8Array | null = null;
  const report = await verifyHostedDraft(config, { ...state.options, onPdf: async bytes => { preview = bytes; } });
  assert.equal(report.status, 'passed'); assert.equal(report.caseId, config.caseId);
  assert.equal(report.caseRevision, 3); assert.equal(report.answerRevision, 2);
  assert.equal(report.pageCount, 5); assert.equal(report.checklistVerified, true);
  assert.equal(report.protectedFieldsUnresolved, true); assert.equal(report.policyCurrentnessUnknown, true);
  assert.ok(preview); assert.equal(createHash('sha256').update(preview).digest('hex'), report.sha256);
  const pdf = await PDFDocument.load(preview); assert.equal(pdf.getPageCount(), 5); assert.equal(pdf.getForm().getFields().length, 0);
  assert.equal((await state.cases.loadForUser(users[0], config.caseId))?.revision, 3);
  assert.equal(await state.cases.loadForUser(users[1], config.caseId), null);
  assert.equal(state.calls.filter(call => call.url.endsWith('/create-case')).length, 1);
  assert.equal(state.calls.filter(call => call.url.endsWith('/save-form-answers')).length, 2);
  assert.equal(state.calls.filter(call => call.url.endsWith('/create-draft-export')).length, 1);
  assert.equal(state.calls.filter(call => call.url.endsWith('/logout?scope=local')).length, 2);
  const saved = state.calls.find(call => call.url.endsWith('/save-form-answers'))!.body.answers as { key: string }[];
  assert.deepEqual(saved.map(answer => answer.key), ['memberFirstName', 'memberLastName', 'memberPhone', 'memberPreferredSpokenLanguage']);
  const journalText = JSON.stringify(state.journal);
  for (const forbidden of ['access-0', 'fixture-a@', 'fictional-password', '202-555', 'Resident', users[0]]) assert.equal(journalText.includes(forbidden), false);
  assert.equal(state.journal.at(-1)?.stage, 'complete');
});

test('a lost create response retains the unique case and stops without retrying any write', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.url.endsWith('/create-case')) { await response.body?.cancel(); throw new Error('PRIVATE_RESPONSE access-0'); }
    return response;
  });
  const config = configuration();
  await failure(verifyHostedDraft(config, state.options), 'create_case', true);
  assert.equal((await state.cases.loadForUser(users[0], config.caseId))?.revision, 1);
  assert.equal(state.calls.filter(call => call.url.endsWith('/create-case')).length, 1);
  assert.equal(state.calls.some(call => call.url.endsWith('/match-case')), false);
  assert.equal(state.calls.filter(call => call.url.includes('/logout?scope=local')).length, 2);
  assert.deepEqual(state.journal.at(-1), { stage: 'create_case', state: 'failed', caseId: config.caseId, cleanupFailed: false, mutationUncertain: true });
});

test('unexpected eligibility and changed pinned form context stop before answer writes', async t => {
  for (const target of ['match', 'form_context']) {
    const state = await setup(t, async (call, response) => {
      if (target === 'match' && call.url.endsWith('/match-case')) {
        const value = await response.json(); value.matches[0].status = 'meets_known_criteria'; return json(value);
      }
      if (target === 'form_context' && call.url.endsWith('/read-form-answers')) {
        const value = await response.json(); value.context.mappingVersion = 'unreviewed-version'; return json(value);
      }
      return response;
    });
    await failure(verifyHostedDraft(configuration(), state.options), target);
    assert.equal(state.calls.some(call => call.url.endsWith('/save-form-answers')), false);
  }
});

test('wrong answer provenance/revision is uncertain and prevents PDF preparation', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.url.endsWith('/save-form-answers')) {
      const value = await response.json(); value.saved.updatedBy = users[1]; return json(value);
    }
    return response;
  });
  await failure(verifyHostedDraft(configuration(), state.options), 'save_answers', true);
  assert.equal(state.calls.some(call => call.url.endsWith('/create-draft-export')), false);
});

test('malformed checklist timestamp or incomplete review tasks cannot produce checklistVerified', async t => {
  for (const target of ['timestamp', 'tasks']) {
    const state = await setup(t, async (call, response) => {
      if (call.url.endsWith('/prepare-packet')) {
        const value = await response.json();
        if (target === 'timestamp') value.generatedAt = null;
        else value.missingItems = value.missingItems.map((item: { id: string }) => ({ id: item.id }));
        return json(value);
      }
      return response;
    });
    await failure(verifyHostedDraft(configuration(), state.options), 'prepare_packet', true);
    assert.equal(state.calls.some(call => call.url.endsWith('/create-draft-export')), false);
  }
});

test('missing policy warning and corrupt download digest cannot be accepted or trigger the later revision', async t => {
  for (const target of ['create_export', 'owner_download']) {
    const state = await setup(t, async (call, response) => {
      if (target === 'create_export' && call.url.endsWith('/create-draft-export')) {
        const value = await response.json(); value.warnings.pop(); return json(value);
      }
      if (target === 'owner_download' && call.url.endsWith('/download-draft-export')) response.headers.set('X-Content-SHA256', '0'.repeat(64));
      return response;
    });
    await failure(verifyHostedDraft(configuration(), state.options), target, target === 'create_export');
    assert.equal(state.calls.filter(call => call.url.endsWith('/save-form-answers')).length, 1);
  }
});

test('cross-owner404 must use ARTIFACT_NOT_FOUND, and failure leaves the earlier case revision retained', async t => {
  const state = await setup(t, async (call, response) => {
    if (call.url.endsWith('/download-draft-export') && call.token === 'Bearer access-1') {
      await response.body?.cancel(); return json({ schemaVersion: '1', error: { code: 'CASE_NOT_FOUND', message: 'PRIVATE_RESPONSE' } }, 404);
    }
    return response;
  });
  const config = configuration();
  await failure(verifyHostedDraft(config, state.options), 'cross_owner');
  assert.equal((await state.cases.loadForUser(users[0], config.caseId))?.revision, 2);
  assert.equal(state.calls.filter(call => call.url.endsWith('/save-form-answers')).length, 1);
});

test('journal failure before mutation prevents its POST and still signs out known sessions', async t => {
  const state = await setup(t);
  await failure(verifyHostedDraft(configuration(), { ...state.options, journal: async event => {
    if (event.stage === 'create_case') throw new Error('PRIVATE_RESPONSE');
  } }), 'create_case');
  assert.equal(state.calls.some(call => call.url.endsWith('/create-case')), false);
  assert.equal(state.calls.filter(call => call.url.endsWith('/logout?scope=local')).length, 2);
});

test('unsafe origin, malformed generation key and missing journal fail before provider/network work', async () => {
  let requests = 0;
  const options = { fetchImpl: (async () => { requests++; throw new Error('Must not run'); }) as typeof fetch, journal: async () => {} };
  await failure(verifyHostedDraft({ ...configuration(), apiOrigin: 'http://localhost' }, options), 'configuration');
  await failure(verifyHostedDraft({ ...configuration(), generationKey: 'a-valid-key\n' }, options), 'configuration');
  await failure(verifyHostedDraft(configuration(), { ...options, journal: undefined } as unknown as Parameters<typeof verifyHostedDraft>[1]), 'configuration');
  assert.equal(requests, 0);
});

test('CLI journal and preview are private/exclusive; a repeated run cannot overwrite retained recovery IDs', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'sah-draft-check-'));
  const initial = { apiOrigin, projectOrigin, caseId: randomUUID(), generationKey: randomUUID() };
  try {
    const local = await createHostedDraftJournal(directory, initial);
    try {
      assert.equal((await stat(join(directory, 'hosted-draft-check.jsonl'))).mode & 0o777, 0o600);
      assert.deepEqual(JSON.parse((await readFile(join(directory, 'hosted-draft-check.jsonl'), 'utf8')).trim()),
        { schemaVersion: '1', kind: 'retained-identifiers', ...initial });
      await local.onPdf(new TextEncoder().encode('%PDF-fictional-test'));
      assert.equal((await stat(join(directory, 'hosted-draft-preview.pdf'))).mode & 0o777, 0o600);
      await assert.rejects(createHostedDraftJournal(directory, { ...initial, caseId: randomUUID() }));
    } finally { await local.close(); }
  } finally { await rm(directory, { recursive: true, force: true }); }
});
