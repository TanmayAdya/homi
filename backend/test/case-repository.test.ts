import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import sharp from 'sharp';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { MAX_CASE_BYTES, MAX_MEMORY_CASES, type CaseDraft } from '../src/cases/types.ts';
import { parseCaseDraft, parseCaseSaveRequest, parseWrittenCase } from '../src/cases/validation.ts';
import { sanitizeEvidenceImage } from '../src/evidence/image-sanitizer.ts';
import { createSavedFormAnswers } from '../src/forms/form-answers.ts';
import type { CaseSnapshot, DraftPacket } from '../src/types.ts';

const CASE = '10000000-0000-4000-8000-000000000001';
const OTHER = '10000000-0000-4000-8000-000000000002';
const NOW = '2026-10-17T22:00:00.000Z';
function draft(caseId = CASE): CaseDraft {
  return { schemaVersion: '1', caseId,
    profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: 0,
      householdSize: null, annualIncomeUsd: 0, ownerConsentReported: false }, unresolvedFields: ['profile.city'],
    findings: [{ id: 'finding-a', room: 'entrance', observation: 'Fictional observation', reviewState: 'needs_review',
      evidenceIds: ['image-a'], measurements: [{ type: 'height', value: 0, unit: 'mm', method: 'manual', confirmed: false }] }] };
}
function setup() { return new MemoryCaseRepository([{ userId: 'alice', snapshot: { ...draft(), revision: 1 } }]); }
const image = sharp({ create: { width: 2, height: 2, channels: 4, background: '#888888' } }).png().toBuffer().then(sanitizeEvidenceImage);
async function upload(repository: MemoryCaseRepository) {
  const result = await repository.saveEvidenceIfCurrent({ userId: 'alice', caseId: CASE, revision: 1,
    expectedCatalogRevision: 0, evidenceId: 'image-a', expectedEvidenceRevision: 0, findingId: 'finding-a',
    image: await image, capturedAt: null, preparedAt: NOW });
  assert.equal(result.status, 'saved');
}

test('case draft parsing preserves null, zero and false and detaches nested values', () => {
  const input = draft(), parsed = parseCaseDraft(input, true); input.findings[0].measurements[0].value = 10;
  assert.equal(parsed.profile.city, null); assert.equal(parsed.profile.ageYears, 0);
  assert.equal(parsed.profile.ownerConsentReported, false); assert.equal(parsed.findings[0].measurements[0].value, 0);
  assert.deepEqual(parseWrittenCase({ ...parsed, revision: 9 }), { ...parsed, revision: 9 });
});

test('canonical schema rejects metadata overrides, malformed fields and duplicate evidence associations', () => {
  const repeated = draft(); repeated.findings.push({ ...repeated.findings[0], id: 'finding-b' });
  for (const input of [null, {}, { ...draft(), revision: 99 }, { ...draft(), ownerId: 'bob' },
    { ...draft(), profile: { ...draft().profile, clinicalDiagnosis: 'invented' } },
    { ...draft(), findings: [{ ...draft().findings[0], reviewState: 'approved' }] },
    { ...draft(), findings: [{ ...draft().findings[0], measurements: [{ ...draft().findings[0].measurements[0], unit: 'inch' }] }] }, repeated,
    { ...draft(), caseId: ' leading' }, { ...draft(), findings: [{ ...draft().findings[0], id: '\ud800' }] }]) {
    assert.throws(() => parseCaseDraft(input));
  }
});

test('case text rejects NUL before storage while preserving ordinary multiline Unicode', async () => {
  for (const field of ['city', 'county', 'healthPlan', 'observation'] as const) {
    const value = draft();
    if (field === 'observation') value.findings[0].observation = 'Fictional\u0000text';
    else value.profile[field] = 'Fictional\u0000text';
    assert.throws(() => parseCaseDraft(value));
    assert.throws(() => parseCaseSaveRequest({ ...value, expectedCaseRevision: 1 }));
    const repository = setup();
    assert.equal((await repository.replaceIfCurrent('alice', CASE, 1, value)).status, 'invalid_input');
    assert.equal((await repository.loadForUser('alice', CASE))!.revision, 1);
    assert.equal((await new MemoryCaseRepository([]).createForUser('alice', value)).status, 'invalid_input');
  }
  const value = draft(); value.findings[0].observation = 'Fictional José\nSecond line';
  assert.equal(parseCaseDraft(value).findings[0].observation, value.findings[0].observation);
});

test('new IDs require lowercase UUIDv4 while existing saved case IDs remain compatible', async () => {
  const repository = setup();
  for (const caseId of ['legacy', CASE.toUpperCase().replace('10000000', 'A0000000'),
    '10000000-0000-1000-8000-000000000001', '10000000-0000-4000-7000-000000000001']) {
    assert.equal((await repository.createForUser('alice', draft(caseId))).status, 'invalid_input');
  }
  const legacy = new MemoryCaseRepository([{ userId: 'alice', snapshot: { ...draft('legacy'), revision: 1 } }]);
  assert.equal((await legacy.replaceIfCurrent('alice', 'legacy', 1, draft('legacy'))).status, 'saved');
});

test('canonical snapshot byte budget uses UTF-8 and the actual assigned revision', () => {
  const input = draft(); input.findings[0].observation = '';
  const overhead = Buffer.byteLength(JSON.stringify({ ...input, revision: 1 }));
  input.findings[0].observation = 'x'.repeat(MAX_CASE_BYTES - overhead);
  assert.equal(Buffer.byteLength(JSON.stringify({ ...parseCaseDraft(input), revision: 1 })), MAX_CASE_BYTES);
  assert.throws(() => parseCaseDraft(input, false, 10));
  assert.throws(() => parseCaseDraft({ ...input, findings: [{ ...input.findings[0], observation: `${input.findings[0].observation}x` }] }));
  input.findings[0].observation = '😀'.repeat(4000);
  assert.throws(() => parseCaseDraft(input));
});

test('direct inputs reject cycles, accessors, sparse arrays and non-JSON values without running hooks', () => {
  const cycle = draft() as unknown as Record<string, unknown>; cycle.profile = cycle;
  let invoked = false;
  const accessor = draft(); Object.defineProperty(accessor, 'profile', { enumerable: true, get() { invoked = true; return {}; } });
  const saveAccessor = { ...draft(), expectedCaseRevision: 1 };
  Object.defineProperty(saveAccessor, 'expectedCaseRevision', { enumerable: true, get() { invoked = true; return 1; } });
  const sparse = draft(); sparse.findings = Array(2);
  for (const value of [cycle, accessor, sparse, { ...draft(), profile: new Date() },
    { ...draft(), unresolvedFields: [undefined] }, { ...draft(), findings: [{ ...draft().findings[0], observation: '\ud800' }] }]) {
    assert.throws(() => parseCaseDraft(value));
  }
  assert.throws(() => parseCaseSaveRequest(saveAccessor)); assert.equal(invoked, false);
});

test('creation assigns revision one, never overwrites and has uniform cross-owner collisions', async () => {
  const repository = new MemoryCaseRepository([]), input = draft();
  const created = await repository.createForUser('alice', input); assert.equal(created.status, 'saved');
  if (created.status !== 'saved') return;
  assert.equal(created.snapshot.revision, 1); created.snapshot.findings.length = 0; input.findings.length = 0;
  assert.equal((await repository.loadForUser('alice', CASE))!.findings.length, 1);
  assert.equal(await repository.loadForUser('bob', CASE), null);
  assert.deepEqual(await repository.createForUser('alice', draft()), { status: 'id_unavailable' });
  assert.deepEqual(await repository.createForUser('bob', draft()), { status: 'id_unavailable' });
});

test('the global case quota includes seeds and rejects new creation without partial state', async () => {
  const cases = Array.from({ length: MAX_MEMORY_CASES }, (_, index) => ({ userId: 'alice',
    snapshot: { ...draft(`seed-${index}`), revision: 1 } }));
  const repository = new MemoryCaseRepository(cases);
  assert.equal((await repository.createForUser('bob', draft())).status, 'quota_exceeded');
  assert.equal(await repository.loadForUser('bob', CASE), null);
  assert.throws(() => new MemoryCaseRepository([...cases, { userId: 'bob', snapshot: { ...draft(), revision: 1 } }]));
});

test('full replacement uses owner and expected revision and never trusts a draft caseId override', async () => {
  const repository = setup(); const changed = draft(); changed.profile.city = 'Fictional City';
  assert.equal((await repository.replaceIfCurrent('bob', CASE, 1, changed)).status, 'not_found');
  assert.equal((await repository.replaceIfCurrent('alice', OTHER, 1, changed)).status, 'not_found');
  assert.equal((await repository.replaceIfCurrent('alice', CASE, 2, changed)).status, 'conflict');
  assert.equal((await repository.replaceIfCurrent('alice', CASE, 1, draft(OTHER))).status, 'invalid_input');
  const saved = await repository.replaceIfCurrent('alice', CASE, 1, changed); assert.equal(saved.status, 'saved');
  if (saved.status === 'saved') { assert.equal(saved.snapshot.revision, 2); saved.snapshot.profile.city = 'Caller mutation'; }
  assert.equal((await repository.loadForUser('alice', CASE))!.profile.city, 'Fictional City');
  assert.equal((await repository.replaceIfCurrent('alice', CASE, 1, changed)).status, 'conflict');
});

test('concurrent creation and replacement each have exactly one winner', async () => {
  const repository = new MemoryCaseRepository([]);
  assert.deepEqual((await Promise.all([repository.createForUser('alice', draft()), repository.createForUser('bob', draft())]))
    .map(result => result.status).sort(), ['id_unavailable', 'saved']);
  assert.deepEqual((await Promise.all([repository.replaceIfCurrent('alice', CASE, 1, draft()), repository.replaceIfCurrent('alice', CASE, 1, draft())]))
    .map(result => result.status).sort(), ['conflict', 'saved']);
});

test('active uploaded evidence cannot be removed or moved during a case replacement', async () => {
  const repository = setup(); await upload(repository);
  const remove = draft(); remove.findings[0].evidenceIds = [];
  const move = draft(); move.findings[0].evidenceIds = [];
  move.findings.push({ ...draft().findings[0], id: 'finding-b' });
  for (const changed of [remove, move, { ...draft(), findings: [] }]) {
    assert.equal((await repository.replaceIfCurrent('alice', CASE, 1, changed)).status, 'evidence_conflict');
  }
  assert.equal((await repository.loadForUser('alice', CASE))!.revision, 1);
  const changed = draft(); changed.findings[0].observation = 'Corrected fictional observation';
  assert.equal((await repository.replaceIfCurrent('alice', CASE, 1, changed)).status, 'saved');
});

test('after explicit evidence deletion its reference can be removed but its tombstoned binding cannot move', async () => {
  const repository = setup(); await upload(repository);
  assert.equal((await repository.deleteEvidenceIfCurrent({ userId: 'alice', caseId: CASE, revision: 1,
    expectedCatalogRevision: 1, evidenceId: 'image-a', expectedEvidenceRevision: 1 })).status, 'deleted');
  const remove = draft(); remove.findings = [];
  assert.equal((await repository.replaceIfCurrent('alice', CASE, 1, remove)).status, 'saved');
  const move = draft(); move.findings[0].id = 'finding-b';
  assert.equal((await repository.replaceIfCurrent('alice', CASE, 2, move)).status, 'evidence_conflict');
  assert.equal((await repository.replaceIfCurrent('alice', CASE, 2, draft())).status, 'saved');
});

test('case and upload ordering cannot orphan an image in either direction', async () => {
  const repository = setup(), remove = draft(); remove.findings = [];
  assert.equal((await repository.replaceIfCurrent('alice', CASE, 1, remove)).status, 'saved');
  assert.equal((await repository.saveEvidenceIfCurrent({ userId: 'alice', caseId: CASE, revision: 1,
    expectedCatalogRevision: 0, evidenceId: 'image-a', expectedEvidenceRevision: 0, findingId: 'finding-a',
    image: await image, capturedAt: null, preparedAt: NOW })).status, 'conflict');
});

test('case replacement invalidates matches and packet keys while retaining old answers as stale', async () => {
  const repository = setup();
  const answers = createSavedFormAnswers({ snapshot: { ...draft(), revision: 2 }, context: {
    programId: 'program-a', formVersion: 'form-a', mappingVersion: 'mapping-a', formContextId: 'a'.repeat(64) },
    answerRevision: 1, answers: [], updatedAt: NOW, updatedBy: 'alice' });
  await repository.saveFormAnswersIfCurrent({ userId: 'alice', caseId: CASE, revision: 1, programId: 'program-a', expectedAnswerRevision: 0, answers });
  await repository.saveMatchIfCurrent('alice', CASE, 2, { schemaVersion: '1', caseId: CASE, caseRevision: 2,
    evaluatedAt: NOW, evaluationDate: NOW.slice(0, 10), matches: [] });
  const packet: DraftPacket = { schemaVersion: '1', packetId: 'packet-a', caseId: CASE, caseRevision: 2,
    programId: 'program-a', ruleVersion: 'r1', formVersion: null, mappingVersion: null, status: 'draft', isDemo: true,
    generatedAt: NOW, recheckAfter: '2026-10-18T00:00:00.000Z', storageReference: null, attachments: [], missingItems: [] };
  await repository.createPacketIfCurrent({ userId: 'alice', caseId: CASE, revision: 2, generationKey: 'packet-key',
    contextFingerprint: 'same-private-context', packet, checkedAt: NOW });
  await repository.replaceIfCurrent('alice', CASE, 2, draft());
  assert.equal(await repository.readSavedMatchForUser('alice', CASE), null);
  assert.equal((await repository.loadFormAnswersForUser('alice', CASE, 'program-a'))!.caseRevision, 2);
  assert.equal((await repository.loadForUser('alice', CASE))!.revision, 3);
  assert.equal((await repository.createPacketIfCurrent({ userId: 'alice', caseId: CASE, revision: 3, generationKey: 'packet-key',
    contextFingerprint: 'same-private-context', packet: { ...packet, caseRevision: 3 }, checkedAt: NOW })).status, 'generation_conflict');
});

test('case replacement atomically invalidates downloadable PDF bytes even with no evidence selected', async () => {
  const repository = setup();
  const loaded = await repository.loadExportSnapshotForUser({ userId: 'alice', caseId: CASE, revision: 1,
    expectedCatalogRevision: 0, programId: 'program-a', selections: [] });
  assert.equal(loaded.status, 'found'); if (loaded.status !== 'found') return;
  const bytes = Buffer.from('%PDF-1.7\nFictional case repository fixture.\n'); const context = 'b'.repeat(64);
  const publication = { userId: 'alice', caseId: CASE, revision: 1, expectedCatalogRevision: 0,
    programId: 'program-a', expectedCaseFingerprint: loaded.snapshot.caseFingerprint,
    expectedAnswersFingerprint: null, selections: [], contextFingerprint: context, generationKey: 'export-key', checkedAt: NOW,
    artifact: { bytes, metadata: { schemaVersion: '1' as const, artifactId: 'artifact-case', caseId: CASE, caseRevision: 1,
      programId: 'program-a', ruleVersion: 'rule-a', formVersion: 'form-a', mappingVersion: 'mapping-a', formContextId: 'a'.repeat(64),
      answerRevision: 0, evidenceCatalogRevision: 0, exportContextId: context, generatedAt: NOW,
      expiresAt: '2026-10-17T22:15:00.000Z', recheckAfter: null, status: 'draft' as const, isDemo: true,
      mediaType: 'application/pdf' as const, byteLength: bytes.byteLength, sha256: createHash('sha256').update(bytes).digest('hex'),
      pageCount: 1, renderingVersion: 'draft-export-v1' as const, selectedEvidence: [], missingItems: [],
      warnings: ['INCOMPLETE_DRAFT', 'NOT_SUBMITTED', 'POLICY_CURRENTNESS_UNKNOWN'] as ('INCOMPLETE_DRAFT' | 'NOT_SUBMITTED' | 'POLICY_CURRENTNESS_UNKNOWN')[] } } };
  assert.equal((await repository.publishExportIfCurrent(publication)).status, 'saved');
  await repository.replaceIfCurrent('alice', CASE, 1, draft());
  assert.equal((await repository.readExportForUserIfCurrent({ userId: 'alice', caseId: CASE,
    artifactId: 'artifact-case', contextFingerprint: context, checkedAt: NOW })).status, 'conflict');
  assert.equal((await repository.publishExportIfCurrent(publication)).status, 'conflict');
});
