import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import type { AddressInfo } from 'node:net';
import { PDFDocument } from 'pdf-lib';
import { createDemoEvidenceImage } from '../fixtures/demo-evidence.ts';
import { createDemoFormArtifact } from '../fixtures/demo-form-template.ts';
import { demoProgram } from '../fixtures/demo-program.ts';
import { handleDraftExport, type DraftExportDependencies, type DraftExportResult, type ExportRoute } from '../src/api/draft-export.ts';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { createFormAnswerContext, createSavedFormAnswers } from '../src/forms/form-answers.ts';
import type { CaseSnapshot } from '../src/types.ts';
import type { ExportArtifactMetadata } from '../src/exports/types.ts';
import type { ExportPublishInput } from '../src/evidence/repository.ts';
import { canonicalJson } from '../src/evidence/validation.ts';
import { matchPrograms } from '../src/matcher.ts';
import { REVIEWED_TEXT_RENDERING_VERSION } from '../src/pdf/reviewed-text-font.ts';

const NOW = '2026-10-17T22:00:00.000Z';
function makeCase(): CaseSnapshot {
  return { schemaVersion: '1', caseId: 'export-case', revision: 1,
    profile: { city: 'Demo City', county: null, healthPlan: 'Example Plan', tenure: null,
      ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [],
    findings: [{ id: 'finding', room: 'entrance', observation: 'Fictional entrance step.', reviewState: 'confirmed',
      evidenceIds: ['photo-a', 'photo-b'], measurements: [{ type: 'step height', value: 20, unit: 'mm', method: 'manual', confirmed: true }] }] };
}
async function setup() {
  const snapshot = makeCase(), repository = new MemoryCaseRepository([{ userId: 'alice', snapshot }]);
  const image = await createDemoEvidenceImage(), form = await createDemoFormArtifact(demoProgram.programId);
  const binding = { userId: 'alice', caseId: snapshot.caseId, revision: 1, expectedCatalogRevision: 0 };
  assert.equal((await repository.saveEvidenceIfCurrent({ ...binding, evidenceId: 'photo-a', expectedEvidenceRevision: 0,
    findingId: 'finding', image, capturedAt: null, preparedAt: NOW })).status, 'saved');
  let time = NOW, sequence = 0;
  const program = { ...structuredClone(demoProgram), recheckAfter: null };
  const deps: DraftExportDependencies = { authenticate: async token => token === 'alice-token' ? { userId: 'alice' }
    : token === 'bob-token' ? { userId: 'bob' } : null, cases: repository,
    loadRegistry: async () => [program], loadFormTemplate: async () => form, now: () => new Date(time),
    allowDemoPrograms: true, newArtifactId: () => `artifact-${++sequence}` };
  const base = { schemaVersion: '1', caseId: snapshot.caseId, expectedCaseRevision: 1 };
  const request = { ...base, programId: program.programId, expectedFormContextId: createFormAnswerContext(form.template).formContextId,
    expectedAnswerRevision: 0, expectedEvidenceCatalogRevision: 1, generationKey: 'export-key-001',
    selectedEvidence: [{ evidenceId: 'photo-a', expectedEvidenceRevision: 1, reviewedForExport: true }] };
  const send = (route: ExportRoute, body: unknown = request, token: string | null = 'alice-token') => handleDraftExport({ body, bearerToken: token }, deps, route);
  const download = (artifact: ExportArtifactMetadata, token = 'alice-token') => send('download-draft-export', { ...base, artifactId: artifact.artifactId }, token);
  return { snapshot, repository, image, form, binding, deps, base, program, request, send, download, setNow: (next: string) => { time = next; } };
}
function metadata(result: DraftExportResult): ExportArtifactMetadata {
  assert.equal(result.status, 200, JSON.stringify(result.body)); assert.ok('artifactId' in result.body);
  return result.body;
}
function error(result: DraftExportResult, status: number, code: string) {
  assert.equal(result.status, status, JSON.stringify(result.body)); assert.ok('error' in result.body);
  assert.equal(result.body.error.code, code); assert.equal(result.headers['Cache-Control'], 'no-store');
}

test('private catalog, preview, reviewed export and download preserve exact identities and bytes', async () => {
  const state = await setup();
  const listed = await state.send('list-evidence', state.base); assert.equal(listed.status, 200); assert.ok('evidence' in listed.body);
  assert.equal(listed.body.evidence.length, 1); assert.equal('bytes' in listed.body.evidence[0], false);
  const preview = await state.send('download-evidence', { ...state.base, expectedCatalogRevision: 1, evidenceId: 'photo-a', expectedEvidenceRevision: 1 });
  assert.ok(preview.body instanceof Uint8Array); assert.equal(preview.headers['Content-Type'], 'image/png');
  assert.deepEqual(preview.body, state.image.bytes);
  const artifact = metadata(await state.send('create-draft-export'));
  assert.equal(artifact.status, 'draft'); assert.equal(artifact.pageCount, 2); assert.equal(artifact.selectedEvidence[0].reviewedBy, 'alice');
  assert.deepEqual(artifact.warnings, ['INCOMPLETE_DRAFT', 'NOT_SUBMITTED', 'POLICY_CURRENTNESS_UNKNOWN']);
  assert.equal(artifact.expiresAt, '2026-10-17T22:15:00.000Z'); assert.equal('storageReference' in artifact, false);
  assert.ok(artifact.missingItems.find(item => item.id === 'form-rendering')!.description.includes('Inspect'));
  const downloaded = await state.download(artifact); assert.ok(downloaded.body instanceof Uint8Array);
  assert.equal(downloaded.headers['Content-Type'], 'application/pdf'); assert.equal(downloaded.headers['X-Content-Type-Options'], 'nosniff');
  assert.equal(createHash('sha256').update(downloaded.body).digest('hex'), artifact.sha256);
  const pdf = await PDFDocument.load(downloaded.body); assert.equal(pdf.getPageCount(), 2); assert.equal(pdf.getForm().getFields().length, 0);
});

test('authorization never treats an evidence or artifact ID as a credential', async () => {
  const state = await setup(), artifact = metadata(await state.send('create-draft-export'));
  for (const route of ['list-evidence', 'create-draft-export'] as const) {
    error(await state.send(route, route === 'list-evidence' ? state.base : state.request, null), 401, 'UNAUTHENTICATED');
    error(await state.send(route, route === 'list-evidence' ? state.base : state.request, 'bob-token'), 404, 'CASE_NOT_FOUND');
  }
  error(await state.download(artifact, 'bob-token'), 404, 'ARTIFACT_NOT_FOUND');
  error(await state.send('download-evidence', { ...state.base, expectedCatalogRevision: 1, evidenceId: 'photo-a', expectedEvidenceRevision: 1 }, 'bob-token'), 404, 'ARTIFACT_NOT_FOUND');
});

test('request validation rejects unreviewed selections, duplicates, injected paths and private field overrides', async () => {
  const state = await setup();
  for (const request of [{ ...state.request, privatePath: '/private/photo' }, { ...state.request, status: 'submitted' },
    { ...state.request, selectedEvidence: [{ ...state.request.selectedEvidence[0], reviewedForExport: false }] },
    { ...state.request, selectedEvidence: [...state.request.selectedEvidence, ...state.request.selectedEvidence] },
    { ...state.request, expectedAnswerRevision: -1 }, { ...state.request, generationKey: 'too short!' }]) {
    error(await state.send('create-draft-export', request), 400, 'INVALID_REQUEST');
  }
  error(await state.send('create-draft-export', { ...state.request, expectedFormContextId: 'a'.repeat(64) }), 409, 'FORM_CONTEXT_MISMATCH');
  error(await state.send('create-draft-export', { ...state.request, expectedAnswerRevision: 1 }), 409, 'FORM_ANSWER_REVISION_MISMATCH');
});

test('empty explicit selection exports only the incomplete form and exact-key retries reuse the artifact', async () => {
  const state = await setup(), request = { ...state.request, selectedEvidence: [] };
  const first = metadata(await state.send('create-draft-export', request)); assert.equal(first.pageCount, 1);
  state.setNow('2026-10-17T22:01:00.000Z');
  assert.deepEqual(metadata(await state.send('create-draft-export', request)), first);
  error(await state.send('create-draft-export'), 409, 'EXPORT_GENERATION_CONFLICT');
});

test('font renderer identity invalidates legacy artifacts without changing their readable metadata schema', async () => {
  const state = await setup();
  const publish = state.repository.publishExportIfCurrent.bind(state.repository);
  let published: ExportPublishInput | undefined;
  state.repository.publishExportIfCurrent = async input => { published = structuredClone(input); return publish(input); };
  const current = metadata(await state.send('create-draft-export'));
  assert.ok(published);
  const review = await state.repository.loadExportReviewForUser({ userId: 'alice', caseId: state.snapshot.caseId,
    revision: 1, expectedCatalogRevision: 1, programId: state.program.programId, selections: published.selections });
  assert.equal(review.status, 'found'); if (review.status !== 'found') return;
  const { snapshot, answers, evidence, catalogRevision } = review.snapshot;
  const legacyContext = { renderingVersion: 'draft-export-v1', snapshot, program: state.program,
    match: matchPrograms(snapshot, [state.program], { evaluatedAt: NOW, evaluationDate: NOW.slice(0, 10) }).matches[0],
    template: state.form.template, formAnswers: answers, catalogRevision, evidence, evaluationDate: NOW.slice(0, 10) };
  const digest = (value: unknown) => createHash('sha256').update(canonicalJson(value)).digest('hex');
  const oldFingerprint = digest(legacyContext);
  assert.notEqual(current.exportContextId, oldFingerprint);
  assert.equal(current.exportContextId, digest({ ...legacyContext, textRenderingVersion: REVIEWED_TEXT_RENDERING_VERSION }));
  const legacy = structuredClone(published);
  legacy.contextFingerprint = oldFingerprint;
  legacy.generationKey = 'legacy-renderer-export';
  legacy.artifact.metadata.exportContextId = oldFingerprint;
  legacy.artifact.metadata.artifactId = 'legacy-renderer-artifact';
  assert.equal((await publish(legacy)).status, 'saved');
  error(await state.download(legacy.artifact.metadata), 409, 'EXPORT_GENERATION_CONFLICT');
  error(await state.send('create-draft-export', { ...state.request, generationKey: legacy.generationKey }), 409, 'EXPORT_GENERATION_CONFLICT');
  assert.equal((await state.download(current)).status, 200);
  metadata(await state.send('create-draft-export', { ...state.request, generationKey: 'new-renderer-export' }));
});

test('artifact expiry is exclusive and cannot be revived by reusing its generation key', async () => {
  const state = await setup(), artifact = metadata(await state.send('create-draft-export'));
  state.setNow(artifact.expiresAt);
  error(await state.download(artifact), 410, 'EXPORT_EXPIRED');
  error(await state.send('create-draft-export'), 409, 'EXPORT_GENERATION_CONFLICT');
  metadata(await state.send('create-draft-export', { ...state.request, generationKey: 'replacement-export' }));
});

test('known past or exact policy recheck boundaries return an expiry error, not a server failure', async () => {
  for (const deadline of ['2026-10-17T21:59:59.000Z', NOW]) {
    const state = await setup();
    state.deps.loadRegistry = async () => [{ ...state.program, recheckAfter: deadline }];
    error(await state.send('create-draft-export'), 410, 'EXPORT_EXPIRED');
  }
  const state = await setup();
  state.deps.loadRegistry = async () => [{ ...state.program, recheckAfter: '2026-10-17T22:03:00.000Z' }];
  assert.equal(metadata(await state.send('create-draft-export')).expiresAt, '2026-10-17T22:03:00.000Z');
});

test('unsupported reviewed form text fails without publishing a partial draft', async () => {
  const state = await setup();
  const answers = createSavedFormAnswers({ snapshot: { ...state.snapshot, revision: 2 }, context: createFormAnswerContext(state.form.template),
    answerRevision: 1, answers: [{ key: 'memberFirstName', value: 'Example \u0378', reviewState: 'reviewed' }], updatedAt: NOW, updatedBy: 'alice' });
  await state.repository.saveFormAnswersIfCurrent({ userId: 'alice', caseId: state.snapshot.caseId, revision: 1,
    programId: state.program.programId, expectedAnswerRevision: 0, answers });
  error(await state.send('create-draft-export', { ...state.request, expectedCaseRevision: 2, expectedAnswerRevision: 1 }), 422, 'EXPORT_REVIEW_REQUIRED');
  assert.equal((await state.repository.readExportForUser({ userId: 'alice', caseId: state.snapshot.caseId, artifactId: 'artifact-1' })).status, 'not_found');
});

test('oversized selection uses review-required and never loads forms or publishes a partial draft', async () => {
  const state = await setup();
  state.repository.loadExportSnapshotForUser = async () => ({ status: 'selection_too_large' });
  let loadedRegistry = false, published = false;
  state.deps.loadRegistry = async () => { loadedRegistry = true; return [state.program]; };
  state.repository.publishExportIfCurrent = async () => { published = true; return { status: 'quota_exceeded' }; };
  const result = await state.send('create-draft-export');
  error(result, 422, 'EXPORT_REVIEW_REQUIRED');
  assert.ok('error' in result.body && result.body.error.message.includes('fewer or smaller images'));
  assert.equal(loadedRegistry, false); assert.equal(published, false);
});

test('handler independently rejects excessive decoded pixels before cloning adapter image buffers', async () => {
  const state = await setup();
  const loaded = await state.repository.loadExportSnapshotForUser({ userId: 'alice', caseId: state.snapshot.caseId,
    revision: 1, expectedCatalogRevision: 1, programId: state.program.programId,
    selections: [{ evidenceId: 'photo-a', expectedEvidenceRevision: 1, reviewedForExport: true }] });
  assert.equal(loaded.status, 'found');
  if (loaded.status !== 'found') throw new Error('Missing export fixture.');
  loaded.snapshot.assets = ['photo-a', 'photo-b'].map(evidenceId => ({ bytes: state.image.bytes,
    descriptor: { ...loaded.snapshot.assets[0].descriptor, evidenceId, width: 4000, height: 3000 } }));
  Object.defineProperty(loaded.snapshot.snapshot.profile, 'city', { enumerable: true,
    get() { throw new Error('Clone was attempted before the selection budget check.'); } });
  state.repository.loadExportSnapshotForUser = async () => loaded;
  error(await state.send('create-draft-export', { ...state.request,
    selectedEvidence: ['photo-a', 'photo-b'].map(evidenceId => ({ evidenceId, expectedEvidenceRevision: 1, reviewedForExport: true })) }),
  422, 'EXPORT_REVIEW_REQUIRED');
});

test('case answer saves, evidence deletion and changed registry invalidate previously exported bytes', async () => {
  for (const change of ['answers', 'delete', 'registry'] as const) {
    const state = await setup(), artifact = metadata(await state.send('create-draft-export'));
    if (change === 'answers') {
      const answers = createSavedFormAnswers({ snapshot: { ...state.snapshot, revision: 2 }, context: createFormAnswerContext(state.form.template),
        answerRevision: 1, answers: [{ key: 'memberFirstName', value: 'Fictional Ada', reviewState: 'reviewed' }], updatedAt: NOW, updatedBy: 'alice' });
      await state.repository.saveFormAnswersIfCurrent({ userId: 'alice', caseId: state.snapshot.caseId, revision: 1,
        programId: state.program.programId, expectedAnswerRevision: 0, answers });
    } else if (change === 'delete') await state.repository.deleteEvidenceIfCurrent({ ...state.binding, expectedCatalogRevision: 1,
      evidenceId: 'photo-a', expectedEvidenceRevision: 1 });
    else state.program.ruleVersion = 'changed-rule';
    error(await state.download(artifact), 409, change === 'answers' ? 'CASE_REVISION_MISMATCH' : change === 'delete' ? 'EVIDENCE_CONFLICT' : 'EXPORT_GENERATION_CONFLICT');
  }
});

test('no artifact is published when evidence changes while a form is loading', async () => {
  const state = await setup(); let first = true;
  state.deps.loadFormTemplate = async () => {
    if (first) { first = false; await state.repository.deleteEvidenceIfCurrent({ ...state.binding, expectedCatalogRevision: 1,
      evidenceId: 'photo-a', expectedEvidenceRevision: 1 }); }
    return state.form;
  };
  error(await state.send('create-draft-export'), 409, 'EVIDENCE_CONFLICT');
  assert.equal((await state.repository.readExportForUser({ userId: 'alice', caseId: state.snapshot.caseId, artifactId: 'artifact-1' })).status, 'not_found');
});

test('server configuration and renderer errors fail closed with safe messages', async () => {
  const state = await setup();
  state.deps.loadFormTemplate = async () => null;
  error(await state.send('create-draft-export'), 409, 'FORM_NOT_AVAILABLE');
  state.deps.loadFormTemplate = async () => { throw new Error('private/path/secret'); };
  const unavailable = await state.send('create-draft-export'); error(unavailable, 503, 'SERVICE_UNAVAILABLE');
  assert.equal(JSON.stringify(unavailable).includes('secret'), false);
  state.deps.loadFormTemplate = async () => ({ ...state.form, bytes: new Uint8Array([1, 2, 3]) });
  error(await state.send('create-draft-export'), 500, 'INTERNAL_ERROR');
});

test('render admission rejects overlapping jobs and releases the slot after failure', async () => {
  const state = await setup(); let enter!: () => void, release!: () => void;
  const entered = new Promise<void>(resolve => { enter = resolve; }), blocked = new Promise<void>(resolve => { release = resolve; });
  state.deps.loadRegistry = async () => { enter(); await blocked; return [state.program]; };
  const first = state.send('create-draft-export'); await entered;
  error(await state.send('create-draft-export'), 429, 'EXPORT_BUSY'); release(); metadata(await first);
  metadata(await state.send('create-draft-export'));
});

test('adapter cannot mutate reviewed selections or publication expectations across awaits', async () => {
  const state = await setup(); const originalLoad = state.repository.loadExportSnapshotForUser.bind(state.repository);
  state.repository.loadExportSnapshotForUser = async input => {
    const result = await originalLoad(input); input.selections.length = 0; return result;
  };
  const originalPublish = state.repository.publishExportIfCurrent.bind(state.repository);
  state.repository.publishExportIfCurrent = async input => {
    const result = await originalPublish(input); input.artifact.metadata.sha256 = 'a'.repeat(64); return result;
  };
  assert.equal(metadata(await state.send('create-draft-export')).selectedEvidence.length, 1);
  assert.equal(state.request.selectedEvidence.length, 1);
});

test('raw stored bytes are detached before an injected clock can mutate them', async () => {
  const state = await setup(), artifact = metadata(await state.send('create-draft-export'));
  let returned: Uint8Array | null = null;
  const original = state.repository.readExportForUserIfCurrent.bind(state.repository);
  state.repository.readExportForUserIfCurrent = async input => {
    const result = await original(input); if (result.status === 'found') returned = result.artifact.bytes; return result;
  };
  state.deps.now = () => { returned?.fill(0); return new Date(NOW); };
  const result = await state.download(artifact); assert.ok(result.body instanceof Uint8Array);
  assert.equal(createHash('sha256').update(result.body).digest('hex'), artifact.sha256);
});

test('HTTP delivers authenticated binary bytes without public URLs or JSON encoding', async t => {
  const state = await setup();
  const server = createMatchingServer({ ...state.deps, cases: state.repository }, undefined, undefined, state.deps);
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.close(); server.closeAllConnections(); });
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/`;
  const post = (path: string, body: unknown, token = 'alice-token') => fetch(url + path, { method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const created = await post('create-draft-export', state.request); assert.equal(created.status, 200);
  const artifact = await created.json() as ExportArtifactMetadata;
  const download = await post('download-draft-export', { ...state.base, artifactId: artifact.artifactId });
  assert.equal(download.status, 200); assert.equal(download.headers.get('content-type'), 'application/pdf');
  assert.equal(download.headers.get('cache-control'), 'no-store');
  const bytes = new Uint8Array(await download.arrayBuffer()); assert.equal(bytes.length, artifact.byteLength);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), artifact.sha256);
  assert.equal((await post('download-draft-export', { ...state.base, artifactId: artifact.artifactId }, 'bob-token')).status, 404);
  assert.equal((await fetch(url + 'download-draft-export')).status, 405);
});
