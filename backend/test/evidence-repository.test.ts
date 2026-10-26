import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import sharp from 'sharp';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { sanitizeEvidenceImage } from '../src/evidence/image-sanitizer.ts';
import { parseEvidenceSelections, parseEvidenceAsset, parseSanitizedEvidenceImage } from '../src/evidence/validation.ts';
import type { ExportPublishInput } from '../src/evidence/repository.ts';
import type { SanitizedEvidenceImage } from '../src/evidence/types.ts';
import type { CaseSnapshot } from '../src/types.ts';
import { createSavedFormAnswers } from '../src/forms/form-answers.ts';
import { registerTrustedEvidence, type TrustedEvidenceRegistration } from '../src/evidence/register-trusted-evidence.ts';

const NOW = '2026-10-17T22:00:00.000Z';
const LATER = '2026-10-17T22:01:00.000Z';
const CONTEXT = 'a'.repeat(64);
const imagePromise = sharp({ create: { width: 2, height: 2, channels: 4, background: '#d0d0d0' } }).png().toBuffer()
  .then(sanitizeEvidenceImage);
function makeCase(caseId = 'case-a'): CaseSnapshot {
  return { schemaVersion: '1', caseId, revision: 1, profile: { city: null, county: null, healthPlan: null,
    tenure: null, ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [],
  findings: [
    { id: 'finding-a', room: 'bathroom', observation: 'Fictional reviewed observation', reviewState: 'confirmed', evidenceIds: ['photo-a', 'photo-b'], measurements: [] },
    { id: 'finding-b', room: 'entrance', observation: 'Fictional pending observation', reviewState: 'needs_review', evidenceIds: ['photo-c'], measurements: [] },
  ] };
}
function setup(limits?: { maxBytes: number; maxAssets: number; maxArtifacts: number }) {
  return new MemoryCaseRepository([{ userId: 'alice', snapshot: makeCase() }, { userId: 'bob', snapshot: makeCase('case-b') }], limits);
}
const binding = { userId: 'alice', caseId: 'case-a', revision: 1, expectedCatalogRevision: 0 };
async function save(repository: MemoryCaseRepository, extra = {}) {
  return repository.saveEvidenceIfCurrent({ ...binding, evidenceId: 'photo-a', expectedEvidenceRevision: 0,
    findingId: 'finding-a', image: await imagePromise, capturedAt: null, preparedAt: NOW, ...extra });
}
const selections = [{ evidenceId: 'photo-a', expectedEvidenceRevision: 1, reviewedForExport: true as const }];
async function publication(repository: MemoryCaseRepository): Promise<ExportPublishInput> {
  const revision = (await repository.loadForUser('alice', 'case-a'))!.revision;
  const loaded = await repository.loadExportSnapshotForUser({ ...binding, revision, expectedCatalogRevision: 1, programId: 'program-a', selections });
  assert.equal(loaded.status, 'found'); if (loaded.status !== 'found') throw new Error('fixture');
  const bytes = Buffer.from('%PDF-1.7\nFictional repository bytes; renderer tests validate actual PDF structure.\n');
  return { ...binding, revision, expectedCatalogRevision: 1, programId: 'program-a', selections,
    expectedCaseFingerprint: loaded.snapshot.caseFingerprint, expectedAnswersFingerprint: loaded.snapshot.answersFingerprint,
    contextFingerprint: CONTEXT, generationKey: 'generation-1', checkedAt: NOW,
    artifact: { bytes, metadata: { schemaVersion: '1', artifactId: 'artifact-a', caseId: 'case-a', caseRevision: revision,
      programId: 'program-a', ruleVersion: 'rule-a', formVersion: 'form-a', mappingVersion: 'mapping-a', formContextId: 'b'.repeat(64),
      answerRevision: loaded.snapshot.answers?.answerRevision ?? 0, evidenceCatalogRevision: 1, exportContextId: CONTEXT, generatedAt: NOW,
      expiresAt: '2026-10-17T22:15:00.000Z', recheckAfter: null, status: 'draft', isDemo: true, mediaType: 'application/pdf',
      byteLength: bytes.byteLength, sha256: createHash('sha256').update(bytes).digest('hex'), pageCount: 2,
      renderingVersion: 'draft-export-v1', selectedEvidence: loaded.snapshot.assets.map(asset => ({
        evidenceId: asset.descriptor.evidenceId, evidenceRevision: asset.descriptor.evidenceRevision,
        findingId: asset.descriptor.findingId, sha256: asset.descriptor.sha256, reviewedAt: NOW, reviewedBy: 'alice' })),
      missingItems: [], warnings: ['INCOMPLETE_DRAFT', 'NOT_SUBMITTED', 'POLICY_CURRENTNESS_UNKNOWN'] } } };
}
const download = { userId: 'alice', caseId: 'case-a', artifactId: 'artifact-a', contextFingerprint: CONTEXT, checkedAt: NOW };

test('streaming validation freezes caller identity and bytes before yielding', async () => {
  const repository = setup();
  const image = structuredClone(await imagePromise);
  const expectedHash = image.sha256;
  const input = { ...binding, evidenceId: 'photo-a', expectedEvidenceRevision: 0,
    findingId: 'finding-a', image, capturedAt: null, preparedAt: NOW };
  const pending = repository.saveEvidenceIfCurrent(input);
  input.userId = 'bob'; input.caseId = 'case-b'; input.evidenceId = 'photo-b';
  input.image.bytes.fill(0); input.image.sha256 = 'f'.repeat(64);
  const result = await pending;
  assert.equal(result.status, 'saved');
  if (result.status !== 'saved') throw new Error('Expected fictional image save.');
  assert.equal(result.asset.descriptor.caseId, 'case-a');
  assert.equal(result.asset.descriptor.evidenceId, 'photo-a');
  assert.equal(result.asset.descriptor.sha256, expectedHash);
  const bob = await repository.readEvidenceCatalogForUser('bob', 'case-b');
  assert.equal(bob.status, 'found');
  if (bob.status === 'found') assert.equal(bob.catalog.evidence.length, 0);
});

test('case changes during streaming validation prevent publication under an old revision', async () => {
  const repository = setup();
  const pending = repository.saveEvidenceIfCurrent({ ...binding, evidenceId: 'photo-a', expectedEvidenceRevision: 0,
    findingId: 'finding-a', image: await imagePromise, capturedAt: null, preparedAt: NOW });
  const { revision: _, ...draft } = makeCase();
  draft.findings[0].observation = 'A corrected fictional observation.';
  assert.equal((await repository.replaceIfCurrent('alice', 'case-a', 1, draft)).status, 'saved');
  assert.equal((await pending).status, 'conflict');
  const catalog = await repository.readEvidenceCatalogForUser('alice', 'case-a');
  assert.equal(catalog.status, 'found');
  if (catalog.status === 'found') assert.equal(catalog.catalog.evidence.length, 0);
});

test('concurrent streaming validations cannot both claim the same catalog revision', async () => {
  const repository = setup();
  const image = await imagePromise;
  const results = await Promise.all(['photo-a', 'photo-b'].map(evidenceId => repository.saveEvidenceIfCurrent({
    ...binding, evidenceId, expectedEvidenceRevision: 0, findingId: 'finding-a', image, capturedAt: null, preparedAt: NOW,
  })));
  assert.deepEqual(results.map(result => result.status).sort(), ['evidence_conflict', 'saved']);
  const catalog = await repository.readEvidenceCatalogForUser('alice', 'case-a');
  assert.equal(catalog.status, 'found');
  if (catalog.status === 'found') {
    assert.equal(catalog.catalog.catalogRevision, 1);
    assert.equal(catalog.catalog.evidence.length, 1);
  }
});

test('evidence selections require explicit review, unique exact IDs and a bounded ordered list', () => {
  assert.deepEqual(parseEvidenceSelections(selections), selections);
  assert.deepEqual(parseEvidenceSelections([]), []);
  for (const invalid of [null, {}, [selections[0], selections[0]], [{ ...selections[0], reviewedForExport: false }],
    [{ ...selections[0], expectedEvidenceRevision: 0 }], [{ ...selections[0], evidenceId: ' leading' }],
    [{ ...selections[0], evidenceId: '\ud800' }], [{ ...selections[0], path: '/private/photo.png' }],
    Array.from({ length: 7 }, (_, i) => ({ ...selections[0], evidenceId: `photo-${i}` }))]) assert.throws(() => parseEvidenceSelections(invalid));
});

test('canonical image descriptors reject mismatched dimensions, hashes and extra metadata', async () => {
  const image = await imagePromise;
  for (const invalid of [{ ...image, width: 3 }, { ...image, sha256: 'f'.repeat(64) }, { ...image, gps: 'private' },
    { ...image, bytes: Buffer.from('not a PNG') }, { ...image, processingVersion: 'unchecked' }]) {
    assert.throws(() => parseSanitizedEvidenceImage(invalid));
  }
  const repository = setup(); const saved = await save(repository);
  assert.equal(saved.status, 'saved'); if (saved.status !== 'saved') return;
  assert.deepEqual(parseEvidenceAsset(saved.asset), saved.asset);
  assert.throws(() => parseEvidenceAsset({ ...saved.asset, descriptor: { ...saved.asset.descriptor, capturedAt: LATER } }));
});

test('registration binds current owner, case, finding and catalog without advancing case answers', async () => {
  const repository = setup();
  assert.equal((await save(repository, { userId: 'bob' })).status, 'not_found');
  assert.equal((await save(repository, { revision: 2 })).status, 'conflict');
  assert.equal((await save(repository, { expectedCatalogRevision: 1 })).status, 'evidence_conflict');
  assert.equal((await save(repository, { findingId: 'finding-b' })).status, 'not_found');
  const saved = await save(repository); assert.equal(saved.status, 'saved'); if (saved.status !== 'saved') return;
  assert.equal(saved.asset.descriptor.evidenceRevision, 1); assert.equal(saved.catalogRevision, 1);
  assert.equal((await repository.loadForUser('alice', 'case-a'))!.revision, 1);
  const catalog = await repository.readEvidenceCatalogForUser('alice', 'case-a');
  assert.equal(catalog.status, 'found'); if (catalog.status !== 'found') return;
  assert.equal(catalog.catalog.evidence.length, 1);
  assert.equal('bytes' in catalog.catalog.evidence[0], false);
  assert.equal((await repository.readEvidenceCatalogForUser('bob', 'case-a')).status, 'not_found');
});

test('stored images and catalog outputs are detached from callers', async () => {
  const repository = setup(); const image = structuredClone(await imagePromise);
  const saved = await save(repository, { image }); assert.equal(saved.status, 'saved'); if (saved.status !== 'saved') return;
  image.bytes.fill(0); saved.asset.bytes.fill(0); saved.asset.descriptor.findingId = 'changed';
  const found = await repository.readEvidenceForUser({ ...binding, expectedCatalogRevision: 1, evidenceId: 'photo-a', expectedEvidenceRevision: 1 });
  assert.equal(found.status, 'found'); if (found.status !== 'found') return;
  assert.equal(found.asset.bytes[0], 137); assert.equal(found.asset.descriptor.findingId, 'finding-a');
});

test('preview accepts linked pending evidence, while export accepts only confirmed findings', async () => {
  const repository = setup();
  assert.equal((await save(repository, { evidenceId: 'photo-c', findingId: 'finding-b' })).status, 'saved');
  assert.equal((await repository.readEvidenceForUser({ ...binding, expectedCatalogRevision: 1, evidenceId: 'photo-c', expectedEvidenceRevision: 1 })).status, 'found');
  assert.equal((await repository.loadExportSnapshotForUser({ ...binding, expectedCatalogRevision: 1, programId: 'p',
    selections: [{ evidenceId: 'photo-c', expectedEvidenceRevision: 1, reviewedForExport: true }] })).status, 'evidence_conflict');
});

test('replacement and deletion require exact catalog/asset revisions and retain monotonic tombstones', async () => {
  const repository = setup(); await save(repository);
  assert.equal((await save(repository, { expectedCatalogRevision: 1 })).status, 'evidence_conflict');
  assert.equal((await save(repository, { expectedCatalogRevision: 1, expectedEvidenceRevision: 1, preparedAt: LATER })).status, 'saved');
  const removed = await repository.deleteEvidenceIfCurrent({ ...binding, expectedCatalogRevision: 2, evidenceId: 'photo-a', expectedEvidenceRevision: 2 });
  assert.deepEqual(removed, { status: 'deleted', evidenceRevision: 3, catalogRevision: 3 });
  assert.equal((await save(repository, { expectedCatalogRevision: 3, preparedAt: LATER })).status, 'evidence_conflict');
  const restored = await save(repository, { expectedCatalogRevision: 3, expectedEvidenceRevision: 3, preparedAt: LATER });
  assert.equal(restored.status, 'saved'); if (restored.status === 'saved') assert.equal(restored.asset.descriptor.evidenceRevision, 4);
});

test('concurrent registrations with the same expected catalog cannot both commit', async () => {
  const repository = setup();
  const results = await Promise.all([save(repository), save(repository, { evidenceId: 'photo-b' })]);
  assert.deepEqual(results.map(result => result.status).sort(), ['evidence_conflict', 'saved']);
});

test('atomic export snapshot checks case, catalog, linked assets and returns detached values', async () => {
  const repository = setup(); await save(repository);
  const input = { ...binding, expectedCatalogRevision: 1, programId: 'p', selections };
  assert.equal((await repository.loadExportSnapshotForUser({ ...input, userId: 'bob' })).status, 'not_found');
  assert.equal((await repository.loadExportSnapshotForUser({ ...input, expectedCatalogRevision: 0 })).status, 'evidence_conflict');
  assert.equal((await repository.loadExportSnapshotForUser({ ...input, selections: [{ ...selections[0], expectedEvidenceRevision: 2 }] })).status, 'evidence_conflict');
  const loaded = await repository.loadExportSnapshotForUser(input); assert.equal(loaded.status, 'found'); if (loaded.status !== 'found') return;
  loaded.snapshot.snapshot.findings[0].reviewState = 'dismissed'; loaded.snapshot.assets[0].bytes.fill(0);
  assert.equal((await repository.loadExportSnapshotForUser(input)).status, 'found');
});

test('artifact publication and download are owner scoped and detach all byte buffers', async () => {
  const repository = setup(); await save(repository); const input = await publication(repository);
  assert.equal((await repository.publishExportIfCurrent({ ...input, userId: 'bob' })).status, 'not_found');
  assert.equal((await repository.publishExportIfCurrent(input)).status, 'saved');
  input.artifact.bytes.fill(0); input.artifact.metadata.selectedEvidence[0].findingId = 'changed';
  assert.equal((await repository.readExportForUser({ ...download, userId: 'bob' })).status, 'not_found');
  assert.equal((await repository.readExportForUserIfCurrent({ ...download, userId: 'bob' })).status, 'not_found');
  const first = await repository.readExportForUserIfCurrent(download); assert.equal(first.status, 'found'); if (first.status !== 'found') return;
  assert.equal(Buffer.from(first.artifact.bytes).subarray(0, 5).toString(), '%PDF-');
  first.artifact.bytes.fill(0);
  const second = await repository.readExportForUserIfCurrent(download); assert.equal(second.status, 'found');
  if (second.status === 'found') assert.equal(second.artifact.bytes[0], 37);
});

test('concurrent same-key publication is idempotent only for identical current bindings', async () => {
  const repository = setup(); await save(repository); const input = await publication(repository);
  const results = await Promise.all([repository.publishExportIfCurrent(input), repository.publishExportIfCurrent(structuredClone(input))]);
  assert.deepEqual(results.map(result => result.status).sort(), ['reused', 'saved']);
  const changed = structuredClone(input); changed.contextFingerprint = 'c'.repeat(64); changed.artifact.metadata.exportContextId = changed.contextFingerprint;
  assert.equal((await repository.publishExportIfCurrent(changed)).status, 'generation_conflict');
  assert.equal((await repository.readExportForUserIfCurrent({ ...download, contextFingerprint: 'c'.repeat(64) })).status, 'generation_conflict');
});

test('any evidence mutation invalidates previously generated artifacts and stale publication', async () => {
  const repository = setup(); await save(repository); const input = await publication(repository);
  await repository.publishExportIfCurrent(input);
  await save(repository, { evidenceId: 'photo-b', expectedCatalogRevision: 1 });
  assert.equal((await repository.publishExportIfCurrent(input)).status, 'evidence_conflict');
  assert.equal((await repository.readExportForUserIfCurrent(download)).status, 'evidence_conflict');
});

test('answer saves advance case revision and invalidate artifacts and in-flight publication', async () => {
  const repository = setup(); await save(repository); const input = await publication(repository); await repository.publishExportIfCurrent(input);
  const answers = createSavedFormAnswers({ snapshot: { ...makeCase(), revision: 2 }, context: {
    programId: 'program-a', formVersion: 'form-a', mappingVersion: 'mapping-a', formContextId: 'b'.repeat(64) },
    answerRevision: 1, answers: [], updatedAt: NOW, updatedBy: 'alice' });
  assert.equal((await repository.saveFormAnswersIfCurrent({ userId: 'alice', caseId: 'case-a', revision: 1,
    programId: 'program-a', expectedAnswerRevision: 0, answers })).status, 'saved');
  assert.equal((await repository.publishExportIfCurrent(input)).status, 'conflict');
  assert.equal((await repository.readExportForUserIfCurrent(download)).status, 'conflict');
});

test('full case and answer fingerprints are required at publication', async () => {
  const repository = setup(); await save(repository); const input = await publication(repository);
  assert.equal((await repository.publishExportIfCurrent({ ...input, expectedCaseFingerprint: '0'.repeat(64) })).status, 'conflict');
  assert.equal((await repository.publishExportIfCurrent({ ...input, expectedAnswersFingerprint: '0'.repeat(64) })).status, 'answers_conflict');
});

test('publication checks saved answer form binding as well as full record and answer revision', async () => {
  const repository = setup(); await save(repository);
  const answers = createSavedFormAnswers({ snapshot: { ...makeCase(), revision: 2 }, context: {
    programId: 'program-a', formVersion: 'form-a', mappingVersion: 'mapping-a', formContextId: 'b'.repeat(64) },
    answerRevision: 1, answers: [], updatedAt: NOW, updatedBy: 'alice' });
  await repository.saveFormAnswersIfCurrent({ userId: 'alice', caseId: 'case-a', revision: 1,
    programId: 'program-a', expectedAnswerRevision: 0, answers });
  const input = await publication(repository);
  const wrongForm = structuredClone(input); wrongForm.artifact.metadata.formVersion = 'changed-form';
  assert.equal((await repository.publishExportIfCurrent(wrongForm)).status, 'answers_conflict');
  assert.equal((await repository.publishExportIfCurrent(input)).status, 'saved');
});

test('artifact metadata must match selected bytes, identity, reviewer and lifetime exactly', async () => {
  const repository = setup(); await save(repository); const input = await publication(repository);
  for (const change of [
    { sha256: '0'.repeat(64) }, { caseId: 'case-b' }, { evidenceCatalogRevision: 2 }, { answerRevision: 1 },
    { expiresAt: '2026-10-17T22:16:00.000Z' }, { recheckAfter: '2026-10-17T22:14:00.000Z' },
    { selectedEvidence: [{ ...input.artifact.metadata.selectedEvidence[0], reviewedBy: 'bob' }] },
    { selectedEvidence: [{ ...input.artifact.metadata.selectedEvidence[0], sha256: '0'.repeat(64) }] },
  ]) await assert.rejects(repository.publishExportIfCurrent({ ...input, artifact: {
    ...input.artifact, metadata: { ...input.artifact.metadata, ...change } } }));
  assert.equal((await repository.readExportForUser(download)).status, 'not_found');
});

test('expiration is exclusive and clock rollback cannot revive previously expired exports', async () => {
  const repository = setup(); await save(repository); await repository.publishExportIfCurrent(await publication(repository));
  assert.equal((await repository.readExportForUserIfCurrent({ ...download, checkedAt: LATER })).status, 'found');
  assert.equal((await repository.readExportForUserIfCurrent(download)).status, 'expired');
  assert.equal((await repository.readExportForUserIfCurrent({ ...download, checkedAt: '2026-10-17T22:15:00.000Z' })).status, 'expired');
  assert.equal((await repository.readExportForUserIfCurrent({ ...download, checkedAt: LATER })).status, 'expired');
});

test('bounded quotas reject atomically and tombstones count against record limits', async () => {
  const image = await imagePromise;
  const tiny = setup({ maxBytes: image.byteLength - 1, maxAssets: 64, maxArtifacts: 16 });
  assert.equal((await save(tiny)).status, 'quota_exceeded');
  const repository = setup({ maxBytes: 1024 * 1024, maxAssets: 1, maxArtifacts: 1 });
  await save(repository); const input = await publication(repository); await repository.publishExportIfCurrent(input);
  const second = structuredClone(input); second.generationKey = 'generation-2'; second.artifact.metadata.artifactId = 'artifact-b';
  assert.equal((await repository.publishExportIfCurrent(second)).status, 'quota_exceeded');
  await repository.deleteEvidenceIfCurrent({ ...binding, expectedCatalogRevision: 1, evidenceId: 'photo-a', expectedEvidenceRevision: 1 });
  assert.equal((await save(repository, { expectedCatalogRevision: 2, evidenceId: 'photo-b' })).status, 'quota_exceeded');
  assert.equal((await save(repository, { expectedCatalogRevision: 2, expectedEvidenceRevision: 2 })).status, 'saved');
});

async function registration(): Promise<TrustedEvidenceRegistration> {
  return { userId: 'alice', caseId: 'case-a', expectedCaseRevision: 1, expectedCatalogRevision: 0,
    evidenceId: 'photo-a', expectedEvidenceRevision: 0, findingId: 'finding-a', capturedAt: null,
    bytes: (await imagePromise).bytes };
}

test('trusted registration checks owner and current case/finding before invoking sanitizer', async () => {
  const repository = setup(); let decoded = 0;
  const deps = { cases: repository, now: () => new Date(NOW), sanitize: async () => { decoded++; return imagePromise; } };
  const input = await registration();
  assert.equal((await registerTrustedEvidence({ ...input, userId: 'bob' }, deps)).status, 'not_found');
  assert.equal((await registerTrustedEvidence({ ...input, expectedCaseRevision: 2 }, deps)).status, 'conflict');
  assert.equal((await registerTrustedEvidence({ ...input, expectedCatalogRevision: 1 }, deps)).status, 'evidence_conflict');
  assert.equal((await registerTrustedEvidence({ ...input, findingId: 'finding-b' }, deps)).status, 'not_found');
  assert.equal(decoded, 0);
  const result = await registerTrustedEvidence(input, deps); assert.equal(result.status, 'saved');
  if (result.status === 'saved') assert.equal(result.asset.descriptor.preparedAt, NOW);
});

test('trusted registration detaches owner, identities and bytes across awaited adapter work', async () => {
  const repository = setup(); const input = await registration(); input.bytes = Uint8Array.from(input.bytes);
  const originalLoad = repository.loadForUser.bind(repository);
  repository.loadForUser = async (...args) => {
    input.userId = 'bob'; input.caseId = 'case-b'; input.findingId = 'changed'; input.bytes.fill(0);
    return originalLoad(...args);
  };
  const result = await registerTrustedEvidence(input, { cases: repository, now: () => new Date(NOW) });
  assert.equal(result.status, 'saved'); if (result.status === 'saved') assert.equal(result.asset.descriptor.caseId, 'case-a');
});

test('trusted registration rechecks catalog mutation atomically after sanitizer finishes', async () => {
  const repository = setup();
  const result = await registerTrustedEvidence(await registration(), { cases: repository, now: () => new Date(NOW),
    sanitize: async () => { await save(repository, { evidenceId: 'photo-b' }); return imagePromise; } });
  assert.equal(result.status, 'evidence_conflict');
  const catalog = await repository.readEvidenceCatalogForUser('alice', 'case-a');
  assert.equal(catalog.status, 'found'); if (catalog.status === 'found') assert.deepEqual(catalog.catalog.evidence.map(item => item.evidenceId), ['photo-b']);
});

test('trusted registration cannot save after a case change during processing', async () => {
  const repository = setup();
  const result = await registerTrustedEvidence(await registration(), { cases: repository, now: () => new Date(NOW),
    sanitize: async () => {
      const answers = createSavedFormAnswers({ snapshot: { ...makeCase(), revision: 2 }, context: {
        programId: 'program-a', formVersion: 'form-a', mappingVersion: 'mapping-a', formContextId: 'b'.repeat(64) },
        answerRevision: 1, answers: [], updatedAt: NOW, updatedBy: 'alice' });
      await repository.saveFormAnswersIfCurrent({ userId: 'alice', caseId: 'case-a', revision: 1,
        programId: 'program-a', expectedAnswerRevision: 0, answers });
      return imagePromise;
    } });
  assert.equal(result.status, 'conflict');
});

test('invalid image, future capture date and backward processing clocks do not store evidence', async () => {
  const repository = setup(); const input = await registration();
  assert.equal((await registerTrustedEvidence({ ...input, bytes: Buffer.from('invalid image') }, {
    cases: repository, now: () => new Date(NOW) })).status, 'invalid_image');
  assert.equal((await registerTrustedEvidence({ ...input, capturedAt: LATER }, {
    cases: repository, now: () => new Date(NOW) })).status, 'invalid_input');
  let now = LATER;
  assert.equal((await registerTrustedEvidence(input, { cases: repository, now: () => new Date(now),
    sanitize: async () => { now = NOW; return imagePromise; } })).status, 'service_unavailable');
  const catalog = await repository.readEvidenceCatalogForUser('alice', 'case-a');
  assert.equal(catalog.status, 'found'); if (catalog.status === 'found') assert.equal(catalog.catalog.catalogRevision, 0);
});

test('trusted registration does not expose private decoder or storage exception messages', async () => {
  const repository = setup();
  const result = await registerTrustedEvidence(await registration(), { cases: repository, now: () => new Date(NOW),
    sanitize: async () => { throw new Error('private filename /secret/location'); } });
  assert.deepEqual(result, { status: 'invalid_image' });
});

test('injected sanitizers cannot bypass canonical byte, dimension or digest validation', async () => {
  for (const change of [
    (value: SanitizedEvidenceImage) => { value.bytes[0] ^= 255; },
    (value: SanitizedEvidenceImage) => { value.width++; },
    (value: SanitizedEvidenceImage) => { value.sha256 = '0'.repeat(64); },
    (value: SanitizedEvidenceImage) => { value.byteLength++; },
  ]) {
    const repository = setup(), supplied = structuredClone(await imagePromise); change(supplied);
    let saved = false; const originalSave = repository.saveEvidenceIfCurrent.bind(repository);
    repository.saveEvidenceIfCurrent = async input => { saved = true; return originalSave(input); };
    const result = await registerTrustedEvidence(await registration(), { cases: repository, now: () => new Date(NOW),
      sanitize: async () => supplied });
    assert.deepEqual(result, { status: 'invalid_image' }); assert.equal(saved, false);
  }
});

test('injected sanitizer bytes and metadata are captured before late adapter mutation reaches storage', async () => {
  const repository = setup(), expected = structuredClone(await imagePromise), supplied = structuredClone(expected);
  const originalBytes = supplied.bytes; let scheduled = false, mutated = false;
  Object.defineProperty(supplied, 'bytes', { enumerable: true, get() {
    if (!scheduled) {
      scheduled = true; queueMicrotask(() => { originalBytes.fill(0); supplied.sha256 = '0'.repeat(64); mutated = true; });
    }
    return originalBytes;
  } });
  const originalSave = repository.saveEvidenceIfCurrent.bind(repository);
  repository.saveEvidenceIfCurrent = async input => {
    const bytes = input.image.bytes; await Promise.resolve();
    assert.equal(mutated, true); assert.deepEqual(bytes, expected.bytes); assert.equal(input.image.sha256, expected.sha256);
    return originalSave(input);
  };
  const result = await registerTrustedEvidence(await registration(), { cases: repository, now: () => new Date(NOW), sanitize: async () => supplied });
  assert.equal(result.status, 'saved');
});
