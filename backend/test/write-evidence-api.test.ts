import assert from 'node:assert/strict';
import test from 'node:test';
import sharp from 'sharp';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { handleDeleteEvidence, handleUploadEvidence, MAX_IMAGE_BASE64_CHARACTERS,
  type DeleteEvidenceRequest, type UploadEvidenceRequest, type WriteEvidenceDependencies,
  type WriteEvidenceResult } from '../src/api/write-evidence.ts';
import { MAX_IMAGE_INPUT_BYTES, sanitizeEvidenceImage } from '../src/evidence/image-sanitizer.ts';
import type { CaseSnapshot } from '../src/types.ts';

const NOW = '2026-10-17T22:00:00.000Z';
const imagePromise = sharp({ create: { width: 3, height: 2, channels: 4, background: '#abc123' } }).png().toBuffer();
function snapshot(caseId = 'case-a'): CaseSnapshot {
  return { schemaVersion: '1', caseId, revision: 1, profile: { city: null, county: null, healthPlan: null,
    tenure: null, ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null },
  unresolvedFields: [], findings: [
    { id: 'finding-a', room: 'entrance', observation: 'Fictional entrance image', reviewState: 'needs_review',
      evidenceIds: ['photo-a', 'photo-b'], measurements: [] },
    { id: 'finding-b', room: 'bathroom', observation: 'Fictional bathroom image', reviewState: 'confirmed',
      evidenceIds: ['photo-c'], measurements: [] },
  ] };
}
async function setup(limits?: { maxBytes: number; maxAssets: number; maxArtifacts: number }) {
  const repository = new MemoryCaseRepository([{ userId: 'alice', snapshot: snapshot() },
    { userId: 'bob', snapshot: snapshot('case-b') }], limits);
  const deps: WriteEvidenceDependencies = { cases: repository, now: () => new Date(NOW),
    authenticate: async token => token === 'alice-token' ? { userId: 'alice' } : token === 'bob-token' ? { userId: 'bob' } : null };
  const request: UploadEvidenceRequest = { schemaVersion: '1', caseId: 'case-a', expectedCaseRevision: 1,
    expectedCatalogRevision: 0, evidenceId: 'photo-a', expectedEvidenceRevision: 0, findingId: 'finding-a',
    capturedAt: null, imageBase64: (await imagePromise).toString('base64') };
  return { repository, deps, request,
    upload: (body: unknown = request, token: string | null = 'alice-token') => handleUploadEvidence({ body, bearerToken: token }, deps),
    remove: (body: unknown = deletion, token: string | null = 'alice-token') => handleDeleteEvidence({ body, bearerToken: token }, deps) };
}
const deletion: DeleteEvidenceRequest = { schemaVersion: '1', caseId: 'case-a', expectedCaseRevision: 1,
  expectedCatalogRevision: 1, evidenceId: 'photo-a', expectedEvidenceRevision: 1 };
function error(result: WriteEvidenceResult, status: number, code: string): void {
  assert.equal(result.status, status);
  assert.ok('error' in result.body);
  assert.equal(result.body.error.code, code);
  assert.equal(result.headers['Cache-Control'], 'no-store');
  assert.ok(!JSON.stringify(result).includes('PRIVATE'));
}
function uploaded(result: WriteEvidenceResult) {
  assert.equal(result.status, 200);
  assert.ok('evidence' in result.body);
  return result.body;
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}

test('upload uses the default sanitizer and returns only private descriptor metadata', async () => {
  const state = await setup();
  const result = await state.upload();
  const body = uploaded(result);
  assert.deepEqual(Object.keys(body).sort(), ['caseId', 'caseRevision', 'catalogRevision', 'evidence', 'schemaVersion']);
  assert.equal(body.caseRevision, 1); assert.equal(body.catalogRevision, 1);
  assert.equal(body.evidence.evidenceRevision, 1); assert.equal(body.evidence.mediaType, 'image/png');
  assert.equal(body.evidence.width, 3); assert.equal(body.evidence.height, 2);
  assert.equal(body.evidence.capturedAt, null); assert.equal(body.evidence.preparedAt, NOW);
  assert.equal(body.evidence.processingVersion, 'evidence-png-v1');
  assert.ok(!JSON.stringify(body).includes(state.request.imageBase64));
  assert.ok(!('bytes' in body.evidence)); assert.ok(!('userId' in body));
  assert.equal((await state.repository.loadForUser('alice', 'case-a'))!.revision, 1);
  const asset = await state.repository.readEvidenceForUser({ userId: 'alice', caseId: 'case-a', revision: 1,
    expectedCatalogRevision: 1, evidenceId: 'photo-a', expectedEvidenceRevision: 1 });
  assert.equal(asset.status, 'found');
  if (asset.status === 'found') {
    assert.equal(Buffer.from(asset.asset.bytes).includes(Buffer.from('eXIf')), false);
    assert.equal(asset.asset.descriptor.sha256, body.evidence.sha256);
  }
});

test('JPEG is converted to PNG and reported capture time remains explicit', async () => {
  const state = await setup();
  const jpeg = await sharp(await imagePromise).jpeg().withExif({ IFD0: { Copyright: 'PRIVATE fictional metadata' } }).toBuffer();
  const body = uploaded(await state.upload({ ...state.request, capturedAt: '2026-10-17T21:00:00Z', imageBase64: jpeg.toString('base64') }));
  assert.equal(body.evidence.mediaType, 'image/png');
  assert.equal(body.evidence.capturedAt, '2026-10-17T21:00:00Z');
});

test('opaque authentication scopes both operations and caller owner fields are rejected', async () => {
  const state = await setup();
  for (const token of [null, '', 'bad token', 'unknown', 'x'.repeat(4097)]) {
    error(await state.upload(state.request, token), 401, 'UNAUTHENTICATED');
    error(await state.remove(deletion, token), 401, 'UNAUTHENTICATED');
  }
  error(await state.upload(state.request, 'bob-token'), 404, 'CASE_NOT_FOUND');
  error(await state.upload({ ...state.request, userId: 'bob' }), 400, 'INVALID_REQUEST');
  uploaded(await state.upload());
  error(await state.remove(deletion, 'bob-token'), 404, 'CASE_NOT_FOUND');
  error(await state.remove(deletion, null), 401, 'UNAUTHENTICATED');
  error(await state.remove({ ...deletion, userId: 'alice' }), 400, 'INVALID_REQUEST');
  assert.equal((await state.repository.readEvidenceCatalogForUser('alice', 'case-a')).status, 'found');
});

test('strict requests reject invalid keys, identifiers, revisions and timestamps before storage', async () => {
  const state = await setup(); let reads = 0;
  state.deps.cases.loadForUser = async () => { reads++; throw new Error('PRIVATE unexpected storage'); };
  for (const body of [null, [], {}, { ...state.request, schemaVersion: '2' }, { ...state.request, path: '/private/file' },
    { ...state.request, imageBase64: null }, { ...state.request, caseId: ' leading' }, { ...state.request, caseId: '\ud800' },
    { ...state.request, evidenceId: 'x\n' }, { ...state.request, findingId: 'x'.repeat(201) },
    { ...state.request, expectedCaseRevision: 0 }, { ...state.request, expectedCaseRevision: '1' },
    { ...state.request, expectedCatalogRevision: -1 }, { ...state.request, expectedCatalogRevision: Number.MAX_SAFE_INTEGER },
    { ...state.request, expectedEvidenceRevision: 1.5 }, { ...state.request, expectedEvidenceRevision: Number.MAX_SAFE_INTEGER },
    { ...state.request, capturedAt: '2026-02-30T01:00:00Z' }, { ...state.request, capturedAt: '2026-10-17T22:00:00+00:00' },
    { ...state.request, capturedAt: false }]) error(await state.upload(body), 400, 'INVALID_REQUEST');
  for (const body of [null, { ...deletion, expectedEvidenceRevision: 0 }, { ...deletion, expectedCatalogRevision: -1 },
    { ...deletion, findingId: 'finding-a' }, { ...deletion, evidenceId: '' }]) error(await state.remove(body), 400, 'INVALID_REQUEST');
  assert.equal(reads, 0);
});

test('base64 must be canonical, padded correctly and bounded before decoding', async () => {
  const state = await setup(); let authCalls = 0;
  state.deps.authenticate = async () => { authCalls++; return { userId: 'alice' }; };
  const values = ['', 'AAAAAAAAAAA', 'AAAAAAAAAAA===', 'AAAAAAAAAAAA\n', 'AAAAAAAAAAAA\r\n',
    'AAAA AAA AAAA', 'AAAAAAAAAA_A', 'AAAAAAAAAA-A', 'AAAAAAAAA=AA', 'AAAAAAAAAAB=',
    'AAAAAAAAAAAAAB==', 'data:image/png;base64,AAAAAAAAAAAA', 'AAAAAAAAAAAA☃',
    'A'.repeat(MAX_IMAGE_BASE64_CHARACTERS + 4), Buffer.alloc(MAX_IMAGE_INPUT_BYTES + 1).toString('base64')];
  for (const imageBase64 of values) error(await state.upload({ ...state.request, imageBase64 }), 400, 'INVALID_REQUEST');
  assert.equal(authCalls, 0);
  error(await state.upload({ ...state.request, imageBase64: 'AAAAAAAAAAA=' }), 422, 'INVALID_IMAGE');
  error(await state.upload({ ...state.request, imageBase64: 'AAAAAAAAAAAA' }), 422, 'INVALID_IMAGE');
});

test('authorized corrupt or unsupported images fail without altering the catalog', async () => {
  const state = await setup();
  for (const imageBase64 of [Buffer.from('PRIVATE not a real image').toString('base64'),
    (await sharp(await imagePromise).webp().toBuffer()).toString('base64')]) {
    error(await state.upload({ ...state.request, imageBase64 }), 422, 'INVALID_IMAGE');
  }
  const catalog = await state.repository.readEvidenceCatalogForUser('alice', 'case-a');
  assert.equal(catalog.status, 'found');
  if (catalog.status === 'found') assert.equal(catalog.catalog.catalogRevision, 0);
});

test('saved case links and all expected revisions are checked before image decoding', async () => {
  const state = await setup();
  const corrupt = { ...state.request, imageBase64: Buffer.from('PRIVATE corrupt pixels').toString('base64') };
  error(await state.upload({ ...corrupt, expectedCaseRevision: 2 }), 409, 'CASE_REVISION_MISMATCH');
  error(await state.upload({ ...corrupt, expectedCatalogRevision: 1 }), 409, 'EVIDENCE_CONFLICT');
  error(await state.upload({ ...corrupt, findingId: 'finding-b' }), 404, 'CASE_NOT_FOUND');
  error(await state.upload({ ...corrupt, evidenceId: 'unlinked-photo' }), 404, 'CASE_NOT_FOUND');
  error(await state.upload({ ...corrupt, expectedEvidenceRevision: 1 }), 409, 'EVIDENCE_CONFLICT');
  error(await state.upload({ ...state.request, capturedAt: '2026-10-17T22:00:01Z' }), 400, 'INVALID_REQUEST');
  uploaded(await state.upload());
  error(await state.upload({ ...corrupt, expectedCatalogRevision: 1 }), 409, 'EVIDENCE_CONFLICT');
});

test('replacement and deletion advance only catalog and asset revisions; deleted IDs cannot be reused publicly', async () => {
  const state = await setup(); uploaded(await state.upload());
  const replaced = uploaded(await state.upload({ ...state.request, expectedCatalogRevision: 1, expectedEvidenceRevision: 1 }));
  assert.equal(replaced.catalogRevision, 2); assert.equal(replaced.evidence.evidenceRevision, 2);
  error(await state.remove(), 409, 'EVIDENCE_CONFLICT');
  error(await state.remove({ ...deletion, expectedCaseRevision: 2 }), 409, 'CASE_REVISION_MISMATCH');
  const removed = await state.remove({ ...deletion, expectedCatalogRevision: 2, expectedEvidenceRevision: 2 });
  assert.deepEqual(removed.body, { schemaVersion: '1', caseId: 'case-a', caseRevision: 1,
    catalogRevision: 3, evidenceId: 'photo-a', evidenceRevision: 3, deleted: true });
  error(await state.remove({ ...deletion, expectedCatalogRevision: 3, expectedEvidenceRevision: 3 }), 409, 'EVIDENCE_CONFLICT');
  error(await state.upload({ ...state.request, expectedCatalogRevision: 3, expectedEvidenceRevision: 3 }), 409, 'EVIDENCE_CONFLICT');
  error(await state.upload({ ...state.request, expectedCatalogRevision: 3 }), 409, 'EVIDENCE_CONFLICT');
  const fresh = uploaded(await state.upload({ ...state.request, evidenceId: 'photo-b', expectedCatalogRevision: 3 }));
  assert.equal(fresh.evidence.evidenceRevision, 1); assert.equal(fresh.catalogRevision, 4);
  assert.equal((await state.repository.loadForUser('alice', 'case-a'))!.revision, 1);
});

test('one active upload per dependency instance releases its slot after failures', async () => {
  const state = await setup(), entered = deferred<void>(), release = deferred<void>();
  state.deps.authenticate = async () => { entered.resolve(); await release.promise; return null; };
  const first = state.upload(); await entered.promise;
  error(await state.upload(), 429, 'UPLOAD_BUSY');
  const independent = await setup(); uploaded(await independent.upload());
  release.resolve(); error(await first, 401, 'UNAUTHENTICATED');
  state.deps.authenticate = async () => ({ userId: 'alice' });
  uploaded(await state.upload());
});

test('aborted authentication releases admission and a late result cannot upload or delete', async () => {
  for (const operation of ['upload', 'delete'] as const) {
    const state = await setup();
    if (operation === 'delete') uploaded(await state.upload());
    const controller = new AbortController(), entered = deferred<void>(), release = deferred<{ userId: string }>();
    state.deps.authenticate = async () => { entered.resolve(); return release.promise; };
    const input = { body: operation === 'upload' ? state.request : deletion, bearerToken: 'alice-token', signal: controller.signal };
    const abandoned = operation === 'upload' ? handleUploadEvidence(input, state.deps) : handleDeleteEvidence(input, state.deps);
    await entered.promise; controller.abort();
    error(await abandoned, 503, 'SERVICE_UNAVAILABLE');
    state.deps.authenticate = async () => ({ userId: 'alice' });
    if (operation === 'upload') uploaded(await state.upload());
    else assert.equal((await state.remove()).status, 200);
    release.resolve({ userId: 'alice' }); await new Promise<void>(resolve => setImmediate(resolve));
    const catalog = await state.repository.readEvidenceCatalogForUser('alice', 'case-a');
    assert.equal(catalog.status, 'found');
    if (catalog.status === 'found') {
      assert.equal(catalog.catalog.catalogRevision, operation === 'upload' ? 1 : 2);
      assert.equal(catalog.catalog.evidence.length, operation === 'upload' ? 1 : 0);
    }
  }
});

test('authentication has a ten-second deadline even without a socket signal', async t => {
  const state = await setup(), entered = deferred<void>(), release = deferred<{ userId: string }>();
  state.deps.authenticate = async () => { entered.resolve(); return release.promise; };
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const pending = state.upload(); await entered.promise;
  t.mock.timers.tick(10_000);
  error(await pending, 503, 'SERVICE_UNAVAILABLE');
  t.mock.timers.reset();
  state.deps.authenticate = async () => ({ userId: 'alice' });
  uploaded(await state.upload());
  release.resolve({ userId: 'alice' }); await new Promise<void>(resolve => setImmediate(resolve));
  const catalog = await state.repository.readEvidenceCatalogForUser('alice', 'case-a');
  assert.equal(catalog.status, 'found');
  if (catalog.status === 'found') assert.equal(catalog.catalog.catalogRevision, 1);
});

test('an already-aborted call never authenticates and cancellation cannot release active publication', async () => {
  const state = await setup(), controller = new AbortController(); controller.abort();
  let calls = 0;
  state.deps.authenticate = async () => { calls++; return { userId: 'alice' }; };
  error(await handleUploadEvidence({ body: state.request, bearerToken: 'alice-token', signal: controller.signal }, state.deps), 503, 'SERVICE_UNAVAILABLE');
  assert.equal(calls, 0);
  const active = new AbortController(), entered = deferred<void>(), release = deferred<void>();
  const save = state.repository.saveEvidenceIfCurrent.bind(state.repository);
  state.repository.saveEvidenceIfCurrent = async input => { entered.resolve(); await release.promise; return save(input); };
  const pending = handleUploadEvidence({ body: state.request, bearerToken: 'alice-token', signal: active.signal }, state.deps);
  await entered.promise; active.abort();
  error(await state.upload(), 429, 'UPLOAD_BUSY');
  release.resolve(); uploaded(await pending);
});

test('body and authentication objects cannot retarget an upload across awaits', async () => {
  const state = await setup(), body = { ...state.request }, user = { userId: 'alice' };
  state.deps.authenticate = async () => {
    body.caseId = 'case-b'; body.findingId = 'finding-b'; body.imageBase64 = 'PRIVATE changed body'; return user;
  };
  const load = state.repository.loadForUser.bind(state.repository);
  state.repository.loadForUser = async (userId, caseId) => {
    assert.equal(userId, 'alice'); assert.equal(caseId, 'case-a'); user.userId = 'bob'; return load(userId, caseId);
  };
  const result = uploaded(await state.upload(body));
  assert.equal(result.caseId, 'case-a'); assert.equal(result.evidence.findingId, 'finding-a');
});

test('delete captures its request and authenticated owner before adapters yield', async () => {
  const state = await setup(); uploaded(await state.upload());
  const body = { ...deletion }, user = { userId: 'alice' };
  state.deps.authenticate = async () => { body.caseId = 'case-b'; body.evidenceId = 'photo-c'; return user; };
  const load = state.repository.loadForUser.bind(state.repository);
  state.repository.loadForUser = async (owner, caseId) => { user.userId = 'bob'; return load(owner, caseId); };
  const result = await state.remove(body);
  assert.equal(result.status, 200); assert.ok('deleted' in result.body); assert.equal(result.body.caseId, 'case-a');
});

test('final atomic publication rejects catalog races after preflight and decoding', async () => {
  const state = await setup(), save = state.repository.saveEvidenceIfCurrent.bind(state.repository);
  state.repository.saveEvidenceIfCurrent = async input => {
    const winner = await save({ ...input, evidenceId: 'photo-b' }); assert.equal(winner.status, 'saved');
    return save(input);
  };
  error(await state.upload(), 409, 'EVIDENCE_CONFLICT');
  const catalog = await state.repository.readEvidenceCatalogForUser('alice', 'case-a');
  assert.equal(catalog.status, 'found');
  if (catalog.status === 'found') assert.deepEqual(catalog.catalog.evidence.map(item => item.evidenceId), ['photo-b']);
});

test('delete cannot remove a newer replacement created after its preflight', async () => {
  const state = await setup(); uploaded(await state.upload());
  const remove = state.repository.deleteEvidenceIfCurrent.bind(state.repository);
  state.repository.deleteEvidenceIfCurrent = async input => {
    const newer = await state.repository.saveEvidenceIfCurrent({ ...input, findingId: 'finding-a',
      image: await sanitizeEvidenceImage(await imagePromise), capturedAt: null, preparedAt: NOW });
    assert.equal(newer.status, 'saved'); return remove(input);
  };
  error(await state.remove(), 409, 'EVIDENCE_CONFLICT');
});

test('atomic upload and delete reject a case edit that wins after preflight', async () => {
  for (const operation of ['upload', 'delete'] as const) {
    const state = await setup();
    if (operation === 'delete') uploaded(await state.upload());
    const { revision: _revision, ...draft } = snapshot();
    draft.profile.city = 'Fictional changed city';
    if (operation === 'upload') {
      const save = state.repository.saveEvidenceIfCurrent.bind(state.repository);
      state.repository.saveEvidenceIfCurrent = async input => {
        assert.equal((await state.repository.replaceIfCurrent('alice', 'case-a', 1, draft)).status, 'saved');
        return save(input);
      };
      error(await state.upload(), 409, 'CASE_REVISION_MISMATCH');
    } else {
      const remove = state.repository.deleteEvidenceIfCurrent.bind(state.repository);
      state.repository.deleteEvidenceIfCurrent = async input => {
        assert.equal((await state.repository.replaceIfCurrent('alice', 'case-a', 1, draft)).status, 'saved');
        return remove(input);
      };
      error(await state.remove(), 409, 'CASE_REVISION_MISMATCH');
    }
    const catalog = await state.repository.readEvidenceCatalogForUser('alice', 'case-a');
    assert.equal(catalog.status, 'found');
    if (catalog.status === 'found') {
      assert.equal(catalog.catalog.caseRevision, 2);
      assert.equal(catalog.catalog.catalogRevision, operation === 'upload' ? 0 : 1);
    }
  }
});

test('a lost storage response remains uncertain and the authoritative catalog supports recovery', async () => {
  const state = await setup(), save = state.repository.saveEvidenceIfCurrent.bind(state.repository);
  let writes = 0;
  state.repository.saveEvidenceIfCurrent = async input => {
    writes++; assert.equal((await save(input)).status, 'saved'); throw new Error('PRIVATE lost successful upload');
  };
  error(await state.upload(), 503, 'SERVICE_UNAVAILABLE'); assert.equal(writes, 1);
  const current = await state.repository.readEvidenceCatalogForUser('alice', 'case-a');
  assert.equal(current.status, 'found');
  if (current.status === 'found') assert.equal(current.catalog.evidence[0].evidenceRevision, 1);
  const remove = state.repository.deleteEvidenceIfCurrent.bind(state.repository);
  let deletes = 0;
  state.repository.deleteEvidenceIfCurrent = async input => {
    deletes++; assert.equal((await remove(input)).status, 'deleted'); throw new Error('PRIVATE lost successful delete');
  };
  error(await state.remove(), 503, 'SERVICE_UNAVAILABLE'); assert.equal(deletes, 1);
  const after = await state.repository.readEvidenceCatalogForUser('alice', 'case-a');
  assert.equal(after.status, 'found');
  if (after.status === 'found') { assert.equal(after.catalog.catalogRevision, 2); assert.deepEqual(after.catalog.evidence, []); }
});

test('storage quota and dependency failures produce bounded safe errors and release upload admission', async () => {
  const full = await setup({ maxBytes: 0, maxAssets: 0, maxArtifacts: 0 });
  error(await full.upload(), 507, 'STORAGE_LIMIT_REACHED');
  for (const layer of ['authenticate', 'load', 'catalog', 'save'] as const) {
    const state = await setup();
    const rejected = async () => { throw new Error('PRIVATE storage and token detail'); };
    if (layer === 'authenticate') state.deps.authenticate = rejected;
    if (layer === 'load') state.repository.loadForUser = rejected;
    if (layer === 'catalog') state.repository.readEvidenceCatalogForUser = rejected;
    if (layer === 'save') state.repository.saveEvidenceIfCurrent = rejected;
    error(await state.upload(), 503, 'SERVICE_UNAVAILABLE');
    error(await state.upload(), 503, 'SERVICE_UNAVAILABLE');
  }
  const state = await setup(); uploaded(await state.upload());
  state.repository.deleteEvidenceIfCurrent = async () => { throw new Error('PRIVATE delete failure'); };
  error(await state.remove(), 503, 'SERVICE_UNAVAILABLE');
});

test('malformed identities and repository records never produce successful private responses', async () => {
  for (const user of [undefined, [], { userId: '' }, { userId: 'x\n' }]) {
    const state = await setup(); state.deps.authenticate = async () => user as never;
    error(await state.upload(), 500, 'INTERNAL_ERROR');
  }
  for (const mutate of [
    (value: any) => { value.caseId = 'case-b'; },
    (value: any) => { value.profile.ownerConsentReported = 'false'; },
    (value: any) => { value.findings[0].private = 'PRIVATE wrong data'; },
  ]) {
    const state = await setup(), value = snapshot(); mutate(value);
    state.repository.loadForUser = async () => value;
    error(await state.upload(), 500, 'INTERNAL_ERROR');
  }
  for (const catalog of [null, { schemaVersion: '1', caseId: 'case-b', caseRevision: 1, catalogRevision: 0, evidence: [] },
    { schemaVersion: '1', caseId: 'case-a', caseRevision: 1, catalogRevision: 0, evidence: [{ private: 'PRIVATE image' }] }]) {
    const state = await setup(); state.repository.readEvidenceCatalogForUser = async () => ({ status: 'found', catalog }) as never;
    error(await state.upload(), 500, 'INTERNAL_ERROR');
  }
});

test('successful adapter results must match exact case, asset and catalog revisions without extra fields', async () => {
  for (const mutate of [
    (value: any) => { value.asset.descriptor.caseId = 'case-b'; },
    (value: any) => { value.asset.descriptor.evidenceId = 'photo-b'; },
    (value: any) => { value.asset.descriptor.findingId = 'finding-b'; },
    (value: any) => { value.asset.descriptor.evidenceRevision = 5; },
    (value: any) => { value.catalogRevision = 5; },
    (value: any) => { value.asset.descriptor.capturedAt = '2026-10-17T21:00:00Z'; },
    (value: any) => { value.asset.descriptor.preparedAt = '2026-10-17T21:00:00Z'; },
    (value: any) => { value.asset.bytes.fill(0); },
    (value: any) => { value.private = 'PRIVATE returned original'; },
  ]) {
    const state = await setup(), save = state.repository.saveEvidenceIfCurrent.bind(state.repository);
    state.repository.saveEvidenceIfCurrent = async input => { const result = await save(input); mutate(result); return result; };
    error(await state.upload(), 500, 'INTERNAL_ERROR');
  }
  for (const result of [{ status: 'deleted', evidenceRevision: 3, catalogRevision: 2 },
    { status: 'deleted', evidenceRevision: 2, catalogRevision: 3 },
    { status: 'deleted', evidenceRevision: 2, catalogRevision: 2, private: 'PRIVATE original' }]) {
    const state = await setup(); uploaded(await state.upload());
    state.repository.deleteEvidenceIfCurrent = async () => result as never;
    error(await state.remove(), 500, 'INTERNAL_ERROR');
  }
});

test('output descriptors are detached from a mutable repository result', async () => {
  const state = await setup(), save = state.repository.saveEvidenceIfCurrent.bind(state.repository);
  let returned: Awaited<ReturnType<typeof save>> | undefined;
  state.repository.saveEvidenceIfCurrent = async input => { returned = await save(input); return returned; };
  const result = uploaded(await state.upload());
  assert.equal(returned?.status, 'saved');
  if (returned?.status === 'saved') { returned.asset.descriptor.findingId = 'PRIVATE late mutation'; returned.asset.bytes.fill(0); }
  assert.equal(result.evidence.findingId, 'finding-a'); assert.equal(result.evidence.width, 3);
});

test('upload captures the saved catalog revision before asynchronous result validation', async () => {
  const state = await setup(), save = state.repository.saveEvidenceIfCurrent.bind(state.repository);
  let mutated = false;
  state.repository.saveEvidenceIfCurrent = async input => {
    const result = await save(input);
    if (result.status !== 'saved') return result;
    const asset = result.asset;
    Object.defineProperty(result, 'asset', { enumerable: true, get() {
      queueMicrotask(() => { result.catalogRevision = 99; mutated = true; });
      return asset;
    } });
    return result;
  };
  const result = uploaded(await state.upload());
  assert.equal(mutated, true);
  assert.equal(result.catalogRevision, 1);
  assert.equal(result.evidence.evidenceRevision, 1);
});
