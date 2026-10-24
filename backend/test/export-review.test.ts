import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { handleDraftExport, type DraftExportDependencies } from '../src/api/draft-export.ts';
import { createFormAnswerContext } from '../src/forms/form-answers.ts';
import { createDemoFormArtifact } from '../fixtures/demo-form-template.ts';
import { demoProgram } from '../fixtures/demo-program.ts';
import { OWNER, OTHER, FORM_CONTEXT, create, answerInput, imageInput, publication } from './postgres/fixtures.ts';

async function seeded(answers = true) {
  const repo = new MemoryCaseRepository([]); let snapshot = await create(repo);
  if (answers) {
    assert.equal((await repo.saveFormAnswersIfCurrent(answerInput(snapshot))).status, 'saved');
    snapshot = (await repo.loadForUser(OWNER, snapshot.caseId))!;
  }
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(snapshot))).status, 'saved');
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(snapshot, 1, 'fictional-photo-b'))).status, 'saved');
  const input = { userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision, expectedCatalogRevision: 2,
    programId: FORM_CONTEXT.programId, selections: ['fictional-photo-b', 'fictional-photo-a'].map(evidenceId =>
      ({ evidenceId, expectedEvidenceRevision: 1, reviewedForExport: true as const })) };
  return { repo, snapshot, input };
}

test('memory review preserves full snapshot bindings and selection order while exposing only detached metadata', async () => {
  const { repo, input } = await seeded();
  const full = await repo.loadExportSnapshotForUser(input), review = await repo.loadExportReviewForUser(input);
  assert.equal(full.status, 'found'); assert.equal(review.status, 'found');
  if (full.status !== 'found' || review.status !== 'found') throw new Error('Missing fictional export context.');
  const { assets, ...bindings } = full.snapshot;
  assert.deepEqual(review.snapshot, { ...bindings, evidence: assets.map(asset => asset.descriptor) });
  assert.equal('assets' in review.snapshot, false);
  assert.equal(review.snapshot.evidence.some(item => 'bytes' in item), false);
  const expected = structuredClone(review.snapshot);
  review.snapshot.snapshot.profile.city = 'Caller mutation';
  review.snapshot.evidence[0].sha256 = 'f'.repeat(64);
  review.snapshot.answers!.answers[0].value = 'Caller mutation';
  assert.deepEqual(await repo.loadExportReviewForUser(input), { status: 'found', snapshot: expected });
  assert.deepEqual((await repo.loadExportSnapshotForUser(input)), full);
});

test('memory metadata review keeps ownership, case/catalog/asset revisions and deletion fences', async () => {
  const { repo, input } = await seeded();
  for (const changed of [{ ...input, userId: OTHER }, { ...input, revision: input.revision + 1 },
    { ...input, expectedCatalogRevision: 1 }, { ...input, selections: [{ ...input.selections[0], expectedEvidenceRevision: 2 }] }]) {
    assert.deepEqual(await repo.loadExportReviewForUser(changed), await repo.loadExportSnapshotForUser(changed));
    assert.notEqual((await repo.loadExportReviewForUser(changed)).status, 'found');
  }
  assert.equal((await repo.deleteEvidenceIfCurrent({ ...input, evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 })).status, 'deleted');
  assert.deepEqual(await repo.loadExportReviewForUser(input), { status: 'evidence_conflict' });
  assert.deepEqual(await repo.loadExportReviewForUser({ ...input, expectedCatalogRevision: 3 }), { status: 'evidence_conflict' });
});

async function published() {
  const state = await seeded();
  const output = await publication(state.repo, state.snapshot, 2);
  assert.equal((await state.repo.publishExportIfCurrent(output)).status, 'saved');
  const request = { userId: OWNER, caseId: state.snapshot.caseId, artifactId: output.artifact.metadata.artifactId,
    contextFingerprint: output.contextFingerprint, checkedAt: output.checkedAt };
  return { ...state, output, request };
}

test('memory final metadata review returns detached current publication metadata and preserves owner/context checks', async () => {
  const { repo, output, request } = await published();
  const expected = structuredClone(output.artifact.metadata);
  const pending = repo.reviewExportForUserIfCurrent(request);
  const original = { ...request }; request.userId = OTHER; request.artifactId = 'caller-mutation';
  const result = await pending;
  assert.deepEqual(result, { status: 'found', artifact: expected });
  if (result.status !== 'found') throw new Error('Missing fictional publication.');
  assert.equal('bytes' in result.artifact, false);
  result.artifact.selectedEvidence[0].sha256 = 'a'.repeat(64);
  assert.deepEqual(await repo.reviewExportForUserIfCurrent(original), { status: 'found', artifact: expected });
  for (const changed of [{ ...original, userId: OTHER }, { ...original, caseId: 'unowned-case' },
    { ...original, artifactId: 'missing-artifact' }, { ...original, contextFingerprint: 'a'.repeat(64) }]) {
    assert.deepEqual(await repo.reviewExportForUserIfCurrent(changed), await repo.readExportForUserIfCurrent(changed));
    assert.notEqual((await repo.reviewExportForUserIfCurrent(changed)).status, 'found');
  }
});

test('memory final metadata review retains expiry, monotonic clock and stale evidence checks', async () => {
  const { repo, output, request } = await published();
  const later = new Date(Date.parse(request.checkedAt) + 1000).toISOString();
  assert.equal((await repo.reviewExportForUserIfCurrent({ ...request, checkedAt: later })).status, 'found');
  assert.deepEqual(await repo.reviewExportForUserIfCurrent(request), { status: 'expired' });
  assert.deepEqual(await repo.reviewExportForUserIfCurrent({ ...request, checkedAt: output.artifact.metadata.expiresAt }), { status: 'expired' });
  assert.deepEqual(await repo.reviewExportForUserIfCurrent({ ...request, checkedAt: later }), { status: 'expired' });
  assert.deepEqual(await repo.readExportForUserIfCurrent({ ...request, checkedAt: later }), { status: 'expired' });
  const changed = await published();
  assert.equal((await changed.repo.deleteEvidenceIfCurrent({ ...changed.input,
    evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 })).status, 'deleted');
  assert.deepEqual(await changed.repo.reviewExportForUserIfCurrent(changed.request), { status: 'evidence_conflict' });
  assert.deepEqual(await changed.repo.reviewExportForUserIfCurrent(changed.request), await changed.repo.readExportForUserIfCurrent(changed.request));
  const answered = await published();
  assert.equal((await answered.repo.saveFormAnswersIfCurrent(answerInput(answered.snapshot, 1))).status, 'saved');
  assert.deepEqual(await answered.repo.reviewExportForUserIfCurrent(answered.request), { status: 'conflict' });
  assert.deepEqual(await answered.repo.reviewExportForUserIfCurrent(answered.request), await answered.repo.readExportForUserIfCurrent(answered.request));
});

async function apiSetup() {
  const { repo, input, snapshot } = await seeded(false);
  const form = await createDemoFormArtifact(demoProgram.programId);
  const deps: DraftExportDependencies = { authenticate: async token => token === 'fictional-owner-token' ? { userId: OWNER } : null,
    cases: repo, loadRegistry: async () => [{ ...structuredClone(demoProgram), recheckAfter: null }],
    loadFormTemplate: async () => form, now: () => new Date(), allowDemoPrograms: true };
  const request = { schemaVersion: '1', caseId: snapshot.caseId, expectedCaseRevision: snapshot.revision,
    programId: demoProgram.programId, expectedFormContextId: createFormAnswerContext(form.template).formContextId,
    expectedAnswerRevision: 0, expectedEvidenceCatalogRevision: 2, generationKey: 'fictional-review-export', selectedEvidence: input.selections };
  return { repo, input, deps, request };
}

test('API creates from bytes once, rechecks metadata, and downloads a validated PDF without refetching image payloads', async () => {
  const state = await apiSetup();
  let images = 0, reviews = 0, pdfReads = 0, finalReviews = 0;
  const originalImages = state.repo.loadExportSnapshotForUser.bind(state.repo);
  const originalReview = state.repo.loadExportReviewForUser.bind(state.repo);
  state.repo.loadExportSnapshotForUser = async input => { images++; return originalImages(input); };
  state.repo.loadExportReviewForUser = async input => { reviews++; return originalReview(input); };
  const originalPdf = state.repo.readExportForUserIfCurrent.bind(state.repo);
  const originalFinalReview = state.repo.reviewExportForUserIfCurrent.bind(state.repo);
  state.repo.readExportForUserIfCurrent = async input => { pdfReads++; return originalPdf(input); };
  state.repo.reviewExportForUserIfCurrent = async input => { finalReviews++; return originalFinalReview(input); };
  const created = await handleDraftExport({ bearerToken: 'fictional-owner-token', body: state.request }, state.deps, 'create-draft-export');
  assert.equal(created.status, 200); assert.ok('artifactId' in created.body);
  assert.equal(images, 1); assert.equal(reviews, 1);
  assert.equal(pdfReads, 0); assert.equal(finalReviews, 1);
  state.repo.loadExportSnapshotForUser = async () => { throw new Error('A download fetched source images.'); };
  const downloaded = await handleDraftExport({ bearerToken: 'fictional-owner-token', body: {
    schemaVersion: '1', caseId: state.request.caseId, expectedCaseRevision: state.request.expectedCaseRevision,
    artifactId: created.body.artifactId } }, state.deps, 'download-draft-export');
  assert.equal(downloaded.status, 200); assert.ok(downloaded.body instanceof Uint8Array);
  assert.equal(createHash('sha256').update(downloaded.body).digest('hex'), created.body.sha256);
  assert.equal(reviews, 2); assert.equal(downloaded.headers['Cache-Control'], 'no-store');
  assert.equal(pdfReads, 1); assert.equal(finalReviews, 1);
});

test('API refuses mismatched final publication metadata and expiry after metadata review', async () => {
  for (const mode of ['mismatch', 'expired'] as const) {
    const state = await apiSetup(); const original = state.repo.reviewExportForUserIfCurrent.bind(state.repo);
    state.repo.readExportForUserIfCurrent = async () => { throw new Error('Creation fetched private PDF bytes.'); };
    state.repo.reviewExportForUserIfCurrent = async input => {
      const result = await original(input);
      assert.equal(result.status, 'found');
      if (result.status !== 'found') throw new Error('Missing fictional publication.');
      if (mode === 'mismatch') result.artifact.sha256 = '0'.repeat(64);
      else state.deps.now = () => new Date(result.artifact.expiresAt);
      return result;
    };
    const result = await handleDraftExport({ bearerToken: 'fictional-owner-token', body: state.request }, state.deps, 'create-draft-export');
    assert.ok('error' in result.body);
    assert.equal(result.body.error.code, mode === 'mismatch' ? 'INTERNAL_ERROR' : 'EXPORT_EXPIRED');
    assert.equal(result.status, mode === 'mismatch' ? 500 : 410);
  }
});

test('post-render metadata review refuses evidence removed during rendering instead of publishing a stale PDF', async () => {
  const state = await apiSetup(); const originalReview = state.repo.loadExportReviewForUser.bind(state.repo);
  let reviews = 0;
  state.repo.loadExportReviewForUser = async input => {
    reviews++;
    assert.equal((await state.repo.deleteEvidenceIfCurrent({ ...state.input, evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 })).status, 'deleted');
    return originalReview(input);
  };
  let publications = 0;
  const publish = state.repo.publishExportIfCurrent.bind(state.repo);
  state.repo.publishExportIfCurrent = async input => { publications++; return publish(input); };
  const result = await handleDraftExport({ bearerToken: 'fictional-owner-token', body: state.request }, state.deps, 'create-draft-export');
  assert.equal(result.status, 409); assert.ok('error' in result.body); assert.equal(result.body.error.code, 'EVIDENCE_CONFLICT');
  assert.equal(reviews, 1); assert.equal(publications, 0);
});
